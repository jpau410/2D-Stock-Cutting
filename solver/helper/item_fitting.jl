# Which items can be placed on a sheet at all, under the same clearance rules as
# the revised DP. The diversification methods use it to decide which items to
# build patterns for, so all four filter the same way.
#
# Requires: clearance_grid, item_placeable (helper/grid_scale.jl),
#           Item, Sheet, Instance (helper/structs.jl)

"""
    items_fitting_sheet(items, sheet, clearance, clearance_left,
                        clearance_right, clearance_top, clearance_bottom)
                        -> Vector{Item}

Items that can be placed on `sheet` under the clearance rules of
generate_pattern_dp_revised_three_staged: those that fit inside the working
sheet (the sheet less each mandatory edge margin), and, where both edges of an
axis are free and the gap is above 0, that don't leave a thin sliver of room
beside them (see item_placeable). A rotated form is its own Item with width
and height swapped, so it is checked separately. An item left out here can
never be placed on this sheet.
"""
function items_fitting_sheet(items::Vector{Item}, sheet::Sheet,
                              clearance::Real, clearance_left::Real, clearance_right::Real,
                              clearance_top::Real, clearance_bottom::Real)::Vector{Item}
    grid = clearance_grid(Instance(items, [sheet]), sheet, clearance, clearance_left,
                          clearance_right, clearance_top, clearance_bottom)
    (grid.W <= 0 || grid.H <= 0) && return Item[]

    return filter(i -> item_placeable(round(Int, i.width * grid.scale),
                                      round(Int, i.height * grid.scale), grid), items)
end

"""
    placeable_positions(original_items, items, sheet, clearance, clearance_left,
                        clearance_right, clearance_top, clearance_bottom)
                        -> Vector{Int}

Positions in `original_items` (the unrotated items) of the items that can be
placed on `sheet` (see items_fitting_sheet). A rotated form is its own item in
`items`, so an item counts if the entry for either orientation can be placed.
"""
function placeable_positions(original_items::Vector{Item}, items::Vector{Item}, sheet::Sheet,
                             clearance::Real, clearance_left::Real, clearance_right::Real,
                             clearance_top::Real, clearance_bottom::Real)::Vector{Int}
    placeable_ids = Set(i.original_part_id for i in items_fitting_sheet(
        items, sheet, clearance, clearance_left, clearance_right, clearance_top, clearance_bottom))
    return [k for (k, item) in enumerate(original_items) if item.original_part_id in placeable_ids]
end
