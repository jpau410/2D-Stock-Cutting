# The revised three-stage guillotine DP: the basic three-stage DP
# (three-staged_dp.jl) with clearance and speed-ups added. It finds the best
# guillotine pattern for one sheet, with no limit on how many copies of an item
# are used.
#
# A pattern is a stack of shelves, a shelf is a row of stacks side by side, and
# a stack is a column of items. Each stage is a knapsack over the one before
# it, as in the basic DP:
#
#   Stage 1, Stack DP:   f(w, h) = best value of one stack of width w and
#                        height exactly h.
#   Stage 2, Shelf DP:   g(w, h) = best value of a shelf of height h, made of
#                        stacks placed side by side across width w.
#   Stage 3, Pattern DP: q(h) = best value of a pattern of height h, made of
#                        shelves stacked on the working sheet.
#
# Clearance: neighbouring items, stacks and shelves are kept at least t apart,
# where t is the `clearance` keyword, and each sheet edge has its own rule. The
# DP always uses exactly t between neighbours and presses everything against
# the left and bottom edges, so any room left over is on the right and at the
# top. When the pattern is placed, that room is moved to where the edge rules
# need it. The rules, and how to place a pattern, are in the docstring of
# generate_pattern_dp_revised_three_staged.
#
# Speed-ups: the basic DP evaluates every whole-number width and height. This
# DP only evaluates the sizes a layout can reach, which are sums of item sizes
# with a gap of t between neighbours:
#
#   1. Reachable heights:         stacks and shelves are only evaluated at
#                                 heights that are sums of item heights.
#   2. Stack widths from items:   stacks are only evaluated at the width of
#                                 some item.
#   3. Reachable shelf widths:    shelves are only evaluated at widths that
#                                 are sums of item widths.
#   4. Reachable pattern heights: the pattern DP is only evaluated at heights
#                                 that are sums of shelf heights.
#   5. Changed heights only:      the shelf DP is only solved at heights where
#                                 some stack width gets a better stack. At any
#                                 other height the best shelf is the one at the
#                                 height below with empty room above it, which
#                                 is never needed.
#   6. Clean shelves only:        only shelves that are tight and can't be split
#                                 into two shelves are stored (see "Clean
#                                 shelves").
#
# None of the speed-ups changes a value, and each can be switched off (see
# RevisedSpeedups).
#
# Time limit: the generator takes an optional `time_limit`, and checks the clock
# once for each width of the Stack DP, each height of the Shelf DP and each
# height of the Pattern DP. When the time is up it stops with TimeLimitExceeded
# (helper/structs.jl).
#
# Ties: many layouts have exactly the same value. The DP tries parts, stacks and
# shelves biggest first and keeps the first of equally good options (values
# within DP_TIE_TOLERANCE), the narrowest shelf and the shortest pattern. So the
# result does not depend on the order the items are given in.
#
# All dimensions and clearance values are scaled to whole numbers first (see
# grid_scale).
#
# Requires: grid_scale, clearance_grid, item_placeable (helper/grid_scale.jl),
#           build_pattern (helper/build_pattern.jl),
#           report_pattern (helper/reporting.jl),
#           Item, Sheet, Shelf, Slot, Pattern, Instance, Deadline, check_deadline
#           (helper/structs.jl),
#           DP_TIE_TOLERANCE (src/constants.jl)

# --- Speed-up switches ---

"""
    RevisedSpeedups(; reachable_heights=true, stack_widths_from_items=true,
                    reachable_shelf_widths=true, reachable_pattern_heights=true,
                    changed_heights_only=true, clean_shelves_only=true)
    RevisedSpeedups(on::Bool)

Which of the six speed-ups listed at the top of this file the DP uses, in the
same order. A speed-up that is switched off makes the DP do the plain work it
replaces. No switch changes a value, only the time (and which of several equally
good patterns is kept). `RevisedSpeedups(false)` switches every one off, which
is the basic DP's plain work and only suits small sheets.
  - `reachable_heights`:         off, stacks and shelves are evaluated at every
                                 whole-number height
  - `stack_widths_from_items`:   off, stacks are evaluated at every whole-number
                                 width
  - `reachable_shelf_widths`:    off, shelves are evaluated at every whole-number
                                 width
  - `reachable_pattern_heights`: off, the pattern DP is evaluated at every
                                 whole-number height
  - `changed_heights_only`:      off, the shelf DP is solved at every height
  - `clean_shelves_only`:        off, every solved shelf is stored
"""
Base.@kwdef struct RevisedSpeedups
    reachable_heights         :: Bool = true
    stack_widths_from_items   :: Bool = true
    reachable_shelf_widths    :: Bool = true
    reachable_pattern_heights :: Bool = true
    changed_heights_only      :: Bool = true
    clean_shelves_only        :: Bool = true
