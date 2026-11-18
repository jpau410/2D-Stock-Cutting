# The whole-number grid that the DPs and the full pack work on, and the clearance
# rules read off it. They count and compare in whole numbers, so every sum and
# every "does it fit" test is exact. Sharing these definitions means the revised
# DP and the full pack always read the clearance keywords the same way and agree
# on which items can be placed on a sheet. The two- and three-staged DPs have no
# clearance and use only the scale. The test for all-or-nothing clearance, which
# the full pack and the roll model both require, is here too.
#
# Requires: Item, Sheet, Instance (helper/structs.jl),
#           GRID_MAX_DECIMAL_PLACES (src/constants.jl)

# --- The grid ---

# The fewest decimal places that write `x` exactly, at most
# GRID_MAX_DECIMAL_PLACES. Float noise past that is dropped first.
function _decimal_places(x::Float64)::Int
    x = round(x, digits = GRID_MAX_DECIMAL_PLACES)
    for places in 0:GRID_MAX_DECIMAL_PLACES
        round(x * 10.0^places) / 10.0^places == x && return places
    end
    return GRID_MAX_DECIMAL_PLACES
end

"""
    grid_scale(instance, clearances...) -> Int

The smallest power of 10 that makes every item and sheet dimension in
`instance`, and every clearance value in `clearances`, a whole number.
Multiplying a dimension by it and rounding gives its whole-number size, with
nothing lost.

Clearance values are included so that one finer than the data (2.5 on
whole-number data) is kept exactly. Rounded to the data's grid it could come
out smaller than the gap that was asked for.
"""
function grid_scale(instance::Instance, clearances::Real...)::Int
    max_places = 0
    for item in instance.items
        max_places = max(max_places, _decimal_places(item.width), _decimal_places(item.height))
    end
    for sheet in instance.sheets
        max_places = max(max_places, _decimal_places(sheet.width), _decimal_places(sheet.height))
    end
    for clearance in clearances
        max_places = max(max_places, _decimal_places(Float64(clearance)))
    end

    return 10^max_places
end

# --- The sheet and its clearances on the grid ---

"""
    clearance_grid(instance, sheet, clearance, clearance_left, clearance_right,
                   clearance_top, clearance_bottom) -> NamedTuple

The sheet and the clearance values on the whole-number grid of `grid_scale`:
`scale`, the gap `t`, the four edge margins `t_left`, `t_right`, `t_top` and
`t_bottom`, and the working sheet `W` by `H`. The working sheet is the sheet
less each mandatory edge margin: an edge with clearance 0 is free and takes
nothing off. `W` or `H` is 0 or less if the margins leave no usable area.

Errors if any clearance is negative.
"""
function clearance_grid(
    instance         :: Instance,
    sheet            :: Sheet,
    clearance        :: Real,
    clearance_left   :: Real,
    clearance_right  :: Real,
    clearance_top    :: Real,
    clearance_bottom :: Real,
)
    scale = grid_scale(instance, clearance, clearance_left, clearance_right,
                       clearance_top, clearance_bottom)

    t        = round(Int, clearance        * scale)
    t_left   = round(Int, clearance_left   * scale)
    t_right  = round(Int, clearance_right  * scale)
    t_top    = round(Int, clearance_top    * scale)
    t_bottom = round(Int, clearance_bottom * scale)
    t < 0 && error("clearance must be >= 0")
    (t_left < 0 || t_right < 0 || t_top < 0 || t_bottom < 0) &&
        error("clearance_left/right/top/bottom must all be >= 0")

    return (
        scale = scale,
        t = t, t_left = t_left, t_right = t_right, t_top = t_top, t_bottom = t_bottom,
        W = round(Int, sheet.width  * scale) - t_left - t_right,
        H = round(Int, sheet.height * scale) - t_top   - t_bottom,
    )
end

"""
    all_or_no_clearance(grid) -> Bool

Whether the clearance in `grid` (from `clearance_grid`) is all or nothing: the gap
and the four edge margins are all 0, or all above 0. In the second case no edge is
free, so the free-edge rules (a part flush or at least the gap away, and spare room
moved into the gaps) never apply. The margins need not be equal. A gap with a free
edge, or margins with no gap, is not all or nothing.
"""
function all_or_no_clearance(grid)::Bool
    values = (grid.t, grid.t_left, grid.t_right, grid.t_top, grid.t_bottom)
    return all(==(0), values) || all(>(0), values)
end

# --- Which items can be placed ---

"""
    item_placeable(width, height, grid) -> Bool

Whether an item of whole-number size `width` by `height` can be placed on the
working sheet of `grid` (from `clearance_grid`) at all. It must fit inside it.

It must also not be placed alone with a thin sliver of room beside it. On an
axis whose two edges are both free, with a gap above 0, a part must sit flush
with an edge or at least the gap from it. An item whose length along that axis
is more than the working length less the gap, but less than the whole length,
leaves room that is neither, and nothing can be moved to take the room up
because no other block fits beside it. Shorter items can share the axis with
others, which lets the room be spread over the gaps when the pattern is placed
(see generate_pattern_dp_revised_three_staged).
"""
function item_placeable(width::Int, height::Int, grid)::Bool
    (width <= grid.W && height <= grid.H) || return false

    free_across = grid.t_left   == 0 && grid.t_right == 0 && grid.t > 0
    free_up     = grid.t_bottom == 0 && grid.t_top   == 0 && grid.t > 0
    (free_across && grid.W - grid.t < width  < grid.W) && return false
    (free_up     && grid.H - grid.t < height < grid.H) && return false

    return true
end
