# layout.jl: turns a pattern (shelves, stacks and item counts) into the exact
# position of every item on its sheet, and checks the result against the
# clearance rules.
#
# The pattern generators return structure only, and a stack keeps no order. This
# file places the items the same way every time, by the conventions below, so
# the page draws exactly what the clearance rules allow.
#
# Conventions, with x along the sheet width and y along the sheet height, both
# measured from the bottom-left corner:
#   - Shelves are stacked from the bottom, tallest first. Stacks sit left to
#     right within a shelf, widest first. Items sit bottom to top within a
#     stack, widest first.
#   - Neighbouring items are exactly the gap apart.
#   - An edge with a margin above 0 keeps every item at least that far away. A
#     row pressed to a free far edge instead of a near edge that has a margin
#     leaves the spare room on the margin side.
#   - Where both edges of an axis are free, the gap is above 0, and the spare room
#     is a sliver (above 0 and below the gap), the last block moves to the far
#     edge, so no item sits a sliver away from an edge.
#   - An item narrower or shorter than the block that holds it sits against the
#     block's near side, or its far side if the block touches a free far edge
#     with only a sliver of room beside the item.
# All arithmetic is on the whole-number grid of the solver (see grid_scale in
# helper/grid_scale.jl), so no rounding error can hide a broken rule.
#
# Requires: Item, Sheet, Instance, Pattern (helper/structs.jl),
#           grid_scale (helper/grid_scale.jl)

# --- Types ---

# The clearance rules on the whole-number grid
struct GridRules
    gap    :: Int
    left   :: Int
    right  :: Int
    top    :: Int
    bottom :: Int
end

# An item with its bottom-left corner and size, on the whole-number grid
struct Placed
    part_id :: Int
    x       :: Int
    y       :: Int
    w       :: Int
    h       :: Int
end

# --- Placing blocks along one axis ---

"""
    place_axis(lengths, gap, near, far, total; rules = true) -> Vector{Int}

The start of each block along one axis of length `total`, for blocks of the given
`lengths` in a row with `gap` between them. `near` and `far` are the margins at
the two ends, where 0 is a free edge.

The blocks are pressed to the near end, starting at `near`. Two cases move them:
  - a margin at the near end only: the whole row is pushed against the free far
    end, so the leftover room joins the margin side;
  - both ends free, a gap above 0, two or more blocks and a leftover room that
    is a sliver (above 0 and below the gap): the last block is pushed against
    the far end, which widens the gap before it.
With `rules = false` the blocks are only pressed to `near`.
"""
function place_axis(lengths::Vector{Int}, gap::Int, near::Int, far::Int, total::Int; rules::Bool = true)::Vector{Int}
    n = length(lengths)
    n == 0 && return Int[]
    used     = sum(lengths) + (n - 1) * gap
    starts   = Vector{Int}(undef, n)
    position = (rules && near > 0 && far == 0) ? total - used : near
    for i in 1:n
        starts[i] = position
        position += lengths[i] + gap
    end
    room = total - near - far - used
    if rules && near == 0 && far == 0 && gap > 0 && n >= 2 && 0 < room < gap
        starts[n] += room
    end
    return starts
end

# --- Placing a pattern ---

# The shelves of a pattern as lists of stacks of part ids: a slot is one stack,
# and holds each part id as many times as its count
function pattern_shelves(pattern::Pattern)::Vector{Vector{Vector{Int}}}
    return [
        [vcat([fill(part_id, count) for (part_id, count) in enumerate(slot.counts) if count > 0]...)
         for slot in shelf.items]
        for shelf in pattern.shelves
    ]
end