end

RevisedSpeedups(on::Bool) = RevisedSpeedups(on, on, on, on, on, on)

# --- Scaling and working sheet ---

"""
    _revised_geometry(instance, sheet; clearance=0.0, clearance_left=0.0,
                      clearance_right=0.0, clearance_top=0.0,
                      clearance_bottom=0.0, speedups=RevisedSpeedups())
        -> Union{NamedTuple, Nothing}

Everything the DP needs before it starts, in whole-number units: the scaled
instance, the items the DP may use, the working sheet (the sheet less each
mandatory edge margin), the gap `t` and the four edge margins, and the sizes
the speed-ups 1 to 3 evaluate (every whole-number size if that speed-up is
switched off).

The items the DP may use (`usable_items`) are the ones that can be placed on
this sheet at all (see item_placeable). `instance_scaled` keeps every item, so
part ids keep their meaning in the count vectors.

The generator below starts here, and reads the clearance keywords this way.

Returns `nothing` if the edge margins leave no usable area.
"""
function _revised_geometry(
    instance         :: Instance,
    sheet            :: Sheet;
    clearance        :: Real = 0.0,
    clearance_left   :: Real = 0.0,
    clearance_right  :: Real = 0.0,
    clearance_top    :: Real = 0.0,
    clearance_bottom :: Real = 0.0,
    speedups         :: RevisedSpeedups = RevisedSpeedups(),
)::Union{NamedTuple, Nothing}
    grid = clearance_grid(instance, sheet, clearance, clearance_left, clearance_right,
                          clearance_top, clearance_bottom)
    (grid.W <= 0 || grid.H <= 0) && return nothing

    items_scaled = [Item(i.part_id, i.original_part_id, i.name, i.demand, i.value,
                         i.width  * grid.scale,
                         i.height * grid.scale,
                         i.rotated) for i in instance.items]
    usable_items = filter(i -> item_placeable(round(Int, i.width), round(Int, i.height), grid),
                          items_scaled)

    # Shelf widths are sums of the real item widths, even when stacks are
    # evaluated at every width
    real_widths       = _revised_item_widths(usable_items)
    reachable_heights = speedups.reachable_heights       ? _revised_reachable_heights(usable_items, grid.H, grid.t) : collect(0:grid.H)
    item_widths       = speedups.stack_widths_from_items ? real_widths : collect(1:grid.W)
    reachable_widths  = speedups.reachable_shelf_widths  ? _revised_reachable_widths(real_widths, grid.W, grid.t) : collect(0:grid.W)

    return (
        instance_scaled   = Instance(items_scaled, instance.sheets),
        usable_items      = usable_items,
        sheet_scaled      = Sheet(sheet.sheet_id, sheet.capacity, Float64(grid.W), Float64(grid.H)),
        reachable_heights = reachable_heights,
        item_widths       = item_widths,
        reachable_widths  = reachable_widths,
        t = grid.t, t_left = grid.t_left, t_right = grid.t_right,
        t_top = grid.t_top, t_bottom = grid.t_bottom,
    )
end

# --- Reachable sizes ---

"""
    _revised_reachable_sums(units, limit, t) -> Vector{Int}

Every total up to `limit` that can be built from values in `units`, with a
gap of `t` between neighbours. A total x is reachable if it equals a single
unit u (the first element, no gap before it), or if x - t - u is itself a
reachable total above 0 (a later element, gap t before it).

Used for three kinds of total:
  - stack heights:   the units are item heights
  - shelf widths:    the units are item widths (see _revised_item_widths)
  - pattern heights: the units are stack heights, since a shelf is always
                     as tall as some stack

Returns a sorted vector that always includes 0.
"""
function _revised_reachable_sums(units::Vector{Int}, limit::Int, t::Int)::Vector{Int}
    reachable    = falses(limit + 1)
    reachable[1] = true  # 0 always reachable

    for x in 1:limit
        for u in units
            u > x && continue

            # First element, no gap before it
            if u == x
                reachable[x + 1] = true
                break
            end

            # Later element, gap t before it
            x_rest = x - t - u
            if x_rest > 0 && reachable[x_rest + 1]
                reachable[x + 1] = true
                break
            end
        end
    end
    return [x for x in 0:limit if reachable[x + 1]]
