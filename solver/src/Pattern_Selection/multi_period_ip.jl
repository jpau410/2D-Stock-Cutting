using JuMP

# solve_ip_multi_period: chooses which patterns to cut in each period, and
# what to buy in, so that every period's demand is met. The sheets are used
# before anything is bought, and when there are more sheets than the demand
# needs, the least valuable ones are cut and the most valuable are saved. One
# period is allowed: with one period and periods_per_year = 1 it plans a single
# year's demand at once.
#
# Each period's demand is met from the inventory carried in plus what is cut and
# bought that period, and whatever is left over is carried forward. Sheet
# capacity is shared across the whole horizon. The model minimises
#
#     minimise    buy_weight * sum over items i and periods m of value_i * buy_i,m
#               + sum over sheet types s of opportunity_cost_s * used_s
#               + sum over items i and periods m of
#                     (item_holding_rate / periods_per_year) * value_i * inventory_i,m
#
#     subject to  inventory_i,m-1 + produced_i,m + buy_i,m = demand_i,m + inventory_i,m
#                                                   for every item i and period m
#                 used_s <= capacity_s              for every sheet type s
#
# inventory_i,m is the number of item i in inventory at the end of period m,
# with inventory_i,0 = 0. T is the last period, and used_s counts the sheets of
# type s cut over the whole horizon. Demand is always met, by cutting or buying,
# so the model is always feasible. Buying an item in costs its value. Inventory
# costs one period's share of its yearly holding cost for every period it is held
# at the end of, so cutting parts before they are needed costs something, and so
# does overproducing: what is left at the end of the horizon is charged one more
# period, as if it were carried into the next.
#
# --- Buying in is the last resort ---
#
# opportunity_cost_s is what cutting one sheet of type s gives up: the value of
# its best packing, the pattern whose parts are worth the most, however much
# demand there is for those parts. It is a constant of the data, found once by
# the pattern generator and given to the model as `sheet_costs`. buy_weight is so
# large (see buy_in_weight in
# helper/stock_valuation.jl) that buying one unit less is worth more than any
# change in all the other terms together. So the plan buys in as little as the
# sheets allow and, among the plans that buy the least, costs the least. That
# gives two cases from one model:
#   - Too few sheets to meet the demand: every sheet that can supply an item that
#     is still short is cut, and what the sheets cannot supply is bought in.
#   - Enough sheets: nothing is bought in, and the sheets cut are the ones that
#     give up the least. Sheets are valued at their best packing, so the least
#     valuable sheets are used and the most valuable are saved.
# A sheet that can hold none of the items has no pattern, so it is never cut.
#
# The costs reported with a plan leave out buy_weight: buying in is counted at the
# value of the items bought.
#
# Requires: Item, Sheet, Pattern, Instance, Solution, SelectedPattern
#           (helper/structs.jl),
#           whole_value, check_item_holding_rate, pooled_sheet_patterns,
#           check_sheet_costs, buy_in_weight (helper/stock_valuation.jl),
#           solution_waste (helper/wastage.jl),
#           print_plan_summary, print_waste_by_period, format_percent (helper/reporting.jl),
#           record_solve_stats! (helper/solve_stats.jl),
#           new_selection_model (helper/ip_model.jl),
#           DEFAULT_ANNUAL_HOLDING_RATE (src/constants.jl)

