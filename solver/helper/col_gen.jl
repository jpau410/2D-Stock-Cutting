using JuMP

# Column generation, shared by the multi-period selection model
# (multi_period_col_gen.jl) and the infinite sheet model
# (infinite_sheet_col_gen.jl).
#
# The master problem is the LP relaxation of the respective IP over the patterns
# found so far. Its duals price the items, and a pricing generator (by default the
# revised DP) finds the best pattern for each sheet type at those prices. A pattern
# with a negative reduced cost would lower the LP's cost, so it joins the pool and the
# LP is solved again. When no pattern has a negative reduced cost, the LP is solved
# over all patterns.
#
# A pattern on sheet type s has the reduced cost
#
#     d = -(sum over items i of price_i * count_i + offset_s)
#
# price_i is the dual of item i's balance row: one price for each item and period
# in the multi-period model, whose balance rows are per period. offset_s is the
# part that depends only on the sheet type: the dual of its capacity row, less the
# opportunity cost of cutting a sheet of the type (the model's `sheet_costs`).
#
# Pricing at the duals finds the most negative d for a sheet type, so the LP value
# less capacity times that d, summed over sheet types, is a lower bound on the LP
# over all patterns. It is valid when the pricing generator is exact.
#
#   check_initial_patterns, start_pool: the patterns a run starts from.
#   default_pricing, priced_instance: finding a pattern at the duals.
#   sheet_dual_offset, pattern_reduced_cost: reduced costs.
#   run_column_generation: the loop.
#   count_fractional, col_gen_gap, col_gen_note, print_col_gen_outcome,
#   record_col_gen_stats!: reading and reporting the result.
#
# Requires: Item, Sheet, Pattern, Instance (helper/structs.jl),
#           PatternPool, add_pattern! (helper/pattern_pool.jl),
#           format_percent (helper/reporting.jl),
#           generate_pattern_dp_revised_three_staged
#           (src/Pattern_Generation/revised_three-staged_dp.jl),
#           COLUMN_GENERATION_MAX_ITERATIONS, COLUMN_GENERATION_GAP_TOLERANCE,
#           REDUCED_COST_TOLERANCE, INTEGRALITY_TOLERANCE (src/constants.jl)

# --- The patterns a run starts from ---

"""
    check_initial_patterns(instance, patterns)

Errors unless every pattern in `patterns` is on a sheet of `instance`, has one
item count for each unrotated item, and has no negative count.
"""
function check_initial_patterns(instance::Instance, patterns::Vector{Pattern})
    sheet_ids = Set(s.sheet_id for s in instance.sheets)
    n_items   = count(i -> !i.rotated, instance.items)
    for (k, pattern) in enumerate(patterns)
        pattern.sheet_id in sheet_ids ||
            error("initial pattern $k is on sheet $(pattern.sheet_id), which is not a sheet of the instance")
        length(pattern.item_counts) == n_items ||
            error("initial pattern $k has $(length(pattern.item_counts)) item counts, expected $n_items (one per unrotated item)")
        all(>=(0), pattern.item_counts) ||
            error("initial pattern $k has a negative item count")
    end
    return nothing
end

"""
    start_pool(instance, initial_patterns, pricing) -> (pool, n_given, n_optimal, sheet_costs)

The pool a run starts from: `initial_patterns`, with repeats dropped, then the
best pattern of every sheet at the true item values (`pricing(instance,
sheet_id)`), unless the pool already holds it. That pattern is always added, so
the pool holds the best packing of every sheet type that can be cut.

Returns the `PatternPool`, how many distinct patterns were given, how many optimal
patterns were added, and `sheet_costs`: the value of each sheet's best pattern at
the true item values, by sheet id (a sheet where nothing can be placed is left
out). That value is the opportunity cost of cutting a sheet of the type. It is
found once, here, and does not change as patterns are added, because no pattern
is worth more than the best one when the generator is exact.
"""
function start_pool(instance::Instance, initial_patterns::Vector{Pattern}, pricing::Function)
    original_items = filter(i -> !i.rotated, instance.items)
    pool = PatternPool(instance)
    for pattern in initial_patterns
        add_pattern!(pool, pattern, original_items)
    end
    n_given     = length(pool.patterns)
    sheet_costs = Dict{Int, Float64}()
    for sheet in instance.sheets
        pattern = pricing(instance, sheet.sheet_id)
        pattern === nothing && continue
        stored, _ = add_pattern!(pool, pattern, original_items)
        sheet_costs[sheet.sheet_id] = stored.value
    end
    return pool, n_given, length(pool.patterns) - n_given, sheet_costs