end

"""
    _revised_reachable_heights(items, H, t) -> Vector{Int}

Every stack height up to `H`: sums of item heights, with a gap of `t`
between stacked items. Speed-up 1.
"""
function _revised_reachable_heights(items::Vector{Item}, H::Int, t::Int)::Vector{Int}
    heights = unique(round(Int, i.height) for i in items)
    return _revised_reachable_sums(heights, H, t)
end

"""
    _revised_item_widths(items) -> Vector{Int}

The distinct item widths, sorted. A stack's width is always a single item
width, never a sum, so these are the only stack widths the DP needs.
Speed-up 2.
"""
function _revised_item_widths(items::Vector{Item})::Vector{Int}
    return sort(unique(round(Int, i.width) for i in items))
end

"""
    _revised_reachable_widths(item_widths, W, t) -> Vector{Int}

Every shelf width up to `W`: sums of stack widths, with a gap of `t` between
neighbouring stacks. The Shelf DP only evaluates these widths. Speed-up 3.
"""
function _revised_reachable_widths(item_widths::Vector{Int}, W::Int, t::Int)::Vector{Int}
    return _revised_reachable_sums(item_widths, W, t)
end

"""
    _revised_reachable_pattern_heights(shelf_heights, H, t) -> Vector{Int}

Every pattern height up to `H`: sums of the given shelf heights, with a gap of
`t` between stacked shelves. The Pattern DP only evaluates these heights.
Speed-up 4.
"""
function _revised_reachable_pattern_heights(shelf_heights::Vector{Int}, H::Int, t::Int)::Vector{Int}
    return _revised_reachable_sums(filter(h -> h > 0, shelf_heights), H, t)
end

# --- Clean shelves ---
#
# The shelf DP stores a shelf only if it is clean:
#   - tight: its tallest stack is as tall as the shelf. A taller shelf is the
#     same content with empty room above it, and the tight one at the lower
#     height is always at least as good.
#   - not splittable: no full-width cut, t thick, can run between the parts of
#     every stack. If one can, the shelf is really two shelves, one above the
#     other, and the Pattern DP builds that pair from the two shorter shelves,
#     which are each at least as good.
# Leaving the others out loses nothing, and the Pattern DP no longer tries many
# copies of the same layout.
#
# A stack stores counts only, so its parts can go in any order. A set of parts
# has key = sum of (part height + t), so the set is key - t tall. A shelf of
# height h splits at cut c (bottom shelf c tall, top shelf h - c - t tall) if
# every stack can be divided into a bottom set and a top set that fit. A stack
# with total key K and a bottom set of key k fits if k <= c + t (the bottom set
# fits below the cut) and K - k <= h - c (the top set fits above it). A stack
# that fits wholly below or wholly above the cut needs no division. The tallest
# stack always has to be divided, so the only cuts to try are its subset keys.

# Each part's whole-number height, indexed by part_id
function _revised_part_heights(items::Vector{Item})::Vector{Int}
    heights = zeros(Int, maximum(i.part_id for i in items))
    for item in items
        heights[item.part_id] = round(Int, item.height)
    end
    return heights
end

# A stack's total key, and the sorted keys of every nonempty proper subset of
# its parts
function _revised_stack_keys(slot::Slot, part_height::Vector{Int}, t::Int)::Tuple{Int, Vector{Int}}
    subset_keys = Set([0])
    total       = 0
    for (part_id, count) in enumerate(slot.counts)
        count == 0 && continue
        step         = part_height[part_id] + t
        subset_keys  = Set(k + m * step for k in subset_keys, m in 0:count)
        total       += count * step
    end
    return total, sort!(collect(setdiff(subset_keys, (0, total))))
end

