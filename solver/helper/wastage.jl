# Waste of a selected plan, worked out after patterns have been selected.
# Pattern generation and selection don't price leftover sheet area: a
# pattern's `.value` is the value of its items only.
#
#   waste_rate_from_params: turns the thickness and material inputs into one
#     value per unit of sheet area.
#   pattern_waste_area: the leftover area of one cut of a pattern.
#   pattern_waste_fraction: that area as a share of the sheet's area.
#   solution_waste: the waste of a whole selected plan, as an area, a share
#     of the cut sheets' area and a value at the scrap rate.
#
# Waste is only the leftover area of the sheets that are cut. Items cut
# beyond demand are not waste, and are reported separately.
#
# Requires: Item, Sheet, Pattern, Instance, SelectedPattern, Solution
#           (helper/structs.jl),
#           DEFAULT_* wastage constants (src/constants.jl)

# --- Scrap value per unit of sheet area ---

"""
    waste_rate_from_params(; sheet_thickness, stainless_value_per_kg,
                           stainless_density_kg_per_m3,
                           material_value_per_volume=nothing) -> Float64

Value of leftover material per unit of sheet area:
`value_per_volume * sheet_thickness`. `value_per_volume` is
`material_value_per_volume` if given, otherwise
`stainless_value_per_kg * stainless_density_kg_per_m3 / 1e9`, which is the
value per cubic millimetre when dimensions are in mm. The other keywords
default to the DEFAULT_* values in src/constants.jl.
"""
function waste_rate_from_params(;
    sheet_thickness              :: Real = DEFAULT_SHEET_THICKNESS,
    stainless_value_per_kg       :: Real = DEFAULT_STAINLESS_VALUE_PER_KG,
    stainless_density_kg_per_m3  :: Real = DEFAULT_STAINLESS_DENSITY_KG_PER_M3,
    material_value_per_volume    :: Union{Real, Nothing} = nothing,
)::Float64
    value_per_volume = material_value_per_volume === nothing ?
        (stainless_value_per_kg * stainless_density_kg_per_m3) / 1e9 :  # per cubic metre to per cubic millimetre
        Float64(material_value_per_volume)
    value_per_volume < 0 && error("material_value_per_volume must be >= 0")
    sheet_thickness   < 0 && error("sheet_thickness must be >= 0")
    return value_per_volume * sheet_thickness
end

# --- Waste of one pattern ---

"""
    pattern_waste_area(pattern, sheet, original_items) -> Float64

Leftover area of one cut of `pattern` on `sheet`: the full sheet area minus
the area of the items placed. Mandatory edge margins count as waste.
Computed from `pattern.item_counts` and the sheet size alone, so it does not
depend on the values used to find the pattern.
"""
function pattern_waste_area(pattern::Pattern, sheet::Sheet, original_items::Vector{Item})::Float64
    placed_area = sum(
        (item.width * item.height * pattern.item_counts[item.original_part_id] for item in original_items);
        init = 0.0,
    )
    return sheet.width * sheet.height - placed_area
end

"""
    pattern_waste_fraction(pattern, sheet, original_items) -> Float64

The leftover area of one cut of `pattern` on `sheet` (see pattern_waste_area)
as a share of the sheet's area: 0.0 when items cover the whole sheet, 1.0 when
it holds none.
"""
function pattern_waste_fraction(pattern::Pattern, sheet::Sheet, original_items::Vector{Item})::Float64
    return pattern_waste_area(pattern, sheet, original_items) / (sheet.width * sheet.height)
end

# --- Waste of a selected plan ---

"""
    solution_waste(selected, patterns, instance; waste_rate) -> NamedTuple
    solution_waste(solution, patterns, instance; waste_rate) -> NamedTuple

Waste of a plan once its patterns have been selected. `selected` is a
vector of `SelectedPattern` (a `Solution` can be passed instead), each
pattern cut `quantity` times. For a plan over several periods, call it for
each period and add the areas. `waste_rate` is the value per unit of
leftover area and defaults to `waste_rate_from_params()`.

Returns a NamedTuple:
  - `cut_sheet_area`: total area of the sheets cut
  - `waste_area`: leftover area of those sheets
  - `waste_fraction`: `waste_area / cut_sheet_area`, or 0.0 if no sheet is cut
  - `waste_value`: `waste_area * waste_rate`
"""
function solution_waste(
    selected   :: Vector{SelectedPattern},
    patterns   :: Vector{Pattern},
    instance   :: Instance;
    waste_rate :: Real = waste_rate_from_params(),
)
    original_items = filter(i -> !i.rotated, instance.items)
    pattern_by_id  = Dict(p.pattern_id => p for p in patterns)
    sheet_by_id    = Dict(s.sheet_id => s for s in instance.sheets)

    cut_sheet_area = 0.0
    waste_area     = 0.0
    for chosen in selected
        pattern = pattern_by_id[chosen.pattern_id]
        sheet   = sheet_by_id[pattern.sheet_id]
        cut_sheet_area += chosen.quantity * sheet.width * sheet.height
        waste_area     += chosen.quantity * pattern_waste_area(pattern, sheet, original_items)
    end

    return (
        cut_sheet_area = cut_sheet_area,
        waste_area     = waste_area,
        waste_fraction = cut_sheet_area > 0 ? waste_area / cut_sheet_area : 0.0,
        waste_value    = waste_area * waste_rate,
    )
end

solution_waste(solution::Solution, patterns::Vector{Pattern}, instance::Instance; kwargs...) =
    solution_waste(solution.selected, patterns, instance; kwargs...)
