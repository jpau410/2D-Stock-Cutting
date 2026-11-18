# Pattern generation by big-M anchors plus pairwise dichotomic search, using
# the revised three-staged DP (generate_pattern_dp_revised_three_staged in
# revised_three-staged_dp.jl). This file stands alone: it does not use any
# other pattern generator, and every step is written out below.
#
#   Optimal:     the best pattern of every sheet at the true item values.
#   Big M:       for every placeable item on every sheet, the best pattern
#                under weights that put almost all the weight on that item.
#                The focus item gets 1 - epsilon and the other placeable items
#                share epsilon.
#   Dichotomic:  for each sheet, a search between every pair of its big-M
#                patterns, one for item i and one for item j with i != j. The
#                weights on i and j are set so the two patterns score the same,
#                so the DP under them finds whatever lies between them. A new
#                pattern is searched against both ends, breadth first, until
#                the result is one of the ends.
#
# The search only means something between two patterns that compete for the
# same sheet, so patterns from different sheets are never paired.
#
# Every pattern goes into a PatternPool as it is generated, so the same sheet
# never holds two with the same item counts. A result that is already in the
# pool is not added again, but the search carries on from it: it becomes the
# middle of the two ends, as if it were new. Each pair of patterns is searched
# at most once for a given pair of items.
#
# The steps run in order and pattern ids are given out in order, so two ids
# tell which step found any pattern: the first big-M id and the first
# dichotomic id. They are returned with track_origins = true (see
# pattern_phase in helper/pattern_pool.jl).
#
# An item can be placed on a sheet if either of its orientations can (see
# items_fitting_sheet). The clearance keywords go unchanged to every DP call,
# so a pattern's `.value` means the same thing whichever step found it.
#
# Requires: generate_pattern_dp_revised_three_staged
#           (revised_three-staged_dp.jl),
#           PatternPool, add_pattern!, pattern_phase (helper/pattern_pool.jl),
#           print_pattern_summary (helper/reporting.jl),
#           softened_lexmax_weights, weighted_instance, objective_vector,
#           dichotomic_lambda_pair (helper/lexmax.jl),
#           placeable_positions (helper/item_fitting.jl),
#           Item, Sheet, Pattern, Instance (helper/structs.jl),
#           DEFAULT_LEXMAX_EPSILON (src/constants.jl)

# --- Optimal and big M ---
#
# `clearances` is the NamedTuple (clearance, clearance_left, clearance_right,
# clearance_top, clearance_bottom) that the DP takes as keywords.

# Adds the best pattern under the true values for every sheet to `pool`. A sheet
# where nothing fits adds nothing.
function _dichotomic_optimal_step!(
    pool           :: PatternPool,
    instance       :: Instance,
    original_items :: Vector{Item},
    clearances     :: NamedTuple,
)
    println("\n=== Optimal patterns ===")
    for sheet in instance.sheets
        pattern = generate_pattern_dp_revised_three_staged(instance, sheet.sheet_id; clearances...)
        pattern === nothing && continue
        add_pattern!(pool, pattern, original_items, "Optimal")
    end
end

# For every sheet and every item that can be placed on it, adds the big-M
# pattern for that item to `pool`. Returns, for each sheet id, the big-M pattern
# of each such item together with the item's position in `original_items`. When
# the pattern was already in the pool it is the pool's earlier pattern, so the
# same pattern can be the big-M pattern of more than one item.
function _dichotomic_bigM_step!(
    pool           :: PatternPool,
    instance       :: Instance,
    original_items :: Vector{Item},
    epsilon        :: Float64,
    clearances     :: NamedTuple,
)::Dict{Int, Vector{Tuple{Pattern, Int}}}
    println("\n=== Big-M patterns (epsilon $epsilon) ===")
    anchors = Dict{Int, Vector{Tuple{Pattern, Int}}}(
        sheet.sheet_id => Tuple{Pattern, Int}[] for sheet in instance.sheets
    )

    for sheet in instance.sheets
        positions   = placeable_positions(original_items, instance.items, sheet, values(clearances)...)
        sheet_items = original_items[positions]
        weights     = softened_lexmax_weights(sheet_items; epsilon = epsilon)

        for (k, position) in enumerate(positions)
            # Items that can't be placed on this sheet get weight 0
            weighted = weighted_instance(instance, weights[k], sheet_items)
            pattern  = generate_pattern_dp_revised_three_staged(weighted, sheet.sheet_id; clearances...)
            pattern === nothing && continue

            stored, _ = add_pattern!(pool, pattern, original_items,
                                     "Big M, $(original_items[position].name)")
            push!(anchors[sheet.sheet_id], (stored, position))
        end
    end

    return anchors
end

# --- The search on one sheet ---