# Whether a shelf of height h can be split into two shelves by a full-width cut
function _revised_can_split(
    shelf       :: Shelf,
    h           :: Int,
    part_height :: Vector{Int},
    t           :: Int,
    key_cache   :: Dict{Vector{Int}, Tuple{Int, Vector{Int}}},
)::Bool
    stacks  = [get!(() -> _revised_stack_keys(slot, part_height, t), key_cache, slot.counts) for slot in shelf.items]
    tallest = argmax(first.(stacks))

    for cut_key in stacks[tallest][2]
        c = cut_key - t
        fits = all(stacks) do (total, subset_keys)
            stack_h = total - t
            (stack_h <= c || stack_h <= h - c - t) && return true      # wholly below or wholly above the cut
            i = searchsortedfirst(subset_keys, total - (h - c))         # divided between two of its parts
            return i <= length(subset_keys) && subset_keys[i] <= c + t
        end
        fits && return true
    end
    return false
end

# --- Stage 1: Stack DP ---
#
# f(w, h) = best value of a stack of width w and height exactly h, with a gap
# of t between stacked items:
#
#   f(w, 0) = 0
#   f(w, h) = max over items with item.width <= w of:
#               item.value                                   if h == item.height
#               f(w, h - t - item.height) + item.value       if h - t - item.height > 0
#
# The first case is the bottom item (no gap below it). The second puts an
# item on top of a smaller stack. An unreachable height stays at -Inf.
# Evaluated only at w in item_widths and h in reachable_heights.
#
# The step back during traceback is item.height for the bottom item but
# t + item.height for any other, so each height's predecessor is stored
# directly in prev_h.
#
# Ties: parts are tried tallest first, then widest, then by part_id, and a
# later part only replaces the current best if it is better by more than
# DP_TIE_TOLERANCE (src/constants.jl). So among equally good stacks the one
# kept uses the biggest parts, whatever order the items came in.

function _revised_solve_stack_dp(
    items             :: Vector{Item},
    n_parts           :: Int,
    reachable_heights :: Vector{Int},
    item_widths       :: Vector{Int},
    H                 :: Int,
    t                 :: Int;
    deadline          :: Deadline = Deadline(Inf),
)::Tuple{Dict{Tuple{Int,Int},Float64}, Dict{Tuple{Int,Int},Slot}}

    f_cache     = Dict{Tuple{Int,Int}, Float64}()   # (w, h) -> f(w, h)
    stack_cache = Dict{Tuple{Int,Int}, Slot}()       # (w, h) -> Slot achieving f(w, h)

    for w in item_widths
        check_deadline(deadline)
        eligible = sort([i for i in items if round(Int, i.width) <= w],
                        by = i -> (-round(Int, i.height), -round(Int, i.width), i.part_id))
        isempty(eligible) && continue

        f      = fill(-Inf, H + 1)
        f[1]   = 0.0                # f(w, 0) = 0, stored 1-indexed as f[h+1]
        choice = zeros(Int, H + 1)  # choice[h+1] = part_id of last item placed to reach h
        prev_h = fill(-1, H + 1)    # prev_h[h+1] = height of the stack this item sits on

        # Heights in increasing order, so every smaller stack is already solved.
        for h in reachable_heights
            h == 0 && continue

            for item in eligible
                item_h = round(Int, item.height)
                item_h > h && continue

                # Case 1: item is the bottom of the stack, no gap below it
                if item_h == h
                    val = item.value
                    if val > f[h + 1] + DP_TIE_TOLERANCE
                        f[h + 1]      = val
                        choice[h + 1] = item.part_id
                        prev_h[h + 1] = 0
                    end
                end

                # Case 2: item on top of a smaller stack, gap t between them
                rest_h = h - t - item_h
                if rest_h > 0 && f[rest_h + 1] != -Inf
                    val = f[rest_h + 1] + item.value
                    if val > f[h + 1] + DP_TIE_TOLERANCE
                        f[h + 1]      = val
                        choice[h + 1] = item.part_id
                        prev_h[h + 1] = rest_h
                    end
                end
            end

            f[h + 1] == -Inf && continue

            # Traceback through the stored predecessor heights
            counts = zeros(Int, n_parts)
            hh = h
            while hh > 0 && choice[hh + 1] != 0
                part_id          = choice[hh + 1]
                counts[part_id] += 1
                hh               = prev_h[hh + 1]
            end

            f_cache[(w, h)]     = f[h + 1]
            stack_cache[(w, h)] = Slot(counts)
        end
    end

    return f_cache, stack_cache
