using JuMP

# solve_col_gen_infinite_sheet: the shortest length of roll that meets every
# item's demand, found by column generation over shelves.
#
# The instance holds one sheet, the roll. Its width is the roll width. Its
# height is the tallest shelf that may be cut, not a length: the roll is as long
# as it needs to be, so the sheet's capacity is not used. A shelf is a row of
# stacks across the whole width of the roll, and a stack is a column of items
# one above another. A shelf is as tall as its tallest stack. The roll is cut
# into shelves laid end to end, and the model chooses how many of each shelf to
# cut so that the length of roll used is as small as possible:
#
#     minimise    sum over shelves k of (height_k + clearance) * count_k + clearance
#
#     subject to  sum over shelves k of copies_i_k * count_k >= demand_i   for every item i
#                 count_k >= 0 and whole
#
# copies_i_k is the number of copies of item i on shelf k. Each shelf is charged
# its own height and one gap of `clearance`, and one more gap is added once. So
# for n shelves the length is their heights added up plus clearance * (n + 1): a
# gap between each neighbouring pair of shelves, and a gap at each of the two
# ends of the roll. Demand is met with >=, so cutting for one item can leave
# copies of another over.
#
# --- Clearance ---
#
# Clearance is all or nothing, as it is for the full pack (fullpack_heuristic.jl):
# either the gap and the four edge values are all 0, or all are above 0 (they
# need not be equal), so that no edge is free. A gap with a free edge, or margins
# with no gap, is an error. The free-edge rules of the revised DP (a part flush
# or at least the gap away, spare room moved into the gaps) therefore never apply
# to a roll: every edge is a margin.
#
# Inside a shelf, the gap between stacked items and between neighbouring stacks,
# and the margins at the left and right edges of the roll, are those of the
# revised DP (revised_three-staged_dp.jl). The gap between neighbouring shelves,
# and a gap at each end of the roll, are charged above, in the objective, so n
# shelves have n + 1 gaps in all. The top and bottom values are not what is added
# at the ends. They shrink the sheet as they do in the revised DP: each margin
# comes off the sheet height, so the tallest shelf allowed is the sheet height
# less both margins. Every shelf found could therefore also be cut from a sheet
# of that height with those margins.
#
# --- Column generation ---
#
# The master problem is the model above with the shelf counts continuous, over
# the shelves found so far. Its duals give each item a price: the length that one
# more copy of it saves. A shelf whose items are worth more at those prices than
# the length it takes (its height plus a gap) would shorten the roll, so pricing
# looks for such shelves. That is the stack and shelf stages of the revised DP
# with each item's value replaced by its price. One run gives the best shelf at
# every shelf height up to the tallest allowed, so every possible shelf height is
# priced at once, and there is no pattern stage. A shelf's reduced cost is its
# height plus the gap, less the value of its items at the prices.
#
# Only useful shelves are added. A shelf found is added only if
#   - its reduced cost is below -REDUCED_COST_TOLERANCE, so it would shorten
#     the roll, and
#   - no shelf already held is at least as good: with as many copies of every
#     item and a height no taller. This also keeps a shelf from being added
#     twice.
# A shelf that a new one is at least as good as is dropped from the pool. Demand
# is met with >=, so the better shelf can take its place in any plan. The shelf
# DP stores only clean shelves (tight, and not splittable into two shelves), so
# those are the only ones priced.
#
# The run starts from one shelf for each item that has demand: a row of single
# copies of it. That makes the first master problem feasible. It stops when no
# shelf would shorten the roll, so the LP is solved over every shelf, or at a
# limit.
#
# --- Lower bound ---
#
# With no limit on how many sheets are cut, the bound the other column
# generation files use does not apply. Instead the prices are scaled down by r,
# the most value any shelf has per unit of length at those prices (the largest
# value / (height + clearance)). That makes them feasible for the model over
# every shelf, so
#
#     bound = (sum over items i of price_i * demand_i) / max(1, r) + clearance
#
# is a lower bound on the length of any plan made of shelves no taller than the
# tallest allowed. The shelf DP finds r as it prices, and the bound holds because
# that pricing is exact.
#
# --- The plan ---
#
# If the LP solution is whole it is the plan. If not, the integer programme over
# the shelves found is solved, which is not guaranteed to be the best over all
# shelves, and the plan's gap to the bound is reported. That integer step is the
# one the multi-period model takes, from no start and with the same
# `ip_time_limit`, except that its gap is its own setting, INFINITE_SHEET_IP_REL_GAP, apart
# from MIP_REL_GAP, because the length is a representative figure and not a plan
# to cut (see src/constants.jl).
#
# Roll waste is the area of the roll used (its width times the length used) less
# the area of the items cut. Items cut beyond demand count as used, as in the
# other selection models, and are reported separately.
#
# Requires: Item, Slot, Shelf, Pattern, Instance, Solution, SelectedPattern
#           (helper/structs.jl),
#           build_pattern (helper/build_pattern.jl),
#           clearance_grid, all_or_no_clearance (helper/grid_scale.jl),
#           RevisedSpeedups, _revised_geometry, _revised_part_heights,
#           _revised_solve_stack_dp, _revised_solve_shelf_dp
#           (src/Pattern_Generation/revised_three-staged_dp.jl),
#           _fullpack_count (src/Pattern_Generation/fullpack_heuristic.jl),
#           priced_instance, count_fractional, col_gen_gap, col_gen_note,
#           print_col_gen_outcome, record_col_gen_stats! (helper/col_gen.jl),
#           new_selection_model (helper/ip_model.jl),
#           record_solve_stats! (helper/solve_stats.jl),
#           format_percent (helper/reporting.jl),
#           COLUMN_GENERATION_MAX_ITERATIONS, COLUMN_GENERATION_GAP_TOLERANCE,
#           REDUCED_COST_TOLERANCE, INFINITE_SHEET_IP_REL_GAP (src/constants.jl)