"""
    solve_ip_multi_period(instance, patterns, period_demands; periods_per_year, sheet_costs,
                          item_holding_rate = DEFAULT_ANNUAL_HOLDING_RATE,
                          time_limit = Inf, stats = nothing) -> Union{NamedTuple, Nothing}

Chooses patterns to cut and items to buy in each period so that every period's
demand is met, buying in as little as the sheets allow and, among those plans,
at the lowest cost (see the file header for the model).

`period_demands` is `n_items` by `n_periods`, one row per unrotated item. The
number of periods is read from its second dimension, so the horizon can be
any length. The demand is the demand to be met, whatever time it covers: nothing
is estimated for a year.

`periods_per_year` is how many periods make up a year, for example 12 when
each period is a month. The annual `item_holding_rate` divided by it is the
cost of carrying a part from one period to the next, as a share of its
value, and so is the cost of the inventory left at the end of the horizon: one
extra period. `item_holding_rate` is the yearly cost of holding an item, as a
share of its value, and must be at least 0.

`sheet_costs` maps each sheet id to the opportunity cost of cutting one sheet of
the type: the value of its best packing, the pattern worth the most at the true
item values (see check_sheet_costs). Find it once with the pattern generator,
for example as the `.value` of `generate_pattern_dp_revised_three_staged(instance,
sheet_id)`. Every pattern's `.value` must be the value of its parts at the true
item values, as the pattern generators leave it, and no more than the cost of its
sheet type. Sheet types with no pattern in `patterns` are never cut.

With one period and `periods_per_year = 1` the carrying sum is empty and this is
a plan for one year's demand at once.

Rotated forms share their unrotated item's rows, because every sum here runs
over unrotated items and reads counts by original_part_id, as
`Pattern.item_counts` does.

With an empty pool nothing is cut and all of the demand is bought in.

After the items it prints the lines every selection IP prints (see
print_plan_summary) for the whole horizon: the sheets cut, the sheet waste and
the value of the items produced, not counting overproduction, and the
overproduced items left in storage at the end. The sheet waste of each period
and its own cost terms follow.

`time_limit` is the number of seconds the solver may take, off (`Inf`) by
default, when the IP is solved to its gap (`MIP_REL_GAP`). If it runs out with a
plan in hand, that plan is returned, a line says it was not proven best and how
far from the solver's bound it is, and the statistics' `"termination_status"` is
`"TIME_LIMIT"`.

If `stats` is a Dict, it is filled with the solve's statistics (see
record_solve_stats!): status, solve time and pool size, plus the objective,
bound, gap and branch-and-bound node count when a solution exists.

Returns `nothing` if the model does not solve to optimality, or, with a time
limit, if it runs out before a plan is found. Otherwise returns a `NamedTuple`:
  - `solutions` :: `Vector{Solution}`, one per period. `items_produced` in
    each is everything cut that period, including parts carried to later
    periods, which are inventory rather than overproduction, and
    `total_profit` is its value. Both are reported for comparison and are not
    what this function optimises. The parts left over at the end of the
    horizon are the last column of `inventory`. They are still counted in the
    period they were cut, so the periods' `total_profit` add up to
    `produced_value` plus the value of those parts, which is overproduction.
  - `bought`    :: `Matrix{Float64}`, `n_items` by `n_periods`, units of each
    item bought in each period.
  - `inventory` :: `Matrix{Float64}`, `n_items` by `n_periods`, units of each
    item in inventory at the end of each period.
  - `costs`     :: `NamedTuple` of the plan's three cost terms over the whole
    horizon (`buy_cost`, the value of the items bought; `sheet_opportunity_cost`;
    `item_holding`) and their `total`. None of them is multiplied by
    `buy_weight`.
  - `buy_weight` :: `Float64`, the weight the objective puts on buying in.
  - `sheets_cut`, `sheets_available` :: `Int`, the sheets cut over the
    horizon and the capacity they were cut from, both over the sheet types
    with patterns in the pool.
  - `produced_value` :: `Float64`, the value of the parts cut that went to
    meeting demand over the horizon: everything cut, less what is left at the
    end, which is overproduction. A part carried to a later period counts once
    it is used.
  - `overproduced_value` :: `Float64`, the value of the parts left in storage at
    the end of the horizon. They are printed under the produced value.
  - `waste`     :: the `solution_waste` result for the whole horizon, with the
    area of the sheets cut and the waste area added up over the periods.
  - `waste_by_period` :: the `solution_waste` result for each period.
"""
function solve_ip_multi_period(
    instance           :: Instance,
    patterns           :: Vector{Pattern},
    period_demands     :: Matrix{Int};
    periods_per_year   :: Real,
    sheet_costs        :: AbstractDict,
    item_holding_rate  :: Real = DEFAULT_ANNUAL_HOLDING_RATE,
    time_limit         :: Real = Inf,
    stats              :: Union{Nothing, Dict{String, Any}} = nothing,
)
    time_limit > 0 || throw(ArgumentError("the time limit must be above 0, got $time_limit"))
    master = build_multi_period_model(
        instance, patterns, period_demands;
        periods_per_year = periods_per_year, sheet_costs = sheet_costs, item_holding_rate = item_holding_rate,
    )
    isfinite(time_limit) && set_time_limit_sec(master.model, Float64(time_limit))
    optimize!(master.model)
    record_solve_stats!(stats, master.model, length(patterns))

    # At the time limit the best plan found so far is still a plan, though it is
    # not proven best
    cut_short = termination_status(master.model) == MOI.TIME_LIMIT && primal_status(master.model) == MOI.FEASIBLE_POINT
    if termination_status(master.model) != MOI.OPTIMAL && !cut_short
        @warn "Multi-period IP did not solve to optimality: $(termination_status(master.model))"
        return nothing
    end

    solution = extract_multi_period_solution(instance, patterns, master)
    cut_short && println("Stopped at the time limit of $time_limit s: this is the best plan found, not proven best. ",
                         "Its cost is within $(format_percent(relative_gap(master.model))) of the solver's bound.")
    return solution
