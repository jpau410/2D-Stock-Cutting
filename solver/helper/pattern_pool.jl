# A pool of patterns that never holds two with the same item counts on the same
# sheet. Pattern generators add to it as they go, so duplicates are caught as
# each pattern is generated, and ask it for the pattern already there when a new
# result turns out to be a repeat. It also knows the sheets, so each pattern it
# prints as it is added comes with its sheet waste.
#
# Requires: Item, Sheet, Pattern, Instance (helper/structs.jl),
#           pattern_figures (helper/reporting.jl)

mutable struct PatternPool
    patterns :: Vector{Pattern}
    position :: Dict{Tuple{Int, Vector{Int}}, Int}   # (sheet_id, item_counts) -> index in patterns
    sheets   :: Dict{Int, Sheet}                     # sheet_id -> sheet, to report each pattern's sheet waste
end

"""
    PatternPool(instance)

An empty pool for patterns cut from the sheets of `instance`.
"""
PatternPool(instance::Instance) =
    PatternPool(Pattern[], Dict{Tuple{Int, Vector{Int}}, Int}(), Dict(s.sheet_id => s for s in instance.sheets))

"""
    add_pattern!(pool, pattern, original_items, label="") -> (Pattern, Bool)

Adds `pattern` to `pool` unless its sheet already has a pattern with the same
item counts. Returns the pattern the pool holds for it, and whether it was
added: a repeat returns the earlier pattern and `false`.

An added pattern is numbered 1, 2, ... in the order added, and its `.value` is
set to the total of its items' values in `original_items`. The DP may have run
on weighted values, and this is what the other generators report. If `label` is
given, an added pattern is printed under it, with its value and sheet waste.
"""
function add_pattern!(
    pool           :: PatternPool,
    pattern        :: Pattern,
    original_items :: Vector{Item},
    label          :: String = "",
)::Tuple{Pattern, Bool}
    key      = (pattern.sheet_id, pattern.item_counts)
    existing = get(pool.position, key, nothing)
    existing === nothing || return pool.patterns[existing], false

    # Worked out from the item counts rather than read from pattern.value,
    # which is the weighted value when the DP ran on weighted values.
    value  = sum(item.value * pattern.item_counts[item.original_part_id] for item in original_items)
    stored = Pattern(length(pool.patterns) + 1, pattern.sheet_id, value, pattern.shelves,
                     pattern.item_counts, nothing, pattern.aligned_far)
    push!(pool.patterns, stored)
    pool.position[key] = length(pool.patterns)

    isempty(label) || println("$label: pattern $(stored.pattern_id) on sheet $(stored.sheet_id), ",
                              pattern_figures(stored, pool.sheets[stored.sheet_id], original_items))
    return stored, true
end

# --- Which step found a pattern ---

"""
    pattern_phase(pattern_id, first_bigm_pattern_id, first_search_pattern_id;
                  search_name="dichotomic") -> String

`"optimal"`, `"big M"`, or `search_name`, from a pattern's id and the two ids
returned with `track_origins = true` by `dichotomic_pattern_generation`. Only
valid for ids from that same call, or ids renumbered without changing their
order.
"""
function pattern_phase(
    pattern_id              :: Int,
    first_bigm_pattern_id   :: Int,
    first_search_pattern_id :: Int;
    search_name             :: String = "dichotomic",
)::String
    pattern_id < first_bigm_pattern_id   && return "optimal"
    pattern_id < first_search_pattern_id && return "big M"
    return search_name
end