# --- The pool of shelves ---

"""
    ShelfPool

The shelves a column generation run holds: `patterns`, each a pattern of one
shelf, numbered 1, 2, ... in the order held, and `heights`, each shelf's height
in whole-number grid units (its tallest stack).
"""
mutable struct ShelfPool
    patterns :: Vector{Pattern}
    heights  :: Vector{Int}
end

# Whether a shelf with item counts `a_counts` and height `a_height` is at least as
# good as one with `b_counts` and `b_height`: no taller, and at least as many
# copies of every item. A shelf is at least as good as a copy of itself.
function _shelf_dominates(a_counts::Vector{Int}, a_height::Int, b_counts::Vector{Int}, b_height::Int)::Bool
    a_height <= b_height || return false
    @inbounds for i in eachindex(a_counts)
        a_counts[i] >= b_counts[i] || return false
    end
    return true
end

# A shelf's height in whole-number grid units: its tallest stack, where a stack
# is its items' heights added up with a gap of `t` between neighbours. It is
# worked out from the stacks, not read from the table the shelf came from, so it
# is right whichever speed-ups are on.
function _shelf_height(shelf::Shelf, part_height::Vector{Int}, t::Int)::Int
    tallest = 0
    for slot in shelf.items
        n_items = sum(slot.counts)
        n_items == 0 && continue
        stack = sum(slot.counts[p] * part_height[p] for p in eachindex(slot.counts) if slot.counts[p] > 0) +
                t * (n_items - 1)
        tallest = max(tallest, stack)
    end
    return tallest
end

# Adds the `candidates` (each with a `pattern`, a `height` and a `reduced` cost,
# most improving first) that are useful to `pool`, and drops the shelves they are
# at least as good as. A candidate is not added if a shelf already held, or one
# added before it, is at least as good. Returns how many were added and how many
# were dropped. The pool's patterns are numbered again, and given the value of
# their items at the true item values.
function _add_useful_shelves!(pool::ShelfPool, candidates::Vector, original_items::Vector{Item})::Tuple{Int, Int}
    patterns = copy(pool.patterns)
    heights  = copy(pool.heights)
    added    = 0
    dropped  = 0

    for candidate in candidates
        counts = candidate.pattern.item_counts
        any(k -> _shelf_dominates(patterns[k].item_counts, heights[k], counts, candidate.height), eachindex(patterns)) &&
            continue

        beaten = [k for k in eachindex(patterns)
                  if _shelf_dominates(counts, candidate.height, patterns[k].item_counts, heights[k])]
        deleteat!(patterns, beaten)
        deleteat!(heights, beaten)
        dropped += length(beaten)

        shelf_value = sum(item.value * counts[item.original_part_id] for item in original_items; init = 0.0)
        push!(patterns, Pattern(0, candidate.pattern.sheet_id, shelf_value, candidate.pattern.shelves,
                                counts, nothing, candidate.pattern.aligned_far))
        push!(heights, candidate.height)
        added += 1
    end

    added == 0 && return 0, 0
    pool.patterns = [Pattern(k, p.sheet_id, p.value, p.shelves, p.item_counts, nothing, p.aligned_far)
                     for (k, p) in enumerate(patterns)]
    pool.heights  = heights
    return added, dropped
end

# --- What the run reads from the instance ---