end

# --- The model and the solution, shared with column generation ---
#
# solve_ip_multi_period builds its model with build_multi_period_model and
# reads the solution with extract_multi_period_solution. Column generation
# (multi_period_col_gen.jl) uses the same two with the pattern counts relaxed,
# so its master problem is always this model.

"""
    build_multi_period_model(instance, patterns, period_demands; periods_per_year, sheet_costs,
                             item_holding_rate = DEFAULT_ANNUAL_HOLDING_RATE,
                             relax = false) -> NamedTuple

The model of `solve_ip_multi_period` over `patterns`, built but not solved.
With `relax = true` the pattern counts are continuous, which is the LP
relaxation whose duals column generation reads.

Returns a `NamedTuple` with
  - `model`, and its variables `z` (pattern by period), `buy` and `inventory`
    (item by period)
  - `produced` and `used`, expressions by item id and period, and by sheet id
  - `buy_cost`, `sheet_cost` and `item_holding`, the objective's three terms, with
    `buy_cost` the value of the items bought, before it is multiplied by
    `buy_weight`
  - `balance_rows` and `capacity_rows`, the constraints: the inventory balance of
    each item and period (keyed by item id and period), and the capacity of each
    sheet type over the whole horizon
  - `sheet_costs`, the opportunity cost of cutting one sheet of each sheet type
    (by sheet id), as given, which column generation reads
  - `buy_weight`, the weight on buying in (see buy_in_weight)
  - `pooled_sheets`, `original_items`, `period_demands`,
    `n_periods`, `n_items`, `item_holding_rate` and `periods_per_year`, which
    reading the solution needs.

Errors if the item holding rate or `periods_per_year` is out of range, if
`sheet_costs` is not valid for the patterns (see check_sheet_costs), or if
`period_demands` does not have one row per unrotated item and a period.
"""
function build_multi_period_model(
    instance           :: Instance,
    patterns           :: Vector{Pattern},
    period_demands     :: Matrix{Int};
    periods_per_year   :: Real,
    sheet_costs        :: AbstractDict,
    item_holding_rate  :: Real = DEFAULT_ANNUAL_HOLDING_RATE,
    relax              :: Bool = false,
)
    check_item_holding_rate(item_holding_rate)
    periods_per_year > 0 ||
        error("periods_per_year must be above 0, got $periods_per_year")

    n_patterns     = length(patterns)
    n_periods      = size(period_demands, 2)
    original_items = filter(i -> !i.rotated, instance.items)
    n_items        = length(original_items)

    size(period_demands, 1) == n_items ||
        error("period_demands has $(size(period_demands, 1)) rows, expected $n_items (one per original item)")
    n_periods >= 1 ||
        error("period_demands has no periods")

    # Patterns per sheet type and the sheet types with patterns in the pool.
    # Cutting a sheet gives up the value of its type's best packing, whatever the
    # demand, and buying in is weighted so heavily that it is the last resort
    # (see the file header).
    patterns_on_sheet, pooled_sheets = pooled_sheet_patterns(instance, patterns)
    check_sheet_costs(sheet_costs, pooled_sheets, patterns, patterns_on_sheet)
    buy_weight = buy_in_weight(pooled_sheets, sheet_costs, original_items, item_holding_rate, n_periods, periods_per_year)

    model = new_selection_model()

    # z[p, m]: how many times pattern p is cut in period m. With relax the
    # counts are continuous: the LP relaxation.
    if relax
        @variable(model, z[1:n_patterns, 1:n_periods] >= 0)
    else
        @variable(model, z[1:n_patterns, 1:n_periods] >= 0, Int)
    end

    # buy[pid, m] and inventory[pid, m]: units of item pid bought in period m,
    # and its inventory at the end of period m. Both are continuous: demand and
    # production are integers, so with the inventory balance below they land on
    # integer values without being declared Int.
    @variable(model, buy[1:n_items, 1:n_periods] >= 0)
    @variable(model, inventory[1:n_items, 1:n_periods] >= 0)

    # init = 0.0 is needed: with an empty pattern pool, summing over zero
    # patterns throws without an initial value.
    produced = Dict(
        (item.original_part_id, m) => sum(
            (patterns[p].item_counts[item.original_part_id] * z[p, m] for p in 1:n_patterns);
            init = 0.0,
        )
        for item in original_items, m in 1:n_periods
    )

    # Inventory balance. Nothing is in inventory before the first period, so the
    # inventory carried into it is the constant 0. There is one row for each item
    # and period, not one for its total demand: a part cut in period m meets
    # period m's demand or goes into inventory.
    balance_rows = Dict{Tuple{Int, Int}, Any}()
    for item in original_items
        pid = item.original_part_id
        for m in 1:n_periods
            carried_in = m == 1 ? 0.0 : inventory[pid, m - 1]
            balance_rows[(pid, m)] = @constraint(model,
                carried_in + produced[(pid, m)] + buy[pid, m] == period_demands[pid, m] + inventory[pid, m]
            )
        end
    end

    # Sheets of each type cut over the whole horizon, since capacity is shared
    # across every period.
    used = Dict(
        sheet.sheet_id => sum(z[p, m] for p in patterns_on_sheet[sheet.sheet_id], m in 1:n_periods)
        for sheet in pooled_sheets
    )

    capacity_rows = Dict(
        sheet.sheet_id => @constraint(model, used[sheet.sheet_id] <= sheet.capacity)
        for sheet in pooled_sheets
    )

    # --- Objective: the four cost terms in the file header ---
    # Kept as separate expressions so each can be printed after the solve.
    buy_cost = @expression(model,
        sum(item.value * buy[item.original_part_id, m] for item in original_items, m in 1:n_periods)
    )
    sheet_cost = @expression(model,
        sum((sheet_costs[sheet.sheet_id] * used[sheet.sheet_id] for sheet in pooled_sheets); init = 0.0)
    )
    item_holding = @expression(model,
        sum(
            (item_holding_rate / periods_per_year) * item.value * inventory[item.original_part_id, m]
            for item in original_items, m in 1:n_periods
        )
    )
    @objective(model, Min, buy_weight * buy_cost + sheet_cost + item_holding)

    return (; model, z, buy, inventory, produced, used,
              buy_cost, sheet_cost, item_holding,
              balance_rows, capacity_rows, sheet_costs, buy_weight,
              pooled_sheets, original_items, period_demands,
              n_periods, n_items, item_holding_rate, periods_per_year)
