using JuMP

# The pieces of the selection model that price the sheets and weight buying in
# (see multi_period_ip.jl for the model). They are kept in one place so the
# integer programme and column generation round solver values and price the
# sheets in the same way.
#
#   whole_value, check_item_holding_rate: rounding of solver values, and the range
#     check on the item holding rate.
#   pooled_sheet_patterns: the pattern pool grouped by sheet type.
#   check_sheet_costs: the check on the opportunity cost of each sheet type.
#   buy_in_weight: the weight that makes buying in the last resort.
#
# Requires: Item, Sheet, Pattern, Instance (helper/structs.jl)

# --- Rounding and rates ---

"""
    whole_value(v)

The solver value of a variable that is a nonnegative whole number at an
optimum, rounded and clamped at 0 to drop solver tolerance, such as
5.9999999 for 6 or -0.0000001 for 0. Passing it to `value(whole_value, expr)`
evaluates an expression at those rounded values.
"""
whole_value(v) = max(0.0, round(value(v)))

"""
    check_item_holding_rate(item_holding_rate)

Errors unless `item_holding_rate` is at least 0.
"""
function check_item_holding_rate(item_holding_rate :: Real)
    item_holding_rate >= 0 ||
        error("item_holding_rate must be at least 0, got $item_holding_rate")
    return nothing
end

# --- The patterns of each sheet type ---

"""
    pooled_sheet_patterns(instance, patterns) -> (patterns_on_sheet, pooled_sheets)

Groups the pattern indices by sheet type (`patterns_on_sheet`, by sheet id) and
lists the sheet types with at least one pattern in the pool (`pooled_sheets`).
Sheet types with no patterns are left out of the model, because they can't be
cut, so they are saved.
"""
function pooled_sheet_patterns(instance :: Instance, patterns :: Vector{Pattern})
    patterns_on_sheet = Dict(
        sheet.sheet_id => [p for p in 1:length(patterns) if patterns[p].sheet_id == sheet.sheet_id]
        for sheet in instance.sheets
    )
    pooled_sheets = [sheet for sheet in instance.sheets if !isempty(patterns_on_sheet[sheet.sheet_id])]
    return patterns_on_sheet, pooled_sheets
end

# --- What cutting a sheet gives up ---

"""
    check_sheet_costs(sheet_costs, pooled_sheets, patterns, patterns_on_sheet)

Errors unless `sheet_costs` gives every pooled sheet type a cost of at least 0 and
no pattern on a type is worth more than that cost.

`sheet_costs` maps a sheet id to the opportunity cost of cutting one sheet of the
type: the value of its best packing, the pattern worth the most at the true item
values, however much demand there is for the items on it. It is a constant of the
data, found once by the pattern generator before the model is built (column
generation does so when it builds its first pool). It must be at least the value
of every pattern the model may use, since `buy_in_weight` relies on no pattern
being worth more than its type's best packing.
"""
function check_sheet_costs(
    sheet_costs       :: AbstractDict,
    pooled_sheets     :: Vector{Sheet},
    patterns          :: Vector{Pattern},
    patterns_on_sheet :: AbstractDict,
)
    for sheet in pooled_sheets
        haskey(sheet_costs, sheet.sheet_id) ||
            error("sheet_costs has no cost for sheet $(sheet.sheet_id), which has patterns")
        cost = sheet_costs[sheet.sheet_id]
        cost >= 0 || error("the cost of sheet $(sheet.sheet_id) must be at least 0, got $cost")
        for p in patterns_on_sheet[sheet.sheet_id]
            patterns[p].value <= cost + 1e-6 * max(1.0, cost) ||
                error("pattern $(patterns[p].pattern_id) on sheet $(sheet.sheet_id) is worth $(patterns[p].value), " *
                      "more than the best packing of its sheet, $cost")
        end
    end
    return nothing
end

# --- Buying in as the last resort ---

"""
    buy_in_weight(pooled_sheets, sheet_costs, original_items, item_holding_rate,
                  n_periods, periods_per_year) -> Float64

The weight the objective puts on the value of the items bought in. It is large
enough that buying one unit less is worth more than any change in everything else
in the objective, so a plan that buys less always beats one that buys more, and
the other terms only choose among the plans that buy the least.

Everything else in the objective is at most

    other_max = S * (1 + item_holding_rate * years)

where S is the sum over the pooled sheet types of capacity times opportunity cost
(the sheet term with every sheet cut, and also the most value that can be cut,
since no pattern is worth more than its type's best), and `years` is the longest
that an item can be held: charged at the end of every period, from the first to the
last. A unit bought costs at least the lowest item value, so the weight is

    other_max / lowest item value + 1

which makes one unit less bought worth more than `other_max`. With no sheets
in the pool nothing can be cut and the weight is 1.
"""
function buy_in_weight(
    pooled_sheets     :: Vector{Sheet},
    sheet_costs       :: AbstractDict,
    original_items    :: Vector{Item},
    item_holding_rate :: Real,
    n_periods         :: Int,
    periods_per_year  :: Real,
)
    (isempty(pooled_sheets) || isempty(original_items)) && return 1.0
    stock_value  = sum(sheet.capacity * sheet_costs[sheet.sheet_id] for sheet in pooled_sheets)
    years        = n_periods / periods_per_year
    other_max    = stock_value * (1 + item_holding_rate * years)
    lowest_value = minimum(item.value for item in original_items)
    return floor(other_max / lowest_value) + 1.0
end