"""
    place_shelves(shelf_defs, size_of, rules, width, sheet_height) -> NamedTuple

Places a pattern made of shelves, given as lists of stacks of part ids, by the
conventions at the top of this file. `size_of` maps a part id to its (width,
height). The order of the shelves, stacks and items in `shelf_defs` does not
matter. Returns `(height, items, gaps)`: the canvas height, the placed items, and
the clearance strips as (x, y, width, height).
"""
function place_shelves(shelf_defs::Vector{Vector{Vector{Int}}}, size_of::Dict{Int, Tuple{Int, Int}},
                       rules::GridRules, width::Int, sheet_height::Int)
    t = rules.gap
    stack_w(stack) = maximum(size_of[id][1] for id in stack)
    stack_h(stack) = sum(size_of[id][2] for id in stack) + (length(stack) - 1) * t
    shelf_h(shelf) = maximum(stack_h(stack) for stack in shelf)

    # The canonical order of the items, stacks and shelves
    shelves = Vector{Vector{Vector{Int}}}()
    for shelf in shelf_defs
        stacks = [sort(stack; by = id -> (-size_of[id][1], -size_of[id][2], id)) for stack in shelf if !isempty(stack)]
        isempty(stacks) && continue
        sort!(stacks; by = stack -> (-stack_w(stack), -stack_h(stack), Tuple(stack)))
        push!(shelves, stacks)
    end
    shelf_w(shelf) = sum(stack_w(stack) for stack in shelf) + (length(shelf) - 1) * t
    sort!(shelves; by = shelf -> (-shelf_h(shelf), -shelf_w(shelf), [Tuple(stack) for stack in shelf]))

    n_shelves = length(shelves)
    n_shelves == 0 && return (height = sheet_height, items = Placed[], gaps = NTuple{4, Int}[])

    heights       = [shelf_h(shelf) for shelf in shelves]
    canvas_height = sheet_height
    shelf_ys      = place_axis(heights, t, rules.bottom, rules.top, canvas_height)

    vertical_free = rules.bottom == 0 && rules.top == 0 && t > 0
    all_items     = Placed[]
    gaps          = NTuple{4, Int}[]

    for (s, shelf) in enumerate(shelves)
        shelf_y, shelf_height = shelf_ys[s], heights[s]
        stack_xs    = place_axis([stack_w(stack) for stack in shelf], t, rules.left, rules.right, width)
        touches_top = rules.top == 0 && shelf_y + shelf_height == canvas_height

        for (j, stack) in enumerate(shelf)
            sw, sh = stack_w(stack), stack_h(stack)
            item_heights = [size_of[id][2] for id in stack]

            # A lone shelf with both vertical edges free can only take up its
            # leftover room in the gaps of its own stacks. Otherwise a stack is
            # pressed to the bottom of its shelf, or to the top if the shelf
            # touches a free top edge with a sliver of room above the stack.
            item_ys = if n_shelves == 1 && vertical_free && length(stack) >= 2
                place_axis(item_heights, t, 0, 0, canvas_height)
            else
                stack_y = (touches_top && 0 < shelf_height - sh < t) ? shelf_y + shelf_height - sh : shelf_y
                place_axis(item_heights, t, stack_y, 0, 0; rules = false)
            end

            # Items are pressed to the left of their stack, or to the right if the
            # stack touches a free right edge with a sliver of room beside the item
            touches_right = rules.right == 0 && stack_xs[j] + sw == width
            for (k, id) in enumerate(stack)
                w, h = size_of[id]
                x = (touches_right && 0 < sw - w < t) ? stack_xs[j] + sw - w : stack_xs[j]
                push!(all_items, Placed(id, x, item_ys[k], w, h))
            end

            if t > 0
                for k in 1:(length(stack) - 1)
                    item_ys[k + 1] - (item_ys[k] + item_heights[k]) >= t &&
                        push!(gaps, (stack_xs[j], item_ys[k] + item_heights[k], sw, t))
                end
                j < length(shelf) && stack_xs[j + 1] - (stack_xs[j] + sw) >= t &&
                    push!(gaps, (stack_xs[j] + sw, shelf_y, t, shelf_height))
            end
        end
        t > 0 && s < n_shelves && shelf_ys[s + 1] - (shelf_y + shelf_height) >= t &&
            push!(gaps, (0, shelf_y + shelf_height, width, t))
    end

    return (height = canvas_height, items = all_items, gaps = gaps)
end

# --- Checking a layout ---

