# Weighting helpers for the pattern generators that re-weight item values to
# steer the DP: the lexmax (big-M) anchors and the dichotomic bisection between
# them. Shared so there is only one definition of each.
#
# Requires: Item, Pattern, Instance (helper/structs.jl),
#           DEFAULT_LEXMAX_EPSILON, MIN_DICHOTOMIC_WEIGHT,
#           DICHOTOMIC_TIE_TOLERANCE (src/constants.jl)

# --- Checking epsilon ---

# Errors unless epsilon is at least 0 and below 1. At 1 or more the focus item's
# weight, 1 - epsilon, is 0 or negative, and below 0 the other items' weights
# are negative.
function _check_epsilon(epsilon::Real)
    0 <= epsilon < 1 || error("epsilon must be at least 0 and below 1, got $epsilon")
    return nothing
end

# --- Lexmax (big-M) weights ---

"""
    softened_lexmax_weights(original_items; epsilon=DEFAULT_LEXMAX_EPSILON) -> Vector{Vector{Float64}}

One weight vector per focus item. The focus item gets `1 - epsilon`, and
every other item gets an equal share of `epsilon`, which is
`epsilon / (n - 1)` for `n` items. Errors unless `epsilon` is at least 0 and
below 1.
"""
function softened_lexmax_weights(
    original_items :: Vector{Item};
    epsilon        :: Float64 = DEFAULT_LEXMAX_EPSILON,
)::Vector{Vector{Float64}}
    _check_epsilon(epsilon)
    n = length(original_items)
    return [
        [
            item.original_part_id == focus.original_part_id ?
                1.0 - epsilon :
                (n > 1 ? epsilon / (n - 1) : 0.0)
            for item in original_items
        ]
        for focus in original_items
    ]
end

"""
    value_map_from_lambda(lambda, original_items, instance) -> Dict{Int, Float64}

Weighted value for every item in `instance`, keyed by part_id and including
rotated forms: `lambda[i] * item.value`, where i is the item's position in
`original_items` (matched by original_part_id). An item that isn't in
`original_items`, such as one that doesn't fit the current sheet, gets
weight 0.
"""
function value_map_from_lambda(
    lambda         :: Vector{Float64},
    original_items :: Vector{Item},
    instance       :: Instance
)
    lambda_map = Dict{Int, Float64}(
        original_items[i].original_part_id => lambda[i]
        for i in 1:length(original_items)
    )
    return Dict{Int, Float64}(
        item.part_id => get(lambda_map, item.original_part_id, 0.0) * item.value
        for item in instance.items
    )
end

"""
    weighted_instance(instance, lambda, original_items) -> Instance

`instance` with every item's value replaced by its weighted value (see
`value_map_from_lambda`), so the DP maximises the weighted value.
"""
function weighted_instance(
    instance       :: Instance,
    lambda         :: Vector{Float64},
    original_items :: Vector{Item},
)::Instance
    value_map = value_map_from_lambda(lambda, original_items, instance)
    weighted_items = [
        Item(item.part_id, item.original_part_id, item.name, item.demand,
             value_map[item.part_id], item.width, item.height, item.rotated)
        for item in instance.items
    ]
    return Instance(weighted_items, instance.sheets)
end

# --- Dichotomic weights ---

"""
    objective_vector(pattern, original_items) -> Vector{Float64}

One objective per item: the item's value times its count in `pattern`, in the
order of `original_items`.
"""
function objective_vector(pattern::Pattern, original_items::Vector{Item})::Vector{Float64}
    return Float64[
        item.value * pattern.item_counts[item.original_part_id] for item in original_items
    ]
end

"""
    dichotomic_lambda_pair(f1, f2, i, j, n; epsilon=DEFAULT_LEXMAX_EPSILON,
                           n_override=nothing) -> Union{Vector{Float64}, Nothing}

Weights that bisect between two patterns with objective vectors `f1` and `f2`
over objectives `i` and `j`. The pair gets weights w_i and w_j that sum to 1
and make the two patterns score the same,

    w_i * f1[i] + w_j * f1[j] = w_i * f2[i] + w_j * f2[j],

so the DP under them finds whatever lies between the two. The pair then
shares `1 - epsilon` in that ratio and the other items split `epsilon`. Every
weight is floored at MIN_DICHOTOMIC_WEIGHT and the vector is normalised to sum
to 1.

`n` is the full item count and sizes the result, so `i` and `j` index the same
item list as everywhere else. `n_override`, if given, replaces `n` only in the
epsilon split (`epsilon / (n_override - 2)`).

Errors unless `epsilon` is at least 0 and below 1. Returns `nothing` if the two
patterns tie on these objectives or no positive weights make them score the same.
"""
function dichotomic_lambda_pair(
    f1         :: Vector{Float64},
    f2         :: Vector{Float64},
    i          :: Int,
    j          :: Int,
    n          :: Int;
    epsilon    :: Float64 = DEFAULT_LEXMAX_EPSILON,
    n_override :: Union{Int, Nothing} = nothing,
)::Union{Vector{Float64}, Nothing}
    _check_epsilon(epsilon)
    denominator = (f1[i] - f2[i]) + (f2[j] - f1[j])
    abs(denominator) < DICHOTOMIC_TIE_TOLERANCE && return nothing

    weight_i = (f2[j] - f1[j]) / denominator
    weight_j = 1.0 - weight_i
    (weight_i <= 0.0 || weight_j <= 0.0) && return nothing

    others_in_split = (n_override === nothing ? n : n_override) - 2
    other_weight    = others_in_split > 0 ? epsilon / others_in_split : 0.0

    lambda    = fill(other_weight, n)
    lambda[i] = weight_i * (1.0 - epsilon)
    lambda[j] = weight_j * (1.0 - epsilon)

    lambda = max.(lambda, MIN_DICHOTOMIC_WEIGHT)
    return lambda ./ sum(lambda)
end