# Everything the run needs from the instance and the revised DP, worked out once:
# the geometry in whole-number grid units, the tallest shelf `H` and the working
# width `W`, the items that have demand, and the checks that fail before any
# column is generated. Errors if the instance is not one sheet, if the clearance
# is not all or nothing, if the margins leave no usable area, or if an item with
# demand cannot be placed on the roll.
function _infinite_sheet_setup(
    instance         :: Instance,
    clearance        :: Real,
    clearance_left   :: Real,
    clearance_right  :: Real,
    clearance_top    :: Real,
    clearance_bottom :: Real,
    speedups         :: RevisedSpeedups,
)
    length(instance.sheets) == 1 ||
        error("an infinite sheet instance holds one sheet, the roll, but this one holds $(length(instance.sheets))")
    sheet = instance.sheets[1]

    grid = clearance_grid(instance, sheet, clearance, clearance_left, clearance_right,
                          clearance_top, clearance_bottom)
    all_or_no_clearance(grid) ||
        error("a roll takes either no clearance at all or clearance on the gap and on every edge, with no free edge")

    geom = _revised_geometry(instance, sheet;
                             clearance        = clearance,
                             clearance_left   = clearance_left,
                             clearance_right  = clearance_right,
                             clearance_top    = clearance_top,
                             clearance_bottom = clearance_bottom,
                             speedups         = speedups)
    geom === nothing && error("the margins of the roll leave no usable area")

    original_items = filter(i -> !i.rotated, instance.items)
    demanded       = filter(i -> i.demand > 0, original_items)
    placeable      = Set(i.original_part_id for i in geom.usable_items)
    stuck          = [i.name for i in demanded if !(i.original_part_id in placeable)]
    isempty(stuck) ||
        error("these items have demand but cannot be placed on the roll, which is too narrow for them, or " *
              "too short a sheet height (the tallest shelf allowed) for them: " * join(stuck, ", "))

    return (; geom, sheet, original_items, demanded,
              scale       = grid.scale,
              W           = grid.W,
              H           = grid.H,
              t           = geom.t,
              t_left      = geom.t_left,
              t_right     = geom.t_right,
              n_parts     = length(instance.items),
              part_height = _revised_part_heights(geom.instance_scaled.items))
end

# --- Starting shelves ---

# The pool a run starts from: for each item that has demand, in each orientation
# that can be placed, a shelf of single copies across the roll. These shelves
# make the first master problem feasible.
function _starting_shelves(roll::NamedTuple)::ShelfPool
    pool       = ShelfPool(Pattern[], Int[])
    wanted     = Set(item.original_part_id for item in roll.demanded)
    candidates = NamedTuple[]

    for item in roll.geom.usable_items
        item.original_part_id in wanted || continue
        copies = _fullpack_count(roll.W, round(Int, item.width), roll.t)
        copies == 0 && continue

        slots   = [Slot(roll.n_parts, item.part_id, 1) for _ in 1:copies]
        counts  = zeros(Int, roll.n_parts)
        counts[item.part_id] = copies
        shelf   = Shelf(slots, counts)
        pattern = build_pattern(0, roll.sheet.sheet_id, item.value * copies, [shelf], roll.geom.instance_scaled.items)
        push!(candidates, (pattern = pattern, height = round(Int, item.height), reduced = 0.0))
    end

    _add_useful_shelves!(pool, candidates, roll.original_items)
    return pool
end

# --- Pricing ---

# Prices every shelf height at once. Runs the stack and shelf stages of the
# revised DP with each item's value replaced by its price (`prices`, indexed by
# original part id), which gives the best clean shelf at every shelf height up
# to the tallest allowed. Returns a candidate for each, a `NamedTuple` of the
# shelf's one-shelf `pattern`, its `height` in grid units and its `reduced` cost
# (its length, height plus a gap, less the value of its items at the prices),
# and `best_ratio`, the most value any shelf has per unit of length.
function _price_shelves(roll::NamedTuple, prices::Vector{Float64}, speedups::RevisedSpeedups)
    priced    = priced_instance(roll.geom.instance_scaled, prices)
    placeable = Set(i.part_id for i in roll.geom.usable_items)

    # An item with no price adds no value to any shelf, so the DP leaves it out
    usable = [i for i in priced.items if i.part_id in placeable && i.value > 0]

    f_cache, stack_cache = _revised_solve_stack_dp(usable, roll.n_parts, roll.geom.reachable_heights,
                                                   roll.geom.item_widths, roll.H, roll.t)
    _, shelf_cache = _revised_solve_shelf_dp(roll.n_parts, roll.part_height, roll.geom.reachable_heights,
                                             roll.geom.item_widths, roll.geom.reachable_widths, roll.W,
                                             f_cache, stack_cache, roll.t, roll.t_left, roll.t_right;
                                             speedups = speedups)

    candidates = NamedTuple[]
    best_ratio = 0.0
    for h in sort!(collect(keys(shelf_cache)))
        shelf   = shelf_cache[h]
        height  = _shelf_height(shelf, roll.part_height, roll.t)
        pattern = build_pattern(0, roll.sheet.sheet_id, 0.0, [shelf], roll.geom.instance_scaled.items)
        worth   = sum(prices[i] * pattern.item_counts[i] for i in eachindex(prices); init = 0.0)
        charged = (height + roll.t) / roll.scale
        best_ratio = max(best_ratio, worth / charged)
        push!(candidates, (pattern = pattern, height = height, reduced = charged - worth))
    end
    return candidates, best_ratio
