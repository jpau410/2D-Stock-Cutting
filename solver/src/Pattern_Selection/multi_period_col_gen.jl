# solve_col_gen_multi_period: column generation on the multi-period model
# (multi_period_ip.jl). Instead of choosing from a fixed pool of patterns, it
# starts from the patterns it is given and generates the ones the model wants.
#
# The master problem is the LP relaxation of solve_ip_multi_period: the same model
# with the pattern counts continuous, built by build_multi_period_model. Each
# iteration solves it over the patterns found so far, prices every sheet type with
# a pattern generator (by default the revised DP), and adds the patterns that would
# lower the LP's cost (see helper/col_gen.jl).
#
# The model has an inventory balance row for each item and period, not a row for
# an item's total demand. So the prices are the duals of those rows, one set for
# each period, and every sheet type is priced once for each distinct set. The
# periods' prices differ by what carrying a part costs, and are equal when carrying
# is free. A pattern found for one period can be cut in any period, so it joins the
# pool for all of them.
#
# It stops when no pattern can improve the LP, so the LP is solved over all
# patterns, or at a limit. Then:
#   - If the LP solution is integral (every pattern count is a whole number), it
#     is the plan. When the LP was solved over all patterns it is optimal for the
#     integer problem, with no IP solved.
#   - If not, the generated patterns are passed to solve_ip_multi_period, and a
#     note says so. The plan is then the best one over the patterns generated,
#     which is not guaranteed to be the best over all patterns. The note compares
#     its cost with the LP's lower bound.
#
# The patterns a run starts from can be given, such as the patterns of the
# dichotomic search (pool seeding). The best pattern of every sheet is always
# added as well. Its value is the opportunity cost of cutting a sheet of that type,
# found once here and passed to the model as `sheet_costs`.
#
# Requires: build_multi_period_model, extract_multi_period_solution,
#           solve_ip_multi_period (multi_period_ip.jl),
#           check_initial_patterns, start_pool, default_pricing,
#           run_column_generation, count_fractional, col_gen_gap, col_gen_note,
#           print_col_gen_outcome, record_col_gen_stats! (helper/col_gen.jl),
#           check_item_holding_rate (helper/stock_valuation.jl),
#           Instance, Pattern (helper/structs.jl),
#           DEFAULT_ANNUAL_HOLDING_RATE,
#           COLUMN_GENERATION_MAX_ITERATIONS,
#           COLUMN_GENERATION_GAP_TOLERANCE (src/constants.jl)

