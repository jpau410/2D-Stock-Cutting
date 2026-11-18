# Core data types shared by the whole solver, and the time limit the pattern
# generators share.

# --- Item ---
struct Item
    part_id          :: Int
    original_part_id :: Int    # same as part_id if not rotated
    name             :: String
    demand           :: Int
    value            :: Float64   # price of one copy; buying one in costs this much
    width            :: Float64
    height           :: Float64
    rotated          :: Bool
end

# --- Convenience constructor for non-rotated items ---
Item(part_id, name, demand, value, width, height) =
    Item(part_id, part_id, name, demand, value, width, height, false)

# --- Expand items with rotated variants ---

"""
    expand_with_rotations(items; rotation_allowed=nothing) -> Vector{Item}

`items` with a rotated form added after each item that can be turned: the same
name with `_r` on the end, the same demand and value, width and height swapped,
`rotated = true`, and the `original_part_id` of the item it came from. Part ids
continue from the highest in `items`. A square item has no rotated form.

`rotation_allowed` maps an original part id to whether that item may be
turned. By default every item may be, and with it given an item that is not
listed may not.
"""
function expand_with_rotations(
    items::Vector{Item};
    rotation_allowed::Union{Dict{Int, Bool}, Nothing} = nothing
)
    expanded = Item[]
    next_id  = maximum(i.part_id for i in items) + 1

    for item in items
        push!(expanded, item)

        # Check if rotation is allowed for this item
        can_rotate = if rotation_allowed === nothing
            true  # default: rotate everything
        else
            get(rotation_allowed, item.original_part_id, false)
        end

        if can_rotate && item.width != item.height
            push!(expanded, Item(
                next_id,
                item.original_part_id,
                item.name * "_r",
                item.demand,
                item.value,
                item.height,  # swapped
                item.width,   # swapped
                true
            ))
            next_id += 1
        end
    end

    return expanded
end

# --- Sheet ---
struct Sheet
    sheet_id :: Int
    capacity :: Int
    width    :: Float64
    height   :: Float64
end

# --- Slot (one column on a shelf) ---
struct Slot
    counts :: Vector{Int}   # counts[part_id] = number of items stacked in this column
end

# --- Convenience constructors ---

"""
    Slot(n_items) -> Slot

An empty slot: a zero count for each of `n_items` part ids.
"""
Slot(n_items::Int) = Slot(zeros(Int, n_items))

"""
    Slot(n_items, part_id, count) -> Slot

A slot holding `count` copies of the item with part id `part_id`, and a zero
count for every other one of the `n_items` part ids.
"""
function Slot(n_items::Int, part_id::Int, count::Int)
    counts = zeros(Int, n_items)
    counts[part_id] = count
    return Slot(counts)
end

# --- Shelf ---
struct Shelf
    items       :: Vector{Slot}
    item_counts :: Vector{Int}   # item_counts[part_id] = total items on this shelf

    # true if the shelf's stacks sit flush against the right edge of the
    # working sheet instead of the left. This happens only when the left
    # edge's clearance is above 0 and the right edge's is 0. Code that works out
    # where the stacks sit reads it.
    aligned_far :: Bool
end

Shelf(items::Vector{Slot}, item_counts::Vector{Int}) = Shelf(items, item_counts, false)

# --- Placed item (an x, y position, for non-guillotine patterns) ---
#
# One item placed at (x, y), for layouts that aren't made of shelves and
# stacks, such as non-guillotine layouts. `part_id` is
# the part actually placed, so a rotated form keeps its own part_id here,
# unlike Pattern.item_counts, which is indexed by original_part_id.
struct PlacedItem
    part_id :: Int
    x       :: Float64
    y       :: Float64
end

# --- Pattern ---
struct Pattern
    pattern_id  :: Int
    sheet_id    :: Int
    value       :: Float64   # value of the items in the pattern; leftover sheet area is not priced
    shelves     :: Vector{Shelf}
    item_counts :: Vector{Int}   # item_counts[original_part_id] = total items in this pattern

    # Item positions for layouts that aren't made of shelves, such as the
    # non-guillotine IP. `nothing` for shelf-based patterns, whose layout is
    # in `shelves`.
    placements  :: Union{Nothing, Vector{PlacedItem}}

    # true if the shelves sit flush against the top edge of the working sheet
    # instead of the bottom. This happens only when the bottom edge's
    # clearance is above 0 and the top edge's is 0. Always false for a
    # placement-based pattern.
    aligned_far :: Bool
end

# Shorter constructors: `aligned_far` defaults to false, and `placements` to
# nothing when it is also left out.
Pattern(pattern_id, sheet_id, value, shelves, item_counts) =
    Pattern(pattern_id, sheet_id, value, shelves, item_counts, nothing, false)
Pattern(pattern_id, sheet_id, value, shelves, item_counts, placements) =
    Pattern(pattern_id, sheet_id, value, shelves, item_counts, placements, false)

# --- Instance ---
struct Instance
    items  :: Vector{Item}
    sheets :: Vector{Sheet}
end

# --- Solution ---
struct SelectedPattern
    pattern_id :: Int
    quantity   :: Int
end

struct Solution
    total_profit   :: Float64
    selected       :: Vector{SelectedPattern}
    items_produced :: Vector{Int}   # items_produced[original_part_id] = total items cut across all selected patterns
end

# --- Time limit ---
#
# A pattern generator that is given a `time_limit` checks the clock as it works
# and, when the time is up, stops with a TimeLimitExceeded error, so that the
# caller can record the run as cut short instead of waiting for it.

"""
    TimeLimitExceeded(limit)

The error a method throws when its `time_limit` of `limit` seconds runs out.
"""
struct TimeLimitExceeded <: Exception
    limit :: Float64
end

Base.showerror(io::IO, e::TimeLimitExceeded) = print(io, "the time limit of ", e.limit, " seconds ran out")

"""
    Deadline(time_limit)

When a run given `time_limit` seconds, counted from now, runs out. `Inf` is no
limit. A method makes one when it starts, and calls `check_deadline` as it works.
"""
struct Deadline
    limit :: Float64   # the seconds the run was given
    at    :: Float64   # the clock time, as time() gives it, when it runs out: Inf with no limit
end

function Deadline(time_limit::Real)
    time_limit >= 0 || throw(ArgumentError("the time limit must be 0 or more, got $time_limit"))
    return Deadline(Float64(time_limit), isfinite(time_limit) ? time() + time_limit : Inf)
end

"""
    check_deadline(deadline)

Throws `TimeLimitExceeded` if `deadline` has passed. With no limit it does
nothing and costs no more than a comparison.
"""
@inline function check_deadline(deadline::Deadline)
    deadline.at < Inf && time() >= deadline.at && throw(TimeLimitExceeded(deadline.limit))
    return nothing
end