end

# --- The model ---

"""
    build_infinite_sheet_model(instance, patterns, shelf_lengths;
                               clearance = 0.0, relax = false) -> NamedTuple

The model of `solve_col_gen_infinite_sheet` over `patterns`, each a pattern of
one shelf, built but not solved. `shelf_lengths[k]` is the height of the shelf
of `patterns[k]` in the units of the item sizes. With `relax = true` the shelf
counts are continuous, which is the LP relaxation whose duals column generation
reads.

Returns a `NamedTuple` with the `model`, its shelf counts `z`, `demand_rows`
(the demand constraints, by original part id) and `demanded`, the items with
demand. The objective is the roll length: the shelf heights and a gap of
`clearance` between each neighbouring pair and at each of the two ends, which is
the heights plus a gap for each shelf plus one more gap. It is only that length
when at least one shelf is cut, which is so whenever an item has demand.
"""
function build_infinite_sheet_model(
    instance      :: Instance,
    patterns      :: Vector{Pattern},
    shelf_lengths :: AbstractVector{<:Real};
    clearance     :: Real = 0.0,
    relax         :: Bool = false,
)
    length(shelf_lengths) == length(patterns) ||
        error("there must be one shelf length for each pattern, got $(length(shelf_lengths)) for $(length(patterns))")
    n_patterns = length(patterns)
    demanded   = filter(i -> !i.rotated && i.demand > 0, instance.items)

    model = new_selection_model()
    if relax
        @variable(model, z[1:n_patterns] >= 0)
    else
        @variable(model, z[1:n_patterns] >= 0, Int)
    end

    demand_rows = Dict(
        item.original_part_id => @constraint(
            model,
            sum((patterns[p].item_counts[item.original_part_id] * z[p] for p in 1:n_patterns); init = 0.0) >= item.demand,
        )
        for item in demanded
    )

    @objective(model, Min,
        sum(((shelf_lengths[p] + clearance) * z[p] for p in 1:n_patterns); init = 0.0) + clearance)

    return (; model, z, demand_rows, demanded)
end

# --- The solution ---

# Reads a solved `master` (from build_infinite_sheet_model) into a Solution, and
# prints the items and the summary lines under `title`. The shelf counts are
# rounded to whole numbers, so this also reads an LP solution whose counts are
# whole. Returns the `solution`, the `shelves_cut`, the `roll_length` and the
# `waste` figures, a NamedTuple.
function _extract_infinite_sheet_solution(
    instance      :: Instance,
    patterns      :: Vector{Pattern},
    shelf_lengths :: AbstractVector{<:Real},
    master        :: NamedTuple,
    clearance     :: Real;
    title         :: String = "Infinite Sheet Column Generation",
)
    sheet          = instance.sheets[1]
    original_items = filter(i -> !i.rotated, instance.items)
    n_original     = length(original_items)

    selected     = SelectedPattern[]
    raw_produced = zeros(Int, n_original)
    shelves_cut  = 0
    length_sum   = 0.0
    for p in eachindex(patterns)
        quantity = round(Int, value(master.z[p]))
        quantity == 0 && continue
        push!(selected, SelectedPattern(patterns[p].pattern_id, quantity))
        raw_produced .+= patterns[p].item_counts .* quantity
        shelves_cut  += quantity
        length_sum   += (shelf_lengths[p] + clearance) * quantity
    end
    roll_length = shelves_cut > 0 ? length_sum + clearance : 0.0

    # items_produced, which is returned, is capped at demand, and raw_produced is
    # the count actually cut.
    items_produced = [min(raw_produced[item.original_part_id], item.demand) for item in original_items]
    total_profit   = sum(item.value * items_produced[item.original_part_id] for item in original_items; init = 0.0)

    overproduced_units = sum(max(0, raw_produced[item.original_part_id] - item.demand) for item in original_items; init = 0)
    overproduced_value = sum(item.value * max(0, raw_produced[item.original_part_id] - item.demand)
                             for item in original_items; init = 0.0)
    overproduced_area  = sum(item.width * item.height * max(0, raw_produced[item.original_part_id] - item.demand)
                             for item in original_items; init = 0.0)

    roll_area   = sheet.width * roll_length
    placed_area = sum(item.width * item.height * raw_produced[item.original_part_id] for item in original_items; init = 0.0)
    waste_area  = roll_area - placed_area
    waste = (
        roll_area          = roll_area,
        waste_area         = waste_area,
        waste_fraction     = roll_area > 0 ? waste_area / roll_area : 0.0,
        overproduced_units = overproduced_units,
        overproduced_value = overproduced_value,
        overproduced_area  = overproduced_area,
    )

    println("\n=== $title ===")
    for item in original_items
        pid  = item.original_part_id
        over = raw_produced[pid] - item.demand
        (item.demand > 0 || raw_produced[pid] > 0) || continue
        println("$(item.name): cut $(raw_produced[pid]) / demand $(item.demand)" *
                (over > 0 ? " — overproduction: $over" : ""))
    end

    println()
    println("Shelves cut: $shelves_cut, of $(length(selected)) kinds")
    println("Roll length used: $(round(roll_length, digits = 2))")
    println("Roll waste: ", roll_area > 0 ? "$(format_percent(waste.waste_fraction)) of the area of the roll used" :
                                            "none, no roll used")
    println("Value of items produced (not counting overproduction): $(round(total_profit, digits = 2))")
    println("Overproduced, left in storage at the end: $(round(overproduced_units, digits = 2)) items worth ",
            round(overproduced_value, digits = 2))

    return (solution = Solution(total_profit, selected, items_produced),
            shelves_cut = shelves_cut, roll_length = roll_length, waste = waste)