end

# --- Stage 2: Shelf DP ---
#
# g(w, h) = best value of a shelf of height h and width w, made of stacks
# side by side with a gap of t between neighbours. A stack can be shorter
# than its shelf (the space above it is waste), so each stack of width w'
# contributes its best value at any height up to h:
#
#   f_star(w', h) = max over h' <= h of f(w', h')
#
# Then, for each stack width w' in item_widths:
#
#   g(0, h) = 0
#   g(w, h) = max over w' of:
#               f_star(w', h)                      if w' == w
#               g(w - t - w', h) + f_star(w', h)   if w - t - w' > 0
#
# The first case is the first stack on the shelf (no gap before it). The
# second places a stack beside a narrower shelf.
#
# 0 is both the starting value and a real value, so a separate reach_g flag
# records which widths are actually reachable. Without it, the second case
# could build on a width that no stack ever reached.
#
# Evaluated only at h in reachable_heights and w in reachable_widths.
#
# Ties, as in the Stack DP: f_star keeps the shortest stack among equally good
# ones, stacks are tried widest first, and the read-out takes the narrowest
# width with the best value, so the shelf's content is as tight as it can be
# and any spare width stays as leftover.
#
# Only clean shelves are stored (see "Clean shelves"): a shelf that is not
# tight or can be split is left out.