"""
    check_layout(items, width, height, rules) -> Vector{String}

The ways a layout breaks the clearance rules: an item outside the canvas, closer
to an edge than that edge allows (a margin is a minimum distance, a free edge
takes an item flush or at least the gap away, never a sliver), or closer to a
neighbour than the gap. Empty if the layout is legal.
"""
function check_layout(items::Vector{Placed}, width::Int, height::Int, rules::GridRules)::Vector{String}
    problems = String[]
    t = rules.gap
    edge_ok(distance::Int, margin::Int) = margin > 0 ? distance >= margin : (distance == 0 || distance >= t)

    for item in items
        id = item.part_id
        (item.x < 0 || item.y < 0 || item.x + item.w > width || item.y + item.h > height) &&
            push!(problems, "part $id is outside the sheet")
        edge_ok(item.x, rules.left) || push!(problems, "part $id: left distance $(item.x) breaks the rule")
        edge_ok(width - item.x - item.w, rules.right) ||
            push!(problems, "part $id: right distance $(width - item.x - item.w) breaks the rule")
        edge_ok(item.y, rules.bottom) || push!(problems, "part $id: bottom distance $(item.y) breaks the rule")
        edge_ok(height - item.y - item.h, rules.top) ||
            push!(problems, "part $id: top distance $(height - item.y - item.h) breaks the rule")
    end

    for a in 1:length(items), b in (a + 1):length(items)
        p, q = items[a], items[b]
        x_gap = max(q.x - (p.x + p.w), p.x - (q.x + q.w))
        y_gap = max(q.y - (p.y + p.h), p.y - (q.y + q.h))
        (x_gap >= t || y_gap >= t) || push!(problems, "parts $(p.part_id) and $(q.part_id) are closer than the gap")
    end
    return problems
end

# --- One pattern ---

"""
    layout_pattern(pattern, instance, sheet; clearance, clearance_left, clearance_right,
                   clearance_top, clearance_bottom) -> NamedTuple

The placed items of `pattern` on `sheet`, in the units of the item sizes. The
clearance keywords are those the pattern was generated with.

Returns `(width, height, items, gaps, problems, utilisation)`:
  - `items`: a `NamedTuple` `(part_id, original_part_id, rotated, x, y, w, h)` for
    each placed item, where `part_id` is the form actually placed
  - `gaps`: the clearance strips between neighbours, as `(x, y, w, h)`
  - `problems`: the rules the layout breaks, and a note if the items placed are
    not the items the pattern records. Empty if the layout is legal.
  - `utilisation`: the share of the canvas the items cover
"""
function layout_pattern(
    pattern          :: Pattern,
    instance         :: Instance,
    sheet            :: Sheet;
    clearance        :: Real = 0.0,
    clearance_left   :: Real = 0.0,
    clearance_right  :: Real = 0.0,
    clearance_top    :: Real = 0.0,
    clearance_bottom :: Real = 0.0,
)
    scale = grid_scale(instance, clearance, clearance_left, clearance_right, clearance_top, clearance_bottom)
    grid(x::Real) = round(Int, x * scale)
    rules = GridRules(grid(clearance), grid(clearance_left), grid(clearance_right),
                      grid(clearance_top), grid(clearance_bottom))

    items_by_part = Dict(item.part_id => item for item in instance.items)
    size_of = Dict(item.part_id => (grid(item.width), grid(item.height)) for item in instance.items)
    width   = grid(sheet.width)

    placed = place_shelves(pattern_shelves(pattern), size_of, rules, width, grid(sheet.height))
    height = placed.height

    problems = check_layout(placed.items, width, height, rules)
    counts = zeros(Int, length(pattern.item_counts))
    for item in placed.items
        counts[items_by_part[item.part_id].original_part_id] += 1
    end
    counts == pattern.item_counts ||
        push!(problems, "the items placed are not the items the pattern records")

    area        = sum((item.w * item.h for item in placed.items); init = 0)
    utilisation = width * height == 0 ? 0.0 : area / (width * height)
    unit(v::Int) = v / scale
    return (
        width  = unit(width),
        height = unit(height),
        items  = [(part_id = p.part_id, original_part_id = items_by_part[p.part_id].original_part_id,
                   rotated = items_by_part[p.part_id].rotated,
                   x = unit(p.x), y = unit(p.y), w = unit(p.w), h = unit(p.h)) for p in placed.items],
        gaps        = [(x = unit(g[1]), y = unit(g[2]), w = unit(g[3]), h = unit(g[4])) for g in placed.gaps],
        problems    = problems,
        utilisation = utilisation,
    )
end