end

# --- The integer programme ---

# Solves the model over `patterns` with whole shelf counts, the way the
# multi-period model does its integer step: from no start, and with the same
# `ip_time_limit` (seconds; `Inf` for none). Only the gap setting differs,
# INFINITE_SHEET_IP_REL_GAP in place of the MIP_REL_GAP that new_selection_model
# sets. Fills `ip_stats` as record_solve_stats! describes. Returns the solved
# model, or `nothing` if it did not end with a plan. A solve that runs out of
# time keeps the best plan found so far, as the multi-period model does; only a
# solve that ends with no plan at all gives `nothing`.
function _solve_infinite_sheet_ip(
    instance      :: Instance,
    patterns      :: Vector{Pattern},
    shelf_lengths :: AbstractVector{<:Real},
    clearance     :: Real,
    ip_stats      :: Dict{String, Any};
    ip_time_limit :: Real = Inf,
)
    ip = build_infinite_sheet_model(instance, patterns, shelf_lengths; clearance = clearance)
    set_optimizer_attribute(ip.model, "mip_rel_gap", INFINITE_SHEET_IP_REL_GAP)
    isfinite(ip_time_limit) && set_time_limit_sec(ip.model, Float64(ip_time_limit))
    optimize!(ip.model)
    record_solve_stats!(ip_stats, ip.model, length(patterns))

    status = termination_status(ip.model)
    if status == MOI.OPTIMAL
        return ip
    elseif status == MOI.TIME_LIMIT && primal_status(ip.model) == MOI.FEASIBLE_POINT
        @warn "The minimum-length integer programme reached its time limit; keeping the best plan found."
        return ip
    end
    @warn "The minimum-length integer programme did not end with a plan: $status"
    return nothing
end

# --- From the master problem to the plan ---

