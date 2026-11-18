# The lines the scripts print about what they found, written once so every
# pattern generator, diversification method and selection IP reports the same
# things in the same wording.
#
#   format_percent: a share written as a percentage, such as 12.3%.
#   pattern_figures: one pattern's item value and sheet waste.
#   report_pattern: prints the pattern a generator found, with those figures.
#   print_pattern_summary: how many patterns a method kept, and the spread of
#     their sheet waste.
#   print_plan_summary: the lines every selection IP prints after its items:
#     the sheets cut, the sheet waste, the value of the items produced and the
#     overproduced items left in storage.
#   print_waste_by_period: the sheet waste of each period of a multi-period plan.
#
# Sheet waste is the leftover area of a sheet once a pattern is cut from it, as
# a share of the sheet's area (see helper/wastage.jl). Items cut beyond demand
# are not waste: their area counts as used.
#
# Requires: Item, Sheet, Pattern, Instance (helper/structs.jl),
#           pattern_waste_fraction (helper/wastage.jl)

# --- Numbers ---

"""
    format_percent(fraction) -> String

`fraction` as a percentage to one decimal place, such as `"12.3%"`. A tiny
negative value left by floating-point rounding is written as 0.0%.
"""
format_percent(fraction::Real) = "$(round(100 * max(0.0, fraction), digits = 1))%"

# --- One pattern ---

"""
    pattern_figures(pattern, sheet, original_items) -> String

The figures reported for one pattern: the value of its items, and the share of
`sheet` left over after one cut of it, as in `"item value 114.0, sheet waste
12.3%"`.
"""
function pattern_figures(pattern::Pattern, sheet::Sheet, original_items::Vector{Item})
    waste = pattern_waste_fraction(pattern, sheet, original_items)
    return "item value $(round(pattern.value, digits = 2)), sheet waste $(format_percent(waste))"
end

"""
    report_pattern(label, pattern, instance)

Prints one line for the pattern a generator found: `label`, the sheet, and the
figures of `pattern_figures`. The generators call it when asked to with
`report = true`.
"""
function report_pattern(label::String, pattern::Pattern, instance::Instance)
    sheet          = instance.sheets[findfirst(s -> s.sheet_id == pattern.sheet_id, instance.sheets)]
    original_items = filter(i -> !i.rotated, instance.items)
    println("$label, sheet $(pattern.sheet_id): ", pattern_figures(pattern, sheet, original_items))
end

# --- Many patterns ---

"""
    print_pattern_summary(patterns, instance)

Prints how many patterns a method kept, and the lowest, mean and highest sheet
waste among them. The mean is over patterns, not weighted by sheet area.
"""
function print_pattern_summary(patterns::Vector{Pattern}, instance::Instance)
    println("\nTotal unique patterns: $(length(patterns))")
    isempty(patterns) && return

    sheet_by_id    = Dict(s.sheet_id => s for s in instance.sheets)
    original_items = filter(i -> !i.rotated, instance.items)
    waste = [pattern_waste_fraction(p, sheet_by_id[p.sheet_id], original_items) for p in patterns]
    println("Sheet waste of those patterns: lowest $(format_percent(minimum(waste))), ",
            "mean $(format_percent(sum(waste) / length(waste))), ",
            "highest $(format_percent(maximum(waste)))")
end

# --- A selected plan ---

"""
    print_plan_summary(; sheets_cut, sheets_available, waste_fraction, produced_value,
                       overproduced_units, overproduced_value)

Prints the lines every selection IP ends its list of items with: the sheets cut
of those available, the sheet waste (the leftover area of the sheets cut as a
share of their area, see `solution_waste`), the value of the items
produced, not counting overproduction, and the overproduced items themselves:
the units cut beyond what meets demand, which are left in storage at the end,
and their value.
"""
function print_plan_summary(;
    sheets_cut       :: Int,
    sheets_available :: Int,
    waste_fraction   :: Real,
    produced_value   :: Real,
    overproduced_units :: Real,
    overproduced_value :: Real,
)
    println("Sheets cut: $sheets_cut of $sheets_available")
    println("Sheet waste: ", sheets_cut > 0 ? "$(format_percent(waste_fraction)) of the area of the sheets cut" :
                                              "none, no sheets cut")
    println("Value of items produced (not counting overproduction): $(round(produced_value, digits = 2))")
    println("Overproduced, left in storage at the end: $(round(overproduced_units, digits = 2)) items worth ",
            round(overproduced_value, digits = 2))
end

"""
    print_waste_by_period(period_waste)

Prints the sheet waste of each period of a multi-period plan, from the
`solution_waste` result of each. A period in which no sheet is cut has no
waste to report and is written as `-`.
"""
function print_waste_by_period(period_waste::AbstractVector)
    text = [w.cut_sheet_area > 0 ? format_percent(w.waste_fraction) : "-" for w in period_waste]
    println("Sheet waste by period: ", join(text, ", "))
end