# Searches between every pair of the sheet's big-M patterns. `anchors` holds
# each big-M pattern with the position of its item in `original_items`, and
# `n_placeable` is how many items can be placed on the sheet, which sizes the
# share of weight the other items split.
function _dichotomic_search!(
    pool           :: PatternPool,
    instance       :: Instance,
    original_items :: Vector{Item},
    sheet          :: Sheet,
    anchors        :: Vector{Tuple{Pattern, Int}},
    n_placeable    :: Int,
    epsilon        :: Float64,
    clearances     :: NamedTuple,
)
    # An edge is (pattern a, pattern b, item i, item j): a search between a and
    # b on the items i and j. Each edge is queued at most once, since two
    # branches can reach the same middle pattern and produce the same edge.
    queue   = Tuple{Pattern, Pattern, Int, Int}[]
    visited = Set{Tuple{Int, Int, Int, Int}}()

    function queue_edge!(a::Pattern, b::Pattern, i::Int, j::Int)
        key = (a.pattern_id, b.pattern_id, i, j)
        key in visited && return
        push!(visited, key)
        push!(queue, (a, b, i, j))
    end

    for idx_a in 1:length(anchors), idx_b in (idx_a + 1):length(anchors)
        (a, i), (b, j) = anchors[idx_a], anchors[idx_b]
        # The same pattern can be the big-M pattern of two items, and there is
        # nothing between a pattern and itself
        (i == j || a.pattern_id == b.pattern_id) && continue
        queue_edge!(a, b, i, j)
    end

    while !isempty(queue)
        a, b, i, j = popfirst!(queue)

        lambda = dichotomic_lambda_pair(
            objective_vector(a, original_items), objective_vector(b, original_items),
            i, j, length(original_items); epsilon = epsilon, n_override = n_placeable)
        lambda === nothing && continue

        weighted = weighted_instance(instance, lambda, original_items)
        pattern  = generate_pattern_dp_revised_three_staged(weighted, sheet.sheet_id; clearances...)
        pattern === nothing && continue

        middle, _ = add_pattern!(pool, pattern, original_items,
                                 "Dichotomic (P$(a.pattern_id), P$(b.pattern_id), items $i-$j)")

        # The result is one of the ends, so nothing lies between them
        middle.pattern_id in (a.pattern_id, b.pattern_id) && continue

        # Otherwise search on from the result, whether it is new or was
        # already in the pool
        queue_edge!(a, middle, i, j)
        queue_edge!(middle, b, i, j)
    end
end

# --- Entry point ---

"""
    dichotomic_pattern_generation(instance; clearance=0.0, clearance_left=0.0,
                                  clearance_right=0.0, clearance_top=0.0,
                                  clearance_bottom=0.0,
                                  epsilon=DEFAULT_LEXMAX_EPSILON,
                                  track_origins=false)

Patterns for every sheet from the optimum, the big-M patterns and the
dichotomic search between them, as described at the top of this file. `epsilon`
is the share of weight the big-M patterns, and the items outside each searched
pair, are given.

Returns the patterns, numbered 1, 2, ... in the order kept: the optimal ones,
then the big-M ones, then the dichotomic ones. With `track_origins = true` it
returns `(patterns, (first_bigm_pattern_id, first_dichotomic_pattern_id))`
instead. Each pattern's `.value` is the value of its items at the true values.

Each pattern kept is printed with its value and sheet waste, and the run ends with the
lowest, mean and highest sheet waste among them.
"""
function dichotomic_pattern_generation(
    instance         :: Instance;
    clearance        :: Real    = 0.0,
    clearance_left   :: Real    = 0.0,
    clearance_right  :: Real    = 0.0,
    clearance_top    :: Real    = 0.0,
    clearance_bottom :: Real    = 0.0,
    epsilon          :: Float64 = DEFAULT_LEXMAX_EPSILON,
    track_origins    :: Bool    = false,
)
    clearances = (clearance = clearance, clearance_left = clearance_left,
                  clearance_right = clearance_right, clearance_top = clearance_top,
                  clearance_bottom = clearance_bottom)
    original_items = filter(i -> !i.rotated, instance.items)
    pool = PatternPool(instance)

    # --- Optimal and big M ---
    _dichotomic_optimal_step!(pool, instance, original_items, clearances)
    first_bigm_pattern_id = length(pool.patterns) + 1

    anchors = _dichotomic_bigM_step!(pool, instance, original_items, epsilon, clearances)
    first_dichotomic_pattern_id = length(pool.patterns) + 1

    # --- Dichotomic search, sheet by sheet ---
    for sheet in instance.sheets
        println("\n=== Dichotomic search, sheet $(sheet.sheet_id) ===")
        n_placeable = length(placeable_positions(original_items, instance.items, sheet, values(clearances)...))
        _dichotomic_search!(pool, instance, original_items, sheet, anchors[sheet.sheet_id],
                            n_placeable, epsilon, clearances)
        println("Patterns so far: $(length(pool.patterns))")
    end

    print_pattern_summary(pool.patterns, instance)

    track_origins || return pool.patterns
    return pool.patterns, (first_bigm_pattern_id       = first_bigm_pattern_id,
                           first_dichotomic_pattern_id = first_dichotomic_pattern_id)
end
