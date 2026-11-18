# Full-pack heuristic: for every sheet and every item, the pattern made by
# packing as many copies of that one item as fit, in a uniform grid of rows
# and columns. Each column holds a single copy (no stacking).
#
# Without clearance the count along each axis is the sheet length divided by
# the item length, rounded down, so the pattern holds floor(W / w) columns by
# floor(H / h) rows.
#
# Clearance is all or nothing: either none whatsoever, or on everything. If the
# gap and the four edge clearances are all 0 there is none. Otherwise the gap
# between neighbouring copies and the margin at every sheet edge must all be
# above 0. They need not be equal, so each edge can have its own margin, but no
# edge is free and there is never room to spread. Anything in between, such as
# a gap with free edges, is an error. The grid starts at the margin from the
# left and bottom edges, and the room left over is on the right and at the top.
#
# Rotation is all or nothing. Without it every pattern places the item as it
# is listed. With it, each item also gets a second pattern with every copy
# rotated through 90 degrees. Copies are never mixed: a pattern is a grid of
# one item in one orientation.
#
# The grid and the clearance values are read as the revised three-staged DP
# reads them (clearance_grid), so for one item type the full pack and that DP,
# given the same gap and edge values, always agree on how many copies fit.
#
# A pattern's `.value` is the value of its items, as in the other generators,
# so the patterns can be pooled with theirs.
#
# The result holds structure only (shelves, stacks and item counts), not
# coordinates. Code that places the items starts the grid at the left and
# bottom margins and keeps exactly the gap between neighbours.
#
# Requires: clearance_grid, all_or_no_clearance (helper/grid_scale.jl),
#           build_pattern (helper/build_pattern.jl),
#           report_pattern, print_pattern_summary (helper/reporting.jl),
#           Item, Sheet, Slot, Shelf, Pattern, Instance, expand_with_rotations
#           (helper/structs.jl)

# --- Copies along one axis ---

"""
    _fullpack_count(usable, item_length, gap) -> Int

How many copies of an item of length `item_length` fit along an axis of usable
length `usable` (the sheet length less the two edge margins), with `gap`
between neighbours. All values are whole numbers.

n copies need n * item_length + (n - 1) * gap. Count each copy as its own
length plus one gap, and give the usable length one extra gap to make up for
the last copy having none. That turns the sum into a plain division:

    n = floor((usable + gap) / (item_length + gap))

Returns 0 if no copy fits.
"""
function _fullpack_count(usable::Int, item_length::Int, gap::Int)::Int
    usable < item_length && return 0
    return (usable + gap) ÷ (item_length + gap)
end

# --- One pattern ---

"""
    generate_pattern_fullpack(instance, sheet_id, part_id; clearance=0.0,
                              clearance_left=0.0, clearance_right=0.0,
                              clearance_top=0.0, clearance_bottom=0.0,
                              report=false) -> Union{Pattern, Nothing}

The full-pack pattern of the item with part id `part_id` on sheet `sheet_id`:
as many copies as fit, in a grid, all in the orientation the item is listed
in. A rotated form is a separate item in `instance.items`, so its pattern
comes from its own part id.

Clearances are in the same units as item and sheet dimensions, and need not be
whole numbers:
  - `clearance` is the gap between neighbouring copies.
  - `clearance_left`, `clearance_right`, `clearance_top` and
    `clearance_bottom` are the margins at each sheet edge. Nothing is placed
    within a margin of its edge.

Clearance is all or nothing. Either all five values are 0, or all five are
above 0 (they need not be equal). Anything else, such as a gap with free edges,
is an error: for those use the DP (generate_pattern_dp_revised_three_staged).

The returned `.value` is the value of the copies placed. The pattern holds
structure only: start the grid at the left and bottom margins, with exactly the
gap between neighbours.

With `report = true`, prints one line giving the pattern's item value and its
sheet waste, the leftover area of the sheet as a share of its area.

Returns `nothing` if the item does not fit the sheet even once.
"""
function generate_pattern_fullpack(
    instance         :: Instance,
    sheet_id         :: Int,
    part_id          :: Int;
    clearance        :: Real = 0.0,
    clearance_left   :: Real = 0.0,
    clearance_right  :: Real = 0.0,
    clearance_top    :: Real = 0.0,
    clearance_bottom :: Real = 0.0,
    report           :: Bool = false,
)::Union{Pattern, Nothing}
    sheet_idx = findfirst(s -> s.sheet_id == sheet_id, instance.sheets)
    sheet_idx === nothing && error("Sheet ID $sheet_id not found")
    item_idx = findfirst(i -> i.part_id == part_id, instance.items)
    item_idx === nothing && error("Part ID $part_id not found")

    sheet = instance.sheets[sheet_idx]
    item  = instance.items[item_idx]
    grid  = clearance_grid(instance, sheet, clearance, clearance_left, clearance_right,
                           clearance_top, clearance_bottom)

    all_or_no_clearance(grid) ||
        error("the full pack takes either no clearance at all or clearance on the gap and on every edge")

    # The working sheet is the sheet less the margin on each side
    (grid.W <= 0 || grid.H <= 0) && return nothing

    n_columns = _fullpack_count(grid.W, round(Int, item.width  * grid.scale), grid.t)
    n_rows    = _fullpack_count(grid.H, round(Int, item.height * grid.scale), grid.t)

    # The item does not fit this sheet even once
    (n_columns == 0 || n_rows == 0) && return nothing

    # One slot is one column holding a single copy of the item (no stacking).
    # A shelf is one row of columns, repeated for every row up the sheet.
    n_parts = maximum(i.part_id for i in instance.items)
    slot    = Slot(n_parts, item.part_id, 1)

    shelf_item_counts = zeros(Int, n_parts)
    shelf_item_counts[item.part_id] = n_columns
    shelf = Shelf(fill(slot, n_columns), shelf_item_counts)

    # A rotated copy is worth the same as the item it was rotated from
    original = instance.items[findfirst(i -> i.part_id == item.original_part_id, instance.items)]
    value    = original.value * n_columns * n_rows

    pattern = build_pattern(0, sheet.sheet_id, value, fill(shelf, n_rows), instance.items)
    report && report_pattern("Full pack of $(item.name)", pattern, instance)
    return pattern