end

# --- Pricing ---

"""
    default_pricing(; clearance=0.0, clearance_left=0.0, clearance_right=0.0,
                    clearance_top=0.0, clearance_bottom=0.0) -> Function

The pricing generator a run uses unless it is given another: the revised
three-staged DP under these clearances. A pricing generator is a function
`(instance, sheet_id) -> Union{Pattern, Nothing}` that returns the pattern worth
the most on that sheet at the instance's item values, such as any of the
generators in src/Pattern_Generation/.
"""
function default_pricing(;
    clearance        :: Real = 0.0,
    clearance_left   :: Real = 0.0,
    clearance_right  :: Real = 0.0,
    clearance_top    :: Real = 0.0,
    clearance_bottom :: Real = 0.0,
)
    return (priced::Instance, sheet_id::Int) -> generate_pattern_dp_revised_three_staged(
        priced, sheet_id;
        clearance        = clearance,
        clearance_left   = clearance_left,
        clearance_right  = clearance_right,
        clearance_top    = clearance_top,
        clearance_bottom = clearance_bottom,
    )
end

"""
    priced_instance(instance, prices) -> Instance

`instance` with every item's value replaced by its price (`prices` is indexed by
original_part_id; a rotated form has its original's price), so a generator that
maximises value finds the best pattern at those prices. A price below 0 is taken
as 0: an item that costs to place is left out.
"""
function priced_instance(instance::Instance, prices::AbstractVector{<:Real})
    items = [
        Item(i.part_id, i.original_part_id, i.name, i.demand, max(Float64(prices[i.original_part_id]), 0.0),
             i.width, i.height, i.rotated)
        for i in instance.items
    ]
    return Instance(items, instance.sheets)
end

# --- Reduced costs ---

"""
    sheet_dual_offset(sheet_id, capacity_rows, sheet_costs) -> Float64

The part of a pattern's reduced cost that depends only on its sheet type: the
dual of the type's capacity row (0 or below in a minimisation), less the
opportunity cost of cutting one sheet of the type (the model's `sheet_costs`),
which is what a pattern on it costs in the objective.
"""
function sheet_dual_offset(sheet_id::Int, capacity_rows::AbstractDict, sheet_costs::AbstractDict)
    offset = haskey(capacity_rows, sheet_id) ? dual(capacity_rows[sheet_id]) : 0.0
    return offset - get(sheet_costs, sheet_id, 0.0)
end

"""
    pattern_reduced_cost(prices, item_counts, offset) -> Float64

The reduced cost of a pattern with `item_counts` (by original_part_id) at the
item `prices` and the sheet type's `offset`. Below 0 means it would lower the LP.
"""
function pattern_reduced_cost(prices::AbstractVector{<:Real}, item_counts::AbstractVector{<:Integer}, offset::Real)
    return -(sum(prices[i] * item_counts[i] for i in eachindex(item_counts); init = 0.0) + offset)
end

# --- The loop ---