# Everything after the last LP: the note on whether its solution is whole, then
# the plan (the LP's own solution if it is whole, otherwise the integer
# programme over the shelves held), and the result and statistics described in
# solve_col_gen_infinite_sheet. `kind` is `:col_gen` or `:full_pack`, which only
# changes what is printed.
function _infinite_sheet_plan(
    instance        :: Instance,
    roll            :: NamedTuple,
    pool            :: ShelfPool,
    master          :: NamedTuple,
    clearance       :: Real,
    lp_value        :: Real,
    lp_bound        :: Real,
    stop_reason     :: Symbol,
    iterations      :: Int,
    log             :: Vector,
    lp_seconds      :: Real,
    pricing_seconds :: Real,
    stats           :: Union{Nothing, Dict{String, Any}},
    kind            :: Symbol;
    ip_time_limit   :: Real = Inf,
)
    patterns      = pool.patterns
    shelf_heights = pool.heights ./ roll.scale

    n_fractional = count_fractional(master.z)
    if kind == :full_pack
        note = n_fractional == 0 ?
            "Note: the LP solution over the full-pack shelves is whole, so it is the plan. No IP was solved." :
            "Note: the LP solution over the full-pack shelves is fractional ($n_fractional of $(length(patterns)) " *
            "shelf counts are not whole), so they were passed to the minimum-length integer programme."
        println("\nLP over $(length(patterns)) full-pack shelves, length $(round(lp_value, digits = 2)).")
    else
        note = col_gen_note(n_fractional = n_fractional, n_counts = length(patterns), stop_reason = stop_reason,
                            n_patterns = length(patterns), ip_name = "the minimum-length integer programme")
        println("\nLP over $(length(patterns)) shelves after $iterations iterations, length $(round(lp_value, digits = 2)).")
    end
    println(note)

    # The plan: the LP's own solution if it is whole, otherwise the integer
    # programme over the shelves held
    title     = kind == :full_pack ? "Infinite Sheet Full Pack" : "Infinite Sheet Column Generation"
    ip_stats  = Dict{String, Any}()
    ip_status = nothing
    extracted = nothing
    if n_fractional == 0
        extracted  = _extract_infinite_sheet_solution(instance, patterns, shelf_heights, master, clearance; title = title)
        final_step = :lp
        cost       = lp_value
        ip_value   = nothing
    else
        ip         = _solve_infinite_sheet_ip(instance, patterns, shelf_heights, clearance, ip_stats;
                                              ip_time_limit = ip_time_limit)
        ip_status  = get(ip_stats, "termination_status", nothing)
        final_step = :ip
        if ip === nothing
            ip_value = nothing
            cost     = nothing
        else
            extracted = _extract_infinite_sheet_solution(instance, patterns, shelf_heights, ip, clearance; title = title)
            ip_value  = objective_value(ip.model)
            cost      = ip_value
        end
    end
    ip_gap = ip_value === nothing ? nothing : col_gen_gap(ip_value, lp_bound)
    if kind == :full_pack
        cost === nothing || println("\nFull pack: ", final_step == :ip ? "integer programme" : "LP", " length $(round(cost, digits = 2)), ",
                                    "LP lower bound over its shelves $(round(lp_bound, digits = 2)), ",
                                    "$(format_percent(col_gen_gap(cost, lp_bound))) above the bound")
    else
        print_col_gen_outcome(final_step = final_step, cost = cost, lp_bound = lp_bound, stop_reason = stop_reason)
    end

    no_waste = (roll_area = 0.0, waste_area = 0.0, waste_fraction = 0.0,
                overproduced_units = 0, overproduced_value = 0.0, overproduced_area = 0.0)
    result = (
        solution = extracted === nothing ? nothing : extracted.solution,
        patterns = patterns, shelf_heights = shelf_heights, cost = cost,
        lp_value = lp_value, lp_bound = lp_bound, lp_integral = n_fractional == 0, final_step = final_step,
        ip_value = ip_value, ip_gap = ip_gap, ip_status = ip_status,
        stop_reason = stop_reason, iterations = iterations, log = log,
        shelves_cut = extracted === nothing ? 0 : extracted.shelves_cut,
        waste = extracted === nothing ? no_waste : extracted.waste,
        lp_seconds = lp_seconds, pricing_seconds = pricing_seconds, note = note,
    )
    record_col_gen_stats!(stats, result, ip_stats)
    if stats !== nothing
        stats["shelves_cut"]        = result.shelves_cut
        stats["waste_fraction"]     = result.waste.waste_fraction
        stats["overproduced_units"] = result.waste.overproduced_units
    end
    return result
end

# The result when no item has any demand: no roll, no shelves and no cost.
function _no_demand_result(n_original::Int, stats::Union{Nothing, Dict{String, Any}})
    println("No item has any demand, so no roll is needed.")
    result = (
        solution = Solution(0.0, SelectedPattern[], zeros(Int, n_original)), patterns = Pattern[],
        shelf_heights = Float64[], cost = 0.0, lp_value = 0.0, lp_bound = 0.0, lp_integral = true,
        final_step = :lp, ip_value = nothing, ip_gap = nothing, ip_status = nothing, stop_reason = :optimal, iterations = 0,
        log = NamedTuple[], shelves_cut = 0,
        waste = (roll_area = 0.0, waste_area = 0.0, waste_fraction = 0.0,
                 overproduced_units = 0, overproduced_value = 0.0, overproduced_area = 0.0),
        lp_seconds = 0.0, pricing_seconds = 0.0, note = "No item has any demand, so no roll is needed.",
    )
    record_col_gen_stats!(stats, result, Dict{String, Any}())
    return result
end

# --- Entry point ---