end

# --- One pattern for every sheet and item ---

# The items to pack. Without rotation, only the items as listed. With it,
# every item and its rotated form: an instance that already holds the rotated
# forms is used as it is, and otherwise they are added with
# expand_with_rotations, which gives them the same part ids it always does.
function _fullpack_items(items::Vector{Item}, allow_rotation::Bool)::Vector{Item}
    allow_rotation || return filter(i -> !i.rotated, items)
    return any(i -> i.rotated, items) ? items : expand_with_rotations(items)
end

"""
    fullpack_pattern_generation(instance; clearance=0.0, clearance_left=0.0,
                                clearance_right=0.0, clearance_top=0.0,
                                clearance_bottom=0.0, allow_rotation=false,
                                report=false) -> Vector{Pattern}

One full-pack pattern for every (sheet, item) pair where the item fits. With
`allow_rotation`, every item is also packed rotated through 90 degrees, as a
second pattern for the same pair: each pattern is a grid of one item in one
orientation, never a mix. Square items have no rotated form.

Without `allow_rotation`, rotated items already in `instance.items` are
ignored. With it, an instance that does not hold rotated forms gets them
added, numbered as `expand_with_rotations` numbers them.

The clearance keywords work as in `generate_pattern_fullpack`: none at all, or
on the gap and every edge. The patterns are numbered 1, 2, ... in the order
found, so they can be pooled with those of the other generators.

With `report = true`, prints each pattern with its item value and sheet waste,
then the lowest, mean and highest sheet waste among them.
"""
function fullpack_pattern_generation(
    instance         :: Instance;
    clearance        :: Real = 0.0,
    clearance_left   :: Real = 0.0,
    clearance_right  :: Real = 0.0,
    clearance_top    :: Real = 0.0,
    clearance_bottom :: Real = 0.0,
    allow_rotation   :: Bool = false,
    report           :: Bool = false,
)::Vector{Pattern}
    packing_instance = Instance(_fullpack_items(instance.items, allow_rotation), instance.sheets)
    patterns = Pattern[]

    for sheet in packing_instance.sheets
        for item in packing_instance.items
            pattern = generate_pattern_fullpack(
                packing_instance, sheet.sheet_id, item.part_id;
                clearance        = clearance,
                clearance_left   = clearance_left,
                clearance_right  = clearance_right,
                clearance_top    = clearance_top,
                clearance_bottom = clearance_bottom,
            )
            pattern === nothing && continue

            push!(patterns, Pattern(length(patterns) + 1, pattern.sheet_id, pattern.value, pattern.shelves,
                                    pattern.item_counts, nothing, pattern.aligned_far))
            report && report_pattern("Full pack of $(item.name)", patterns[end], packing_instance)
        end
    end

    report && print_pattern_summary(patterns, packing_instance)
    return patterns
end