"""
    run_column_generation(instance, pool, solve_lp, item_prices, pricing;
                          max_iterations = COLUMN_GENERATION_MAX_ITERATIONS,
                          time_limit = Inf,
                          gap_tolerance = COLUMN_GENERATION_GAP_TOLERANCE,
                          maximising = false) -> NamedTuple

Grows `pool` until the LP cannot be improved, or a limit is reached. Each
iteration solves the LP over the pool, prices the sheet types, and adds the
improving patterns.

  - `solve_lp(patterns)` returns the LP master over `patterns`, solved to
    optimality, as built by build_multi_period_model with `relax = true`.
  - `item_prices(master)` returns a vector of price vectors, each indexed by
    original_part_id: one for each period in
    the multi-period model. Every sheet type is priced at each.
  - `pricing(instance, sheet_id)` is the pricing generator (see default_pricing).

The run stops, with `stop_reason`:
  - `:optimal`, when no pattern improves the LP: it is solved over all patterns
  - `:gap`, when `gap_tolerance` is above 0 and the LP value is within that share
    of its lower bound
  - `:time_limit` or `:iteration_limit` (at most `max_iterations` LP solves)
  - `:stalled`, when every improving pattern was already in the pool, which only
    numerical noise explains

The patterns pricing finds at a stop other than `:stalled` are not added, so the
last LP is always the one over the final pool. At the iteration limit the last
pricing round is left out too.

The master always minimises. `maximising = true` says that it minimises the
negative of a value that is to be maximised: the loop then prints, and returns in
`lp_value`, `lp_bound` and the log, the value itself, and `lp_bound` is an upper
bound on it.

Returns `master` (the last LP), `iterations` (LP solves), `stop_reason`,
`lp_value`, `lp_bound` (equal to `lp_value` at `:optimal`), `log` (one entry per
iteration with its LP value, bound, pattern counts and seconds), `lp_seconds`
and `pricing_seconds`.
"""
function run_column_generation(
    instance       :: Instance,
    pool           :: PatternPool,
    solve_lp       :: Function,
    item_prices    :: Function,
    pricing        :: Function;
    max_iterations :: Int  = COLUMN_GENERATION_MAX_ITERATIONS,
    time_limit     :: Real = Inf,
    gap_tolerance  :: Real = COLUMN_GENERATION_GAP_TOLERANCE,
    maximising     :: Bool = false,
)
    max_iterations >= 1 || error("max_iterations must be at least 1, got $max_iterations")
    sense = maximising ? -1.0 : 1.0   # turns the master's objective into the value it stands for

    original_items = filter(i -> !i.rotated, instance.items)
    capacity       = Dict(s.sheet_id => s.capacity for s in instance.sheets)
    log            = NamedTuple[]
    started        = time()
    lp_seconds     = 0.0
    pricing_seconds = 0.0

    master      = nothing
    stop_reason = :iteration_limit
    iterations  = 0
    lp_value    = NaN
    lp_bound    = NaN

    for iteration in 1:max_iterations
        iterations = iteration

        step_start = time()
        master     = solve_lp(pool.patterns)
        lp_step    = time() - step_start
        lp_value   = objective_value(master.model)

        # Price every sheet type at every price vector. Vectors that match to 9
        # decimals (periods whose duals are equal, for instance when carrying parts
        # is free) share one run of the generator.
        step_start = time()
        offsets    = Dict(s.sheet_id => sheet_dual_offset(s.sheet_id, master.capacity_rows, master.sheet_costs)
                          for s in instance.sheets)
        price_sets = item_prices(master)

        # A pattern improves the LP when its reduced cost is below 0 by more than the
        # tolerance. The tolerance grows with the largest price, because duals are
        # only accurate to a share of their size, and prices can be large when buying
        # in is weighted heavily.
        tolerance  = REDUCED_COST_TOLERANCE * max(1.0, maximum(maximum(prices; init = 0.0) for prices in price_sets))
        found      = Dict{Tuple{Int, Vector{Float64}}, Union{Pattern, Nothing}}()
        lowest     = Dict(s.sheet_id => 0.0 for s in instance.sheets)
        candidates = Pattern[]
        for sheet in instance.sheets, prices in price_sets
            positive = max.(prices, 0.0)
            all(==(0.0), positive) && continue
            pattern = get!(found, (sheet.sheet_id, round.(positive, digits = 9))) do
                pricing(priced_instance(instance, prices), sheet.sheet_id)
            end
            pattern === nothing && continue
            reduced = pattern_reduced_cost(prices, pattern.item_counts, offsets[sheet.sheet_id])
            lowest[sheet.sheet_id] = min(lowest[sheet.sheet_id], reduced)
            reduced < -tolerance && push!(candidates, pattern)
        end
        price_step = time() - step_start

        lp_seconds      += lp_step
        pricing_seconds += price_step
        lp_bound         = lp_value + sum(capacity[id] * lowest[id] for id in keys(capacity); init = 0.0)

        n_new  = 0
        reason = nothing
        if isempty(candidates)
            reason   = :optimal
            lp_bound = lp_value
        elseif gap_tolerance > 0 && (lp_value - lp_bound) / max(abs(lp_value), 1.0) <= gap_tolerance
            reason = :gap
        elseif time() - started >= time_limit
            reason = :time_limit
        elseif iteration == max_iterations
            reason = :iteration_limit
        else
            for pattern in candidates
                _, is_new = add_pattern!(pool, pattern, original_items)
                n_new += is_new
            end
            n_new == 0 && (reason = :stalled)
        end

        n_in_lp = length(pool.patterns) - n_new
        push!(log, (iteration = iteration, lp_value = lp_value, lp_bound = lp_bound, patterns = n_in_lp,
                    new_patterns = n_new, lp_seconds = lp_step, pricing_seconds = price_step))
        println("Iteration $iteration: LP value $(round(sense * lp_value, digits = 2)), $n_in_lp patterns, $n_new new, ",
                "$(maximising ? "upper" : "lower") bound $(round(sense * lp_bound, digits = 2)) ",
                "(gap $(format_percent(col_gen_gap(lp_value, lp_bound))))")

        if reason !== nothing
            stop_reason = reason
            break
        end
    end

    log = [merge(entry, (lp_value = sense * entry.lp_value, lp_bound = sense * entry.lp_bound)) for entry in log]
    return (; master, iterations, stop_reason, lp_value = sense * lp_value, lp_bound = sense * lp_bound,
            log, lp_seconds, pricing_seconds)