"""
    solve_col_gen_multi_period(instance, period_demands; periods_per_year,
                               initial_patterns = Pattern[],
                               item_holding_rate = DEFAULT_ANNUAL_HOLDING_RATE,
                               clearance = 0.0, clearance_left = 0.0,
                               clearance_right = 0.0, clearance_top = 0.0,
                               clearance_bottom = 0.0, pricing = nothing,
                               max_iterations = COLUMN_GENERATION_MAX_ITERATIONS,
                               time_limit = Inf, ip_time_limit = Inf,
                               gap_tolerance = COLUMN_GENERATION_GAP_TOLERANCE,
                               stats = nothing) -> NamedTuple

Solves the model of `solve_ip_multi_period` by column generation (see the file
header). `period_demands`, `periods_per_year` and `item_holding_rate` are as in
`solve_ip_multi_period`. `initial_patterns` are the patterns the run starts from;
repeats are dropped, and each must be on a sheet of `instance` with one item
count per unrotated item. The best pattern of every sheet is added to them.

The clearance keywords are those of the default pricing generator, the revised
three-staged DP. `pricing` replaces it: a function `(instance, sheet_id) ->
Union{Pattern, Nothing}` that returns the best pattern on that sheet at the
instance's item values, such as `generate_pattern_dp_two_staged`. The
clearance keywords are then not used, and the lower bound holds only if
`pricing` is exact.

The run stops when no pattern improves the LP, after `max_iterations` LP solves,
after `time_limit` seconds, or, if `gap_tolerance` is above 0, once the LP value
is within that share of its lower bound (see run_column_generation). Each
iteration runs the pattern generator for every sheet type and every distinct set
of period prices, so a horizon of many periods with different prices costs that
many times as much as a single period. `time_limit` limits the LP solves and the
pricing, and `ip_time_limit` the integer programme that follows them if the LP
solution is fractional (see the `time_limit` of `solve_ip_multi_period`); both
are off (`Inf`) by default.

An iteration prints its LP value, the number of patterns, the new ones, and
the lower bound. When the LP is done a note says whether its solution is
integral, and so whether `solve_ip_multi_period` was needed. The plan is then
printed as that function prints it, followed by its cost against the lower bound.

If `stats` is a Dict, it is filled with the run's statistics (see
record_col_gen_stats!).

Returns a `NamedTuple`:
  - `solution`    :: the `NamedTuple` `solve_ip_multi_period` returns, over
    `patterns`; `nothing` if the integer programme did not solve to optimality
  - `patterns`    :: `Vector{Pattern}`, the final pool, numbered from 1; the
    `solution` refers to these
  - `cost`        :: `Float64`, the plan's objective over the horizon, in which buying
    in is weighted (see buy_in_weight). The plan's cost without the weight is
    `solution.costs.total`.
  - `lp_value`, `lp_bound` :: `Float64`, the LP's value over `patterns` and a
    lower bound on its value over all patterns; equal when `stop_reason` is
    `:optimal`
  - `lp_integral` :: `Bool`, whether the LP solution is integral
  - `final_step`  :: `:lp` or `:ip`, where `solution` came from
  - `ip_value`, `ip_gap` :: the integer programme's objective and its gap above
    `lp_bound` as a share of the cost; `nothing` if no IP was solved
  - `ip_status`   :: the integer programme's `"termination_status"`, `"OPTIMAL"`
    or, if it stopped at `ip_time_limit` with a plan, `"TIME_LIMIT"` (the plan is
    then the best found, not proven best over the patterns); `nothing` if no IP
    was solved
  - `stop_reason` :: `:optimal`, `:gap`, `:iteration_limit`, `:time_limit` or
    `:stalled`
  - `iterations`  :: `Int`, the LP solves
  - `log`         :: one `NamedTuple` per iteration: `iteration`, `lp_value`,
    `lp_bound`, `patterns`, `new_patterns`, `lp_seconds`, `pricing_seconds`
  - `n_given`, `n_optimal` :: how many distinct patterns were given, and how
    many optimal patterns were added
  - `sheet_costs` :: `Dict{Int, Float64}`, the value of each sheet type's best
    pattern, by sheet id: the opportunity cost of cutting one sheet of the type
  - `lp_seconds`, `pricing_seconds` :: `Float64`, the time spent in each
  - `note`        :: `String`, the note printed when the LP was done
"""
function solve_col_gen_multi_period(
    instance           :: Instance,
    period_demands     :: Matrix{Int};
    periods_per_year   :: Real,
    initial_patterns   :: Vector{Pattern} = Pattern[],
    item_holding_rate  :: Real = DEFAULT_ANNUAL_HOLDING_RATE,
    clearance          :: Real = 0.0,
    clearance_left     :: Real = 0.0,
    clearance_right    :: Real = 0.0,
    clearance_top      :: Real = 0.0,
    clearance_bottom   :: Real = 0.0,
    pricing            :: Union{Nothing, Function} = nothing,
    max_iterations     :: Int  = COLUMN_GENERATION_MAX_ITERATIONS,
    time_limit         :: Real = Inf,
    ip_time_limit      :: Real = Inf,
    gap_tolerance      :: Real = COLUMN_GENERATION_GAP_TOLERANCE,
    stats              :: Union{Nothing, Dict{String, Any}} = nothing,
)
    ip_time_limit > 0 || throw(ArgumentError("the IP time limit must be above 0, got $ip_time_limit"))
    check_item_holding_rate(item_holding_rate)
    check_initial_patterns(instance, initial_patterns)
    original_items = filter(i -> !i.rotated, instance.items)
    n_periods      = size(period_demands, 2)
    generator = pricing !== nothing ? pricing :
        default_pricing(clearance = clearance, clearance_left = clearance_left, clearance_right = clearance_right,
                        clearance_top = clearance_top, clearance_bottom = clearance_bottom)

    println("\n=== Multi-Period Column Generation ===")
    pool, n_given, n_optimal, sheet_costs = start_pool(instance, initial_patterns, generator)
    println("Started with $n_given distinct patterns from the $(length(initial_patterns)) given, and $n_optimal ",
            "optimal patterns the pool did not hold.")

    # The master problem: the multi-period model with the pattern counts
    # continuous. The prices of period m are the duals of that period's balance rows.
    solve_lp = patterns -> begin
        master = build_multi_period_model(
            instance, patterns, period_demands;
            periods_per_year = periods_per_year, sheet_costs = sheet_costs,
            item_holding_rate = item_holding_rate, relax = true,
        )
        optimize!(master.model)
        termination_status(master.model) == MOI.OPTIMAL ||
            error("the master LP did not solve to optimality: $(termination_status(master.model))")
        master
    end
    item_prices = master -> [
        [dual(master.balance_rows[(item.original_part_id, m)]) for item in original_items]
        for m in 1:n_periods
    ]

    run      = run_column_generation(instance, pool, solve_lp, item_prices, generator;
                                     max_iterations = max_iterations, time_limit = time_limit,
                                     gap_tolerance = gap_tolerance)
    patterns = pool.patterns

    n_fractional = count_fractional(run.master.z)
    note = col_gen_note(n_fractional = n_fractional, n_counts = length(patterns) * n_periods, stop_reason = run.stop_reason,
                        n_patterns = length(patterns), ip_name = "solve_ip_multi_period")
    println("\nLP over $(length(patterns)) patterns after $(run.iterations) iterations, value $(round(run.lp_value, digits = 2)).")
    println(note)

    ip_stats = Dict{String, Any}()
    if n_fractional == 0
        solution   = extract_multi_period_solution(instance, patterns, run.master; title = "Multi-Period Column Generation")
        final_step = :lp
        cost       = run.lp_value
        ip_value   = nothing
    else
        solution   = solve_ip_multi_period(instance, patterns, period_demands;
                                           periods_per_year = periods_per_year, sheet_costs = sheet_costs,
                                           item_holding_rate = item_holding_rate,
                                           time_limit = ip_time_limit, stats = ip_stats)
        final_step = :ip
        ip_value   = get(ip_stats, "objective_value", nothing)
        cost       = ip_value
    end
    ip_gap = ip_value === nothing ? nothing : col_gen_gap(ip_value, run.lp_bound)
    print_col_gen_outcome(final_step = final_step, cost = cost, lp_bound = run.lp_bound, stop_reason = run.stop_reason)

    result = (
        solution = solution, patterns = patterns, cost = cost,
        lp_value = run.lp_value, lp_bound = run.lp_bound, lp_integral = n_fractional == 0, final_step = final_step,
        ip_value = ip_value, ip_gap = ip_gap, ip_status = get(ip_stats, "termination_status", nothing),
        stop_reason = run.stop_reason, iterations = run.iterations, log = run.log,
        n_given = n_given, n_optimal = n_optimal, sheet_costs = sheet_costs,
        lp_seconds = run.lp_seconds, pricing_seconds = run.pricing_seconds,
        note = note,
    )
    record_col_gen_stats!(stats, result, ip_stats)
    return result
end
