# Builds a Pattern from its shelves, with item_counts (indexed by
# original_part_id) added up from the shelves' own counts. Pattern generators
# should use this rather than the Pattern constructor, so item_counts is
# always computed the same way.
#
# Requires: Item, Shelf, Pattern (helper/structs.jl)

"""
    build_pattern(pattern_id, sheet_id, value, shelves, items; aligned_far=false) -> Pattern

A `Pattern` from its `shelves`, with `item_counts` added up from the shelves'
own counts. `items` are all the items of the instance, rotated forms included:
a shelf counts a rotated form under its own part id, and the pattern counts it
under the item it was rotated from. `value` is the value of the items placed,
and `aligned_far` says whether the shelves sit against the top edge (see
`Pattern`).
"""
function build_pattern(
    pattern_id  :: Int,
    sheet_id    :: Int,
    value       :: Float64,
    shelves     :: Vector{Shelf},
    items       :: Vector{Item};
    aligned_far :: Bool = false,
)
    n_original       = count(i -> !i.rotated, items)
    item_counts      = zeros(Int, n_original)
    part_to_original = Dict(item.part_id => item.original_part_id for item in items)

    for shelf in shelves
        for (pid, cnt) in enumerate(shelf.item_counts)
            cnt == 0 && continue
            item_counts[part_to_original[pid]] += cnt
        end
    end

    return Pattern(pattern_id, sheet_id, value, shelves, item_counts, nothing, aligned_far)
end