function _revised_solve_shelf_dp(
    n_parts           :: Int,
    part_height       :: Vector{Int},
    reachable_heights :: Vector{Int},
    item_widths       :: Vector{Int},
    reachable_widths  :: Vector{Int},
    W                 :: Int,
    f_cache           :: Dict{Tuple{Int,Int}, Float64},
    stack_cache       :: Dict{Tuple{Int,Int}, Slot},
    t                 :: Int,
    t_left            :: Int,
    t_right           :: Int;
    speedups          :: RevisedSpeedups = RevisedSpeedups(),
    deadline          :: Deadline = Deadline(Inf),
)::Tuple{Dict{Int,Float64}, Dict{Int,Shelf}}

    g_cache     = Dict{Int, Float64}()   # h -> best shelf value at height h, clean shelves only
    shelf_cache = Dict{Int, Shelf}()
    key_cache   = Dict{Vector{Int}, Tuple{Int, Vector{Int}}}()   # stack counts -> subset keys

    # f_star(w', h) = max over h' <= h of f(w', h'), and h_star is the h' that achieves it.
    # `improved` holds every height where some stack width gets a better stack.
    f_star   = Dict{Tuple{Int,Int}, Float64}()
    h_star   = Dict{Tuple{Int,Int}, Int}()
    improved = Set{Int}()

    for stack_w in item_widths
        best_val = -Inf
        best_h   = -1
        for h in reachable_heights
            if haskey(f_cache, (stack_w, h)) && f_cache[(stack_w, h)] > best_val + DP_TIE_TOLERANCE
                best_val = f_cache[(stack_w, h)]
                best_h   = h
                push!(improved, h)
            end
            if best_h != -1
                f_star[(stack_w, h)] = best_val
                h_star[(stack_w, h)] = best_h
            end
        end
    end

    # The shelf table at height h reads nothing but f_star(., h). At a height
    # where no stack width improved, f_star is the same as at the height below,
    # so its best shelf is the same content with more room above it. Such a
    # height is skipped.
    for h in reachable_heights
        check_deadline(deadline)
        (h == 0 || (speedups.changed_heights_only && !(h in improved))) && continue

        valid_widths = [stack_w for stack_w in Iterators.reverse(item_widths) if haskey(f_star, (stack_w, h))]   # widest first
        isempty(valid_widths) && continue

        g       = zeros(Float64, W + 1)   # g[w+1] = g(w, h)
        reach_g = falses(W + 1)
        reach_g[1] = true                 # w = 0, the empty shelf
        choice  = zeros(Int, W + 1)       # choice[w+1] = stack width placed last to reach w
        prev_w  = fill(-1, W + 1)         # prev_w[w+1] = width of the shelf this stack sits beside

        # w = 0 is the empty shelf, already set above
        for w in reachable_widths
            w == 0 && continue
            for stack_w in valid_widths
                stack_w > w && continue

                # Case 1: first stack on the shelf, no gap before it
                if stack_w == w
                    val = f_star[(stack_w, h)]
                    if !reach_g[w + 1] || val > g[w + 1] + DP_TIE_TOLERANCE
                        g[w + 1]       = val
                        reach_g[w + 1] = true
                        choice[w + 1]  = stack_w
                        prev_w[w + 1]  = 0
                    end
                end

                # Case 2: stack beside a narrower shelf, gap t between them
                rest_w = w - t - stack_w
                if rest_w > 0 && reach_g[rest_w + 1]
                    val = g[rest_w + 1] + f_star[(stack_w, h)]
                    if !reach_g[w + 1] || val > g[w + 1] + DP_TIE_TOLERANCE
                        g[w + 1]       = val
                        reach_g[w + 1] = true
                        choice[w + 1]  = stack_w
                        prev_w[w + 1]  = rest_w
                    end
                end
            end
        end

        # --- Read-out: best shelf width ---
        # Stacks are added from the left, so a shelf of width w is a block
        # flush with the left edge, with W - w left unused beside it. Any
        # mandatory margin is already taken off W by the working sheet, so
        # every reachable w is legal. If only the left side has a margin, the
        # block is put against the right edge instead (aligned_far), so the
        # unused room is on the margin side. If both sides are free, the
        # unused room is moved into the gaps when the pattern is placed (see
        # the docstring of generate_pattern_dp_revised_three_staged).
        shelf_aligned_far = t_left > 0 && t_right == 0

        # The narrowest width with the best value wins. reach_g is only ever
        # true at a reachable width, so only those are checked.
        found    = false
        best_w   = W
        best_val = -Inf
        for w in reachable_widths
            if reach_g[w + 1] && (!found || g[w + 1] > best_val + DP_TIE_TOLERANCE)
                best_val = g[w + 1]
                best_w   = w
                found    = true
            end
        end

        found || continue

        # Traceback from the chosen width through the stored predecessor widths
        slots        = Slot[]
        shelf_counts = zeros(Int, n_parts)
        tallest      = 0
        w = best_w
        while w > 0 && choice[w + 1] != 0
            stack_w = choice[w + 1]
            true_h  = h_star[(stack_w, h)]
            slot    = stack_cache[(stack_w, true_h)]
            push!(slots, slot)
            shelf_counts .+= slot.counts
            tallest = max(tallest, true_h)
            w = prev_w[w + 1]
        end

        isempty(slots) && continue

        # Stored only if clean: tight and not splittable
        shelf = Shelf(slots, shelf_counts, shelf_aligned_far)
        (!speedups.clean_shelves_only ||
            (tallest == h && !_revised_can_split(shelf, h, part_height, t, key_cache))) || continue

        g_cache[h]     = best_val
        shelf_cache[h] = shelf
    end

    return g_cache, shelf_cache
end

# --- Stage 3: Pattern DP ---
#
# q(h) = best value of a pattern of height h on the working sheet width W,
# made of shelves stacked with a gap of t between neighbours. For each shelf
# height h' that has a stored (clean) shelf:
#
#   q(0) = 0
#   q(h) = max over h' of:
#            g(W, h')                      if h' == h
#            q(h - t - h') + g(W, h')      if h - t - h' > 0
#
# The first case is the bottom shelf (no gap below it). The second puts a
# shelf on top of a shorter pattern. Same reach flag and read-out rule as
# the Shelf DP, with bottom as the near edge and top as the far edge.
# Evaluated only at h in reachable_pattern_heights.
#
# Ties: shelves are tried tallest first, ties are handled as in the Stack DP,
# and the read-out takes the shortest height with the best value.
#
# Value: shelves are chosen by item value only, and the returned `.value` is
# that value. Leftover area is not priced here: waste is worked out after
# patterns are selected (helper/wastage.jl).