"""
    solve_col_gen_infinite_sheet(instance; clearance = 0.0, clearance_left = 0.0,
                                 clearance_right = 0.0, clearance_top = 0.0,
                                 clearance_bottom = 0.0,
                                 speedups = RevisedSpeedups(),
                                 max_iterations = COLUMN_GENERATION_MAX_ITERATIONS,
                                 time_limit = Inf, ip_time_limit = Inf,
                                 gap_tolerance = COLUMN_GENERATION_GAP_TOLERANCE,
                                 stats = nothing) -> NamedTuple

The shortest length of roll that meets every item's demand, by column generation
over shelves (see the file header for the model, the pricing, the shelves that
are kept and the lower bound).

`instance` must hold exactly one sheet, the roll: its width is the roll width,
and its height is the tallest shelf that may be cut. Its capacity is not used.
Rotated forms of an item are separate items in `instance.items` that share its
demand, as in the other selection models. Lengths come out in the units of the
item and sheet sizes.

The clearance keywords have the same meaning as in the revised DP, but clearance
is all or nothing: either all five values are 0, or all five are above 0 (they
need not be equal), so that no edge is free. Anything else, such as a gap with a
free edge, is an error. `clearance` is the gap between neighbouring items, stacks
and shelves, and the length also has one at each end of the roll, so n shelves
take their heights plus `clearance` * (n + 1). `clearance_left` and
`clearance_right` are the margins at the roll's own edges. `clearance_top` and
`clearance_bottom` come off the sheet height, and so off the tallest shelf
allowed, and are not what is added at the ends. `speedups` switches the
revised DP's speed-ups on or off, which changes the time and not the shelves'
values.

The run stops when no shelf would shorten the roll, after `max_iterations` LP
solves, after `time_limit` seconds (checked after each iteration), or, if
`gap_tolerance` is above 0, once the LP's length is within that share of its
lower bound. The shelves found at a stop other than the last are not added, so
the last LP is always the one over the final pool.

An iteration prints its LP length, the number of shelves, how many were added and
dropped, and the lower bound. When the LP is done a note says whether its
solution is whole, and so whether the integer programme was needed. The plan is
then printed, followed by its length against the lower bound.

The integer programme, when one is needed, is the integer step of the
multi-period model: the shelf counts over the shelves held, from no start and
within `ip_time_limit` seconds (`Inf` for none), as in the multi-period model. It
is solved to its own gap, `INFINITE_SHEET_IP_REL_GAP` (src/constants.jl), apart
from `MIP_REL_GAP`, because the length is a representative figure for the
material a year's demand needs and not a plan to cut. If the time limit is
reached, the best plan found so far is kept and `ip_status` says so; a solve that
ends with no plan at all gives a `solution` of `nothing`.

If `stats` is a Dict, it is filled as `record_col_gen_stats!` describes, and
with `shelves_cut`, `waste_fraction` and `overproduced_units`.

Returns a `NamedTuple`:
  - `solution`    :: `Solution`, over `patterns`; `nothing` if the integer
    programme did not solve to optimality. Its `items_produced` is capped at
    demand, as in the multi-period model.
  - `patterns`    :: `Vector{Pattern}`, the shelves held at the end, each a
    pattern of one shelf, numbered from 1; the `solution` refers to these
  - `shelf_heights` :: `Vector{Float64}`, each shelf's height in the units of
    the item sizes
  - `cost`        :: `Float64`, the roll length of the plan; `nothing` if there
    is no plan
  - `lp_value`, `lp_bound` :: `Float64`, the LP's roll length over `patterns` and
    a lower bound on its length over every shelf no taller than the tallest
    allowed; equal when `stop_reason` is `:optimal`
  - `lp_integral` :: `Bool`, whether the LP solution is whole
  - `final_step`  :: `:lp` or `:ip`, where `solution` came from
  - `ip_value`, `ip_gap` :: the integer programme's length and its gap above
    `lp_bound` as a share of the length; `nothing` if none was solved
  - `ip_status`   :: the integer programme's termination status as a string
    (`"OPTIMAL"`, `"TIME_LIMIT"`, ...); `nothing` if none was solved
  - `stop_reason` :: `:optimal`, `:gap`, `:iteration_limit`, `:time_limit` or
    `:stalled`
  - `iterations`  :: `Int`, the LP solves
  - `log`         :: one `NamedTuple` per iteration: `iteration`, `lp_value`,
    `lp_bound`, `patterns`, `new_patterns`, `dropped_patterns`, `lp_seconds`,
    `pricing_seconds`
  - `shelves_cut` :: `Int`, the shelves cut in the plan
  - `waste`       :: `NamedTuple`: `roll_area`, `waste_area`, `waste_fraction`,
    `overproduced_units`, `overproduced_value` and `overproduced_area`
  - `lp_seconds`, `pricing_seconds` :: `Float64`, the time spent in each
  - `note`        :: `String`, the note printed when the LP was done

Errors if `instance` is not one sheet, if the clearance is not all or nothing, if
the margins leave no usable area, or if an item with demand cannot be placed on
the roll.
"""
function solve_col_gen_infinite_sheet(
    instance         :: Instance;
    clearance        :: Real = 0.0,
    clearance_left   :: Real = 0.0,
    clearance_right  :: Real = 0.0,
    clearance_top    :: Real = 0.0,
    clearance_bottom :: Real = 0.0,
    speedups         :: RevisedSpeedups = RevisedSpeedups(),
    max_iterations   :: Int  = COLUMN_GENERATION_MAX_ITERATIONS,
    time_limit       :: Real = Inf,
    ip_time_limit    :: Real = Inf,
    gap_tolerance    :: Real = COLUMN_GENERATION_GAP_TOLERANCE,
    stats            :: Union{Nothing, Dict{String, Any}} = nothing,
)
    max_iterations >= 1 || error("max_iterations must be at least 1, got $max_iterations")
    ip_time_limit > 0 || throw(ArgumentError("the IP time limit must be above 0, got $ip_time_limit"))
    roll =_infinite_sheet_setup(instance, clearance, clearance_left, clearance_right,
                                 clearance_top, clearance_bottom, speedups)
    n_original = length(roll.original_items)

    println("\n=== Infinite Sheet Column Generation ===")

    isempty(roll.demanded) && return _no_demand_result(n_original, stats)

    pool = _starting_shelves(roll)
    println("Started with $(length(pool.patterns)) shelves: a row of single copies for each item with demand.")

    started         = time()
    log             = NamedTuple[]
    stop_reason     = :iteration_limit
    master          = nothing
    iterations      = 0
    lp_value        = NaN
    lp_bound        = NaN
    lp_seconds      = 0.0
    pricing_seconds = 0.0

    for iteration in 1:max_iterations
        iterations = iteration

        # The master problem over the shelves held, and its duals
        step_start = time()
        n_in_lp    = length(pool.patterns)
        master     = build_infinite_sheet_model(instance, pool.patterns, pool.heights ./ roll.scale;
                                                clearance = clearance, relax = true)
        optimize!(master.model)
        termination_status(master.model) == MOI.OPTIMAL ||
            error("the master LP did not solve to optimality: $(termination_status(master.model))")
        lp_value = objective_value(master.model)
        lp_step  = time() - step_start

        # Price every shelf height at the duals
        step_start = time()
        prices = zeros(Float64, n_original)
        for item in roll.demanded
            prices[item.original_part_id] = max(0.0, dual(master.demand_rows[item.original_part_id]))
        end
        candidates, best_ratio = _price_shelves(roll, prices, speedups)
        price_step = time() - step_start

        lp_seconds      += lp_step
        pricing_seconds += price_step

        price_total = sum(prices[item.original_part_id] * item.demand for item in roll.demanded)
        lp_bound    = price_total / max(1.0, best_ratio) + clearance

        improving = [c for c in candidates if c.reduced < -REDUCED_COST_TOLERANCE]
        sort!(improving; by = c -> c.reduced)

        n_new     = 0
        n_dropped = 0
        reason    = nothing
        if isempty(improving)
            reason   = :optimal
            lp_bound = lp_value
        elseif gap_tolerance > 0 && col_gen_gap(lp_value, lp_bound) <= gap_tolerance
            reason = :gap
        elseif time() - started >= time_limit
            reason = :time_limit
        elseif iteration == max_iterations
            reason = :iteration_limit
        else
            n_new, n_dropped = _add_useful_shelves!(pool, improving, roll.original_items)
            n_new == 0 && (reason = :stalled)
        end

        push!(log, (iteration = iteration, lp_value = lp_value, lp_bound = lp_bound, patterns = n_in_lp,
                    new_patterns = n_new, dropped_patterns = n_dropped, lp_seconds = lp_step, pricing_seconds = price_step))
        println("Iteration $iteration: LP length $(round(lp_value, digits = 2)), $n_in_lp shelves, $n_new new, ",
                "$n_dropped dropped, lower bound $(round(lp_bound, digits = 2)) ",
                "(gap $(format_percent(col_gen_gap(lp_value, lp_bound))))")

        if reason !== nothing
            stop_reason = reason
            break
        end
    end

    return _infinite_sheet_plan(instance, roll, pool, master, clearance, lp_value, lp_bound, stop_reason,
                                iterations, log, lp_seconds, pricing_seconds, stats, :col_gen;
                                ip_time_limit = ip_time_limit)
end