end

"""
    extract_multi_period_solution(instance, patterns, master;
                                  title = "Multi-Period IP") -> NamedTuple

Reads a solved `master` (from `build_multi_period_model`) into the
`NamedTuple` that `solve_ip_multi_period` returns, and prints the items and the
summary lines under `title`. The pattern counts are rounded to whole numbers,
so this also reads an LP solution whose counts are whole.
"""
function extract_multi_period_solution(
    instance :: Instance,
    patterns :: Vector{Pattern},
    master   :: NamedTuple;
    title    :: String = "Multi-Period IP",
)
    (; z, buy, inventory, produced, used, buy_cost, item_holding,
       pooled_sheets, sheet_costs, buy_weight, original_items, period_demands, n_periods, n_items) = master
    n_patterns = length(patterns)

    period_selected = Vector{Vector{SelectedPattern}}(undef, n_periods)
    for m in 1:n_periods
        selected = SelectedPattern[]
        for p in 1:n_patterns
            zval = round(Int, value(z[p, m]))
            zval > 0 && push!(selected, SelectedPattern(patterns[p].pattern_id, zval))
        end
        period_selected[m] = selected
    end

    # items_produced is everything cut in each period, including parts carried
    # to later periods (see the docstring). buy and inventory are read through
    # whole_value, like the cost terms below, so solver tolerance doesn't show.
    items_produced = zeros(Int, n_items, n_periods)
    bought         = zeros(Float64, n_items, n_periods)
    held           = zeros(Float64, n_items, n_periods)
    for item in original_items
        pid = item.original_part_id
        for m in 1:n_periods
            items_produced[pid, m] = round(Int, value(produced[(pid, m)]))
            bought[pid, m]         = whole_value(buy[pid, m])
            held[pid, m]           = whole_value(inventory[pid, m])
        end
    end

    println("\n=== $title ===")
    for item in original_items
        pid      = item.original_part_id
        n_bought = sum(bought[pid, :])
        leftover = held[pid, n_periods]
        println(
            "$(item.name): cut $(sum(items_produced[pid, :]))" *
            (n_bought > 0 ? " + bought $(round(n_bought, digits=2))" : "") *
            " / demand $(sum(period_demands[pid, :]))" *
            (leftover > 0 ? " — left at the end: $(round(leftover, digits=2))" : "")
        )
    end

    sheets_cut_by_type = Dict(sheet.sheet_id => round(Int, value(used[sheet.sheet_id])) for sheet in pooled_sheets)
    sheets_cut         = sum(values(sheets_cut_by_type); init = 0)
    sheets_available   = sum(sheet.capacity for sheet in pooled_sheets; init = 0)

    # Each cost term at the rounded solution (see whole_value), and their sum.
    # None is multiplied by the weight on buying in.
    cost_terms = (
        buy_cost               = value(whole_value, buy_cost),
        sheet_opportunity_cost = sum((sheet_costs[sheet.sheet_id] * sheets_cut_by_type[sheet.sheet_id]
                                      for sheet in pooled_sheets); init = 0.0),
        item_holding           = value(whole_value, item_holding),
    )
    costs = merge(cost_terms, (total = sum(cost_terms),))

    # The parts cut over the horizon, less what is left at the end, are the ones
    # that went to meeting demand. What is left is overproduction.
    produced_units = [max(0.0, sum(items_produced[pid, :]) - held[pid, n_periods]) for pid in 1:n_items]
    produced_value = sum(item.value * produced_units[item.original_part_id] for item in original_items)
    overproduced_units = sum(held[:, n_periods])
    overproduced_value = sum(item.value * held[item.original_part_id, n_periods] for item in original_items)

    # The waste of each period, and of the whole horizon with the areas added up.
    period_waste = [solution_waste(selected, patterns, instance) for selected in period_selected]
    waste        = solution_waste(reduce(vcat, period_selected), patterns, instance)

    println()
    print_plan_summary(
        sheets_cut       = sheets_cut,
        sheets_available = sheets_available,
        waste_fraction   = waste.waste_fraction,
        produced_value   = produced_value,
        overproduced_units = overproduced_units,
        overproduced_value = overproduced_value,
    )
    print_waste_by_period(period_waste)
    println("Cost of items bought in: ", round(costs.buy_cost, digits = 2))
    println("Opportunity cost of sheets cut: ", round(costs.sheet_opportunity_cost, digits = 2))
    println("Holding cost of items: ", round(costs.item_holding, digits = 2))
    println("Total cost: ", round(costs.total, digits = 2),
            " (the objective weights buying in $(round(buy_weight, digits = 1)) times, so items are bought only when the sheets cannot supply them)")

    period_solutions = map(1:n_periods) do m
        produced_m = items_produced[:, m]
        profit_m   = sum(item.value * produced_m[item.original_part_id] for item in original_items)
        Solution(profit_m, period_selected[m], produced_m)
    end

    return (
        solutions        = period_solutions,
        bought           = bought,
        inventory        = held,
        costs            = costs,
        buy_weight       = buy_weight,
        sheets_cut       = sheets_cut,
        sheets_available = sheets_available,
        produced_value   = produced_value,
        overproduced_value = overproduced_value,
        waste            = waste,
        waste_by_period  = period_waste,
    )
end