function _revised_solve_pattern_dp(
    instance          :: Instance,
    usable_items      :: Vector{Item},
    sheet             :: Sheet,
    reachable_heights :: Vector{Int},
    item_widths       :: Vector{Int},
    reachable_widths  :: Vector{Int},
    t                 :: Int,
    t_left            :: Int,
    t_right           :: Int,
    t_bottom          :: Int,
    t_top             :: Int;
    speedups          :: RevisedSpeedups = RevisedSpeedups(),
    deadline          :: Deadline = Deadline(Inf),
)::Union{Pattern, Nothing}

    items   = instance.items   # every item: the patterns are built against all of them
    n_parts = length(items)
    W       = round(Int, sheet.width)
    H       = round(Int, sheet.height)

    # Stage 1, then Stage 2, over the items that can be placed. Each table is
    # complete before the next stage reads it.
    part_height = _revised_part_heights(items)
    f_cache, stack_cache = _revised_solve_stack_dp(usable_items, n_parts, reachable_heights, item_widths, H, t; deadline = deadline)
    g_cache, shelf_cache = _revised_solve_shelf_dp(n_parts, part_height, reachable_heights, item_widths, reachable_widths, W, f_cache, stack_cache, t, t_left, t_right; speedups = speedups, deadline = deadline)

    isempty(g_cache) && return nothing

    # Patterns are built from the stored (clean) shelves only
    shelf_heights             = sort(collect(keys(g_cache)); rev = true)   # tallest shelf first
    reachable_pattern_heights = speedups.reachable_pattern_heights ? _revised_reachable_pattern_heights(shelf_heights, H, t) : collect(0:H)

    q          = zeros(Float64, H + 1)   # q[h+1] = q(h)
    reach_q    = falses(H + 1)
    reach_q[1] = true                    # h = 0, the empty pattern
    choice     = zeros(Int, H + 1)       # choice[h+1] = shelf height placed last to reach h
    prev_h     = fill(-1, H + 1)         # prev_h[h+1] = height of the pattern this shelf sits on

    for h in reachable_pattern_heights
        check_deadline(deadline)
        h == 0 && continue
        for shelf_h in shelf_heights
            shelf_h > h && continue

            # Case 1: bottom shelf of the pattern, no gap below it
            if shelf_h == h
                val = g_cache[shelf_h]
                if !reach_q[h + 1] || val > q[h + 1] + DP_TIE_TOLERANCE
                    q[h + 1]       = val
                    reach_q[h + 1] = true
                    choice[h + 1]  = shelf_h
                    prev_h[h + 1]  = 0
                end
            end

            # Case 2: shelf on top of a shorter pattern, gap t between them
            rest_h = h - t - shelf_h
            if rest_h > 0 && reach_q[rest_h + 1]
                val = q[rest_h + 1] + g_cache[shelf_h]
                if !reach_q[h + 1] || val > q[h + 1] + DP_TIE_TOLERANCE
                    q[h + 1]       = val
                    reach_q[h + 1] = true
                    choice[h + 1]  = shelf_h
                    prev_h[h + 1]  = rest_h
                end
            end
        end
    end

    # --- Read-out: best pattern height ---
    # Same rule as the shelf read-out, with the bottom edge as the near edge
    # and the top edge as the far edge: every reachable height is legal.
    pattern_aligned_far = t_bottom > 0 && t_top == 0

    # The shortest height with the best value wins, so any spare room stays as
    # leftover.
    found    = false
    best_h   = H
    best_val = -Inf

    for h in reachable_pattern_heights
        if reach_q[h + 1] && (!found || q[h + 1] > best_val + DP_TIE_TOLERANCE)
            best_val = q[h + 1]
            best_h   = h
            found    = true
        end
    end

    found || return nothing

    # Traceback from the chosen height through the stored predecessor heights
    all_shelves = Shelf[]
    h = best_h
    while h > 0 && choice[h + 1] != 0
        shelf_h = choice[h + 1]
        push!(all_shelves, shelf_cache[shelf_h])
        h = prev_h[h + 1]
    end

    isempty(all_shelves) && return nothing

    return build_pattern(0, sheet.sheet_id, best_val, all_shelves, items; aligned_far = pattern_aligned_far)
end

# --- Entry point ---

