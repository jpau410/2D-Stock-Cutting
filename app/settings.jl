# settings.jl: the settings of a run, with their defaults, and the checks on
# what the page sends. The page asks the server for `default_settings()`, so the
# defaults are defined once, in solver/src/constants.jl.
#
# Requires: DEFAULT_CLEARANCE, DEFAULT_ANNUAL_HOLDING_RATE,
#           COLUMN_GENERATION_MAX_ITERATIONS,
#           APP_DEFAULT_IP_TIME_LIMIT, APP_DEFAULT_PERIODS_PER_YEAR,
#           APP_DEFAULT_ROLL_SHELF_HEIGHT (solver/src/constants.jl)

"""
    default_settings() -> Dict{String, Any}

The settings the page starts from, as the JSON the page sends back with a run.
Rates are fractions (0.15 is 15% a year). A time limit of `nothing` is no limit.
"""
function default_settings()::Dict{String, Any}
    return Dict{String, Any}(
        "modes" => Dict("stock" => true, "min_month" => false, "infinite" => false),
        "clearance" => Dict("gap" => DEFAULT_CLEARANCE, "left" => DEFAULT_CLEARANCE, "right" => DEFAULT_CLEARANCE,
                            "top" => DEFAULT_CLEARANCE, "bottom" => DEFAULT_CLEARANCE),
        "pool_preseed" => false,
        "item_holding_rate" => DEFAULT_ANNUAL_HOLDING_RATE,
        "periods_per_year" => APP_DEFAULT_PERIODS_PER_YEAR,
        "limits" => Dict("max_iterations" => COLUMN_GENERATION_MAX_ITERATIONS,
                         "col_gen_time_limit" => nothing,
                         "ip_time_limit" => APP_DEFAULT_IP_TIME_LIMIT),
        "roll" => Dict("gap" => DEFAULT_CLEARANCE, "left" => DEFAULT_CLEARANCE, "right" => DEFAULT_CLEARANCE,
                       "top" => DEFAULT_CLEARANCE, "bottom" => DEFAULT_CLEARANCE,
                       "shelf_height" => APP_DEFAULT_ROLL_SHELF_HEIGHT, "widths" => Dict{String, Any}()),
        "groups" => nothing,
    )
end

# The setting `key` of `section`, or `default` when it is missing or null
function setting(section::AbstractDict, key::String, default)
    value = get(section, key, nothing)
    return value === nothing ? default : value
end

function setting_number(section::AbstractDict, key::String, default; minimum::Real = -Inf, maximum::Real = Inf, name::String = key)
    value = setting(section, key, default)
    value === nothing && return nothing
    number = value isa Real ? Float64(value) : tryparse(Float64, string(value))
    (number === nothing || !isfinite(number)) && error("$name must be a number, got \"$value\"")
    number >= minimum || error("$name must be at least $minimum, got $number")
    number <= maximum || error("$name must be at most $maximum, got $number")
    return number
end

"""
    roll_clearance_ok(clearance) -> Bool

Whether the clearance of a roll, `(gap, left, right, top, bottom)`, is all or
nothing: all five values are 0, or all five are above 0 (they need not be equal).
This is the rule of the infinite sheet model, because no edge of a roll is free.
"""
roll_clearance_ok(clearance::NamedTuple)::Bool = all(==(0), values(clearance)) || all(>(0), values(clearance))

"""
    read_settings(raw) -> NamedTuple

The settings of a run from the JSON the page sent, checked, with a default for
anything missing. Errors with a message for the first setting out of range.
Returns
`(stock, min_month, infinite, clearance, pool_preseed, item_holding_rate,
periods_per_year, max_iterations, col_gen_time_limit, ip_time_limit, roll_clearance,
roll_shelf_height, roll_widths, groups)`,
where `clearance` is `(gap, left, right, top, bottom)` for the sheet stock,
`roll_clearance` is the same for the roll (which is separate, and which must be all
or nothing: see `roll_clearance_ok`), a time limit is `Inf` for no limit,
`roll_widths` maps a group label to its roll width, and `groups` is the labels to
run, or `nothing` for all.
"""
function read_settings(raw::AbstractDict)
    defaults = default_settings()
    section(key) = (value = get(raw, key, nothing); value isa AbstractDict ? value : Dict{String, Any}())
    fallback(key) = defaults[key]

    modes = section("modes")
    stock     = Bool(setting(modes, "stock", true))
    min_month = Bool(setting(modes, "min_month", false))
    infinite  = Bool(setting(modes, "infinite", false))
    (stock || infinite) || error("choose at least one thing to run")
    min_month && !stock && error("months of cover is computed from the sheet stock plan, so that plan must be chosen too")

    clearance_section = section("clearance")
    clearance_default = fallback("clearance")
    edge(key) = setting_number(clearance_section, key, clearance_default[key]; minimum = 0, name = "clearance $key")
    clearance = (gap = edge("gap"), left = edge("left"), right = edge("right"), top = edge("top"), bottom = edge("bottom"))

    limits = section("limits")
    limit_defaults = fallback("limits")
    col_gen_limit = setting_number(limits, "col_gen_time_limit", nothing; minimum = 1, name = "column generation time limit")
    ip_limit      = setting_number(limits, "ip_time_limit", limit_defaults["ip_time_limit"]; minimum = 1, name = "integer programme time limit")

    roll_section = section("roll")
    roll_default = fallback("roll")
    widths = Dict{String, Float64}()
    for (label, value) in pairs(setting(roll_section, "widths", Dict{String, Any}()))
        (value === nothing || isempty(string(value))) && continue
        widths[String(label)] = setting_number(Dict("w" => value), "w", nothing; minimum = 0, name = "roll width of $label")
    end

    roll_edge(key) = setting_number(roll_section, key, roll_default[key]; minimum = 0, name = "roll $key")
    roll_clearance = (gap = roll_edge("gap"), left = roll_edge("left"), right = roll_edge("right"),
                      top = roll_edge("top"), bottom = roll_edge("bottom"))
    infinite && !roll_clearance_ok(roll_clearance) &&
        error("the roll needs the gap and all four margins to be 0, or all five to be above 0")

    chosen = get(raw, "groups", nothing)
    return (
        stock = stock, min_month = min_month, infinite = infinite,
        clearance = clearance,
        pool_preseed = Bool(setting(raw, "pool_preseed", false)),
        item_holding_rate = setting_number(raw, "item_holding_rate", fallback("item_holding_rate"); minimum = 0,
                                           name = "item holding rate"),
        periods_per_year = setting_number(raw, "periods_per_year", fallback("periods_per_year"); minimum = 1,
                                          name = "periods per year"),
        max_iterations = Int(setting_number(limits, "max_iterations", limit_defaults["max_iterations"]; minimum = 1,
                                            name = "column generation iteration limit")),
        col_gen_time_limit = col_gen_limit === nothing ? Inf : col_gen_limit,
        ip_time_limit = ip_limit,
        roll_clearance = roll_clearance,
        roll_shelf_height = setting_number(roll_section, "shelf_height", roll_default["shelf_height"]; minimum = 0,
                                           name = "roll shelf height"),
        roll_widths = widths,
        groups = chosen isa AbstractVector ? String[string(g) for g in chosen] : nothing,
    )
end