end

# --- Reading and reporting the result ---

"""
    count_fractional(z) -> Int

How many of the pattern counts in `z` (a solved variable array) are further than
INTEGRALITY_TOLERANCE from a whole number.
"""
count_fractional(z) = count(v -> abs(v - round(v)) > INTEGRALITY_TOLERANCE, value.(z))

"""
    col_gen_gap(cost, bound) -> Float64

How far `cost` is above the lower `bound`, as a share of `cost` (or of 1 when
`cost` is smaller than 1 in size).
"""
col_gen_gap(cost::Real, bound::Real) = (cost - bound) / max(abs(cost), 1.0)

"""
    col_gen_note(; n_fractional, n_counts, stop_reason, n_patterns, ip_name) -> String

The note a run prints once its LP is done. It says whether the LP solution is
integral, how the LP stopped, and, when the solution is fractional, that the
generated patterns are being passed to the integer programme `ip_name`.
"""
function col_gen_note(; n_fractional::Int, n_counts::Int, stop_reason::Symbol, n_patterns::Int, ip_name::String)
    stop = if stop_reason == :optimal
        "the LP is solved over all patterns"
    elseif stop_reason == :gap
        "the LP was stopped early, once its lower bound was within the gap tolerance"
    elseif stop_reason == :iteration_limit
        "the LP was stopped at the iteration limit"
    elseif stop_reason == :time_limit
        "the LP was stopped at the time limit"
    else
        "the LP was stopped because pricing found only patterns the pool already holds"
    end

    if n_fractional == 0
        stop_reason == :optimal &&
            return "Note: $stop and its solution is integral, so it is optimal for the integer problem. No IP was solved."
        return "Note: $stop, so it is only solved over the $n_patterns patterns found. Its solution is " *
               "integral, so it is the best plan over those patterns. No IP was solved."
    end
    return "Note: the LP solution is fractional ($n_fractional of $n_counts pattern counts are not whole), " *
           "so the $n_patterns patterns found were passed to $ip_name."
end

"""
    print_col_gen_outcome(; final_step, cost, lp_bound, stop_reason)

Prints how the final plan compares with the LP lower bound: the plan's cost, the
bound and the gap between them. After an integer programme it says so, and when
the LP was stopped early it notes that the bound comes from the pricing.
"""
function print_col_gen_outcome(; final_step::Symbol, cost::Union{Nothing, Real}, lp_bound::Real, stop_reason::Symbol)
    cost === nothing && return
    println("\nColumn generation: ", final_step == :ip ? "integer programme" : "LP", " cost $(round(cost, digits = 2)), ",
            "LP lower bound $(round(lp_bound, digits = 2)), ",
            "$(format_percent(col_gen_gap(cost, lp_bound))) above the bound",
            stop_reason == :optimal ? "" : " (the bound is from the pricing, as the LP was stopped early)")
end

"""
    record_col_gen_stats!(stats, result, ip_stats)

If `stats` is a Dict, fills it from a column generation `result`: `n_iterations`,
`stop_reason`, `n_patterns`, `lp_value`, `lp_bound`, `lp_integral`, `final_step`,
`cost`, `ip_value`, `ip_gap`, `lp_seconds` and `pricing_seconds`. The statistics of
the integer programme, if one was solved (`ip_stats`, see record_solve_stats!),
are added with `ip_` in front of each key.
"""
function record_col_gen_stats!(stats::Union{Nothing, Dict{String, Any}}, result::NamedTuple, ip_stats::Dict{String, Any})
    stats === nothing && return nothing
    stats["n_iterations"]    = result.iterations
    stats["stop_reason"]     = String(result.stop_reason)
    stats["n_patterns"]      = length(result.patterns)
    stats["lp_value"]        = result.lp_value
    stats["lp_bound"]        = result.lp_bound
    stats["lp_integral"]     = result.lp_integral
    stats["final_step"]      = String(result.final_step)
    stats["cost"]            = result.cost
    stats["ip_value"]        = result.ip_value
    stats["ip_gap"]          = result.ip_gap
    stats["lp_seconds"]      = result.lp_seconds
    stats["pricing_seconds"] = result.pricing_seconds
    for (key, entry) in ip_stats
        stats["ip_" * key] = entry
    end
    return nothing
end