"""
    generate_pattern_dp_revised_three_staged(instance, sheet_id; clearance=0.0,
        clearance_left=0.0, clearance_right=0.0, clearance_top=0.0,
        clearance_bottom=0.0, speedups=RevisedSpeedups(), time_limit=Inf,
        report=false) -> Union{Pattern, Nothing}

Best pattern for sheet `sheet_id` by item value, using the revised three-stage
DP described at the top of this file. There is no limit on how many copies of
an item are used. Rotated forms are separate items in `instance.items`, as in
the other generators.

Clearances are in the same units as item and sheet dimensions, and need not be
whole numbers: the grid the DP works on is as fine as the finest of the item,
sheet and clearance values (see grid_scale). The gap and the edge margins can
each be on or off, in any combination.
  - `clearance` is the gap t between neighbouring items, stacks and shelves.
    Neighbours are at least t apart.
  - `clearance_left`, `clearance_right`, `clearance_top` and
    `clearance_bottom` set each sheet edge's rule. A value V above 0 is a
    mandatory margin: nothing is placed within V of that edge, and the
    working sheet is shrunk by V on that side before solving. A value of 0
    leaves the edge free: a part may sit flush against it, and otherwise
    must be at least `clearance` away, never a thin sliver.

The pattern is compact: everything is pressed against the left and bottom
edges with exactly t between neighbours, so the room left over is on the right
and at the top, where it could be a thin sliver beside a free edge. It is moved
afterwards, when the pattern is placed. The result holds structure only
(shelves, stacks and item counts), not coordinates, so code that places the
items on the sheet must:
  - keep neighbours at least t apart and offset the layout by the mandatory
    edge margins;
  - place a shelf with `aligned_far = true` against the right edge and a
    pattern with `aligned_far = true` against the top edge (set when only the
    left, or only the bottom, edge has a margin);
  - put an item or stack that is narrower or shorter than the block holding it
    against the block's near side, or against its far side if the block
    touches a free far edge;
  - where both edges of an axis are free and the gap is above 0, spread the
    room left over along that axis into the gaps between neighbours, so the
    first block is flush with one edge and the last with the other. Along the
    width that is the stacks of a shelf, up the height it is the shelves of
    the pattern, or the items of a stack if the pattern is a single shelf.

That can always be done, because a block alone on an axis is never left with a
sliver: an item that would be (see item_placeable) is not placed at all, and
two or more blocks can take up the room between them.

The returned `.value` is the value of the items placed. Leftover area is not
priced: waste is worked out after patterns are selected (helper/wastage.jl).

`speedups` (see RevisedSpeedups) switches the speed-ups at the top of this file
on or off. They change the time only, never the value. All are on by default.

`time_limit` is the number of seconds the DP may take, counted from the call.
When it runs out the DP stops with `TimeLimitExceeded` (helper/structs.jl). The
default is no limit.

With `report = true`, prints one line giving the pattern's item value and its
sheet waste, the leftover area of the sheet as a share of its area.

Returns `nothing` if no pattern fits, including when the edge clearances
leave no usable area (a warning is logged then).
"""
function generate_pattern_dp_revised_three_staged(
    instance         :: Instance,
    sheet_id         :: Int;
    clearance        :: Real = 0.0,
    clearance_left   :: Real = 0.0,
    clearance_right  :: Real = 0.0,
    clearance_top    :: Real = 0.0,
    clearance_bottom :: Real = 0.0,
    speedups         :: RevisedSpeedups = RevisedSpeedups(),
    time_limit       :: Real = Inf,
    report           :: Bool = false,
)::Union{Pattern, Nothing}
    deadline = Deadline(time_limit)
    idx = findfirst(s -> s.sheet_id == sheet_id, instance.sheets)
    idx === nothing && error("Sheet ID $sheet_id not found")

    geom = _revised_geometry(instance, instance.sheets[idx];
                             clearance        = clearance,
                             clearance_left   = clearance_left,
                             clearance_right  = clearance_right,
                             clearance_top    = clearance_top,
                             clearance_bottom = clearance_bottom,
                             speedups         = speedups)
    if geom === nothing
        @warn "Sheet $sheet_id too small for its clearance margins"
        return nothing
    end

    pattern = _revised_solve_pattern_dp(geom.instance_scaled, geom.usable_items, geom.sheet_scaled,
                                        geom.reachable_heights, geom.item_widths, geom.reachable_widths,
                                        geom.t, geom.t_left, geom.t_right, geom.t_bottom, geom.t_top;
                                        speedups = speedups, deadline = deadline)
    report && pattern !== nothing && report_pattern("Revised three-staged DP", pattern, instance)
    return pattern
end
