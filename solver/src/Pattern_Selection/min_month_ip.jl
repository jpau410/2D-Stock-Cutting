using JuMP

# solve_ip_min_month: planning purely for profit, finds how many months of each
# item's demand the obsolete sheets cover. That is the item's runway: how long
# until it has to be bought in.
#
# For a horizon of m months and a set F of items already fixed, one integer
# programme is solved:
#
#     maximise    sum over items i of value_i * delivered_i
#     subject to  delivered_i <= sum over patterns p of count_i,p * z_p   for every item i
#                 delivered_i <= m * monthly_demand_i                      for every item i not in F
#                 delivered_i  = runway_i * monthly_demand_i               for every item i in F
#                 used_s <= capacity_s                                     for every sheet type s
#
# monthly_demand_i is the item's annual demand divided by MONTHS_PER_YEAR. The
# sheets carry no cost, so the stock is always used before anything is bought.
# An item is fully covered at m months when delivered_i reaches
# m * monthly_demand_i, and short otherwise.
#
# The horizon starts with no limit and shortens month by month. When an item
# that was short at m + 1 months is fully covered at m months, its runway is m.
# It is then fixed, and later solves must keep delivering that much of it, so
# its sheets can't go to other items. The items that deliver the most value per
# sheet are therefore covered longest. At 0 months every item left is fully
# covered, with a runway of 0.
#
# Horizons where nothing can change are skipped. A plan stays feasible, and so
# optimal, at every shorter horizon down to the most months any unfixed item
# gets in it, and no unfixed item becomes fully covered above that. So after
# each solve the next one is at that many months rounded down, or one month
# shorter if that is less. This finds the same runways as stepping one month
# at a time, with far fewer solves.
#
# Requires: Item, Sheet, Pattern, Instance, SelectedPattern (helper/structs.jl),
#           solution_waste (helper/wastage.jl),
#           print_plan_summary (helper/reporting.jl),
#           record_solve_stats! (helper/solve_stats.jl),
#           new_selection_model (helper/ip_model.jl),
#           MONTHS_PER_YEAR, COVERAGE_TOLERANCE (src/constants.jl)

"""
    solve_ip_min_month(instance, patterns; stats = nothing) -> Union{NamedTuple, Nothing}

Finds each item's runway: how many whole months of its demand the sheets in
`instance` cover when patterns from `patterns` are chosen purely for profit
(see the file header for the model and the procedure). Item demand is read
from `Item.demand` as annual demand.

A runway of m months means the sheets cover at least m months of the item's
demand but not m + 1. When two plans are equally good, for example two items
giving the same value per sheet, which item is covered longer can depend on
the plan the solver returns.

Items with no demand are left out: nothing of them counts, and they get no
runway. With an empty pool nothing can be cut, so every item with demand has a
runway of 0. Rotated forms share their unrotated item's demand and runway,
because every sum here runs over unrotated items and reads counts by
original_part_id, as `Pattern.item_counts` does.

If `stats` is a Dict, it is filled with the solve statistics (see
record_solve_stats!). Several integer programmes are solved, so `solve_seconds`
and `nodes` are totals over all of them. The status, objective, bound and gap
are those of the last solve, and `n_solves` is added.

After the runways it prints the lines every selection IP prints (see
print_plan_summary), worked out from the plan of the last solve. Whatever that
plan cuts beyond the demand the runways cover is the overproduction.

Returns `nothing` if a solve fails to reach optimality. Otherwise returns a
`NamedTuple`:
  - `runways`  :: `Vector{Union{Int, Nothing}}`, indexed by original_part_id:
    the months of demand covered, or `nothing` for an item with no demand.
  - `n_solves` :: `Int`, the number of integer programmes solved.
  - `selected` :: `Vector{SelectedPattern}`, the plan of the last solve. It is
    one of the plans that deliver the runways. Sheets carry no cost, so it can
    cut more than the runways need. If every runway is 0 the last solve delivers
    nothing, and it is empty.
  - `produced_value` :: `Float64`, the value of the demand the runways cover:
    the sum over items of value times runway times monthly demand. Whatever
    `selected` cuts beyond that is overproduction and is not counted.
  - `overproduced_value` :: `Float64`, the value of that overproduction.
  - `sheets_cut`, `sheets_available` :: `Int`, the sheets `selected` cuts and
    the capacity of the sheet types with patterns in the pool.
  - `waste`    :: the `solution_waste` result for `selected`.
"""
function solve_ip_min_month(
    instance :: Instance,
    patterns :: Vector{Pattern};
    stats    :: Union{Nothing, Dict{String, Any}} = nothing,
)
    n_patterns     = length(patterns)
    original_items = filter(i -> !i.rotated, instance.items)
    monthly_demand = Dict(item.original_part_id => item.demand / MONTHS_PER_YEAR for item in original_items)

    model = new_selection_model()

    @variable(model, z[1:n_patterns] >= 0, Int)

    # delivered[pid]: units of item pid counted against its demand. Continuous,
    # since a horizon's demand is usually not a whole number of units. Items
    # with no demand are held at 0.
    @variable(model, delivered[1:length(original_items)] >= 0)

    for item in original_items
        pid = item.original_part_id
        if item.demand > 0
            @constraint(model, delivered[pid] <= sum(patterns[p].item_counts[pid] * z[p] for p in 1:n_patterns))
        else
            fix(delivered[pid], 0.0; force = true)
        end
    end

    # Only sheet types with at least one pattern get a capacity constraint.
    for sheet in instance.sheets
        relevant = [p for p in 1:n_patterns if patterns[p].sheet_id == sheet.sheet_id]
        isempty(relevant) && continue
        @constraint(model, sum(z[p] for p in relevant) <= sheet.capacity)
    end

    @objective(model, Max, sum(item.value * delivered[item.original_part_id] for item in original_items))

    # --- Shorten the horizon, fixing items as they become fully covered ---
    free     = Set(item.original_part_id for item in original_items if item.demand > 0)
    runways  = Vector{Union{Int, Nothing}}(nothing, length(original_items))
    horizon  = nothing   # no limit on the first solve
    n_solves = 0
    plan     = zeros(n_patterns)   # the pattern counts of the latest solve

    # Time and branch-and-bound nodes are totalled over every solve. The rest
    # of the statistics come from the latest solve, so they are recorded right
    # after it, before the model is changed. They are also recorded here, so a
    # run with nothing to solve still reports its status and pool size.
    total_seconds = 0.0
    total_nodes   = 0
    record_solve_stats!(stats, model, n_patterns; solve_seconds = 0.0)
    stats === nothing || (stats["n_solves"] = 0)

    while !isempty(free)
        optimize!(model)
        n_solves      += 1
        total_seconds += solve_time(model)
        total_nodes   += MOI.get(model, MOI.NodeCount())
        record_solve_stats!(stats, model, n_patterns;
                            solve_seconds = total_seconds, nodes = total_nodes)
        stats === nothing || (stats["n_solves"] = n_solves)
        if termination_status(model) != MOI.OPTIMAL
            @warn "Min-month IP at horizon $(something(horizon, "unlimited")) did not solve to optimality: $(termination_status(model))"
            return nothing
        end

        # Read the plan before changing the model, which discards the solution.
        amount = Dict(pid => value(delivered[pid]) for pid in free)
        plan   = value.(z)

        if horizon !== nothing
            for pid in collect(free)
                amount[pid] >= horizon * monthly_demand[pid] - COVERAGE_TOLERANCE || continue
                runways[pid] = horizon
                fix(delivered[pid], horizon * monthly_demand[pid]; force = true)
                delete!(free, pid)
            end
        end
        isempty(free) && break

        # This plan stays optimal down to the most months any free item gets
        # in it (see the file header), so the next solve is there.
        longest = maximum(amount[pid] / monthly_demand[pid] for pid in free)
        next    = floor(Int, longest + COVERAGE_TOLERANCE)
        horizon = horizon === nothing ? next : min(next, horizon - 1)

        # The plan, with each free item's delivery cut back to its new limit,
        # is feasible at the new horizon, so the next solve starts from it.
        for pid in free
            limit = horizon * monthly_demand[pid]
            set_upper_bound(delivered[pid], limit)
            set_start_value(delivered[pid], min(amount[pid], limit))
        end
        for item in original_items
            pid = item.original_part_id
            pid in free || set_start_value(delivered[pid], fix_value(delivered[pid]))
        end
        set_start_value.(z, plan)
    end

    # The plan of the last solve, and what it reports: the demand the runways cover
    # is what counts as produced, and anything cut beyond it is overproduction.
    selected         = [SelectedPattern(patterns[p].pattern_id, round(Int, plan[p]))
                        for p in 1:n_patterns if round(Int, plan[p]) > 0]
    sheets_cut       = sum(chosen.quantity for chosen in selected; init = 0)
    pooled_sheet_ids = Set(pattern.sheet_id for pattern in patterns)
    sheets_available = sum(sheet.capacity for sheet in instance.sheets
                           if sheet.sheet_id in pooled_sheet_ids; init = 0)
    waste            = solution_waste(selected, patterns, instance)
    produced_value   = sum(
        item.value * runways[item.original_part_id] * monthly_demand[item.original_part_id]
        for item in original_items if runways[item.original_part_id] !== nothing;
        init = 0.0,
    )
    # What the plan cuts beyond the demand the runways cover is overproduction.
    cut_units = zeros(length(original_items))
    for chosen in selected, item in original_items
        cut_units[item.original_part_id] += chosen.quantity * patterns[findfirst(p -> p.pattern_id == chosen.pattern_id, patterns)].item_counts[item.original_part_id]
    end
    over_units = [max(0.0, cut_units[item.original_part_id] -
                      (runways[item.original_part_id] === nothing ? 0 : runways[item.original_part_id]) * monthly_demand[item.original_part_id])
                  for item in original_items]
    overproduced_units = sum(over_units)
    overproduced_value = sum(item.value * over_units[item.original_part_id] for item in original_items)

    println("\n=== Min-Month IP ===")
    for item in sort(original_items; by = item -> something(runways[item.original_part_id], -1), rev = true)
        runway = runways[item.original_part_id]
        println(runway === nothing ? "$(item.name): no demand, left out" : "$(item.name): $runway month$(runway == 1 ? "" : "s")")
    end

    println()
    print_plan_summary(
        sheets_cut       = sheets_cut,
        sheets_available = sheets_available,
        waste_fraction   = waste.waste_fraction,
        produced_value   = produced_value,
        overproduced_units = overproduced_units,
        overproduced_value = overproduced_value,
    )
    println("Integer programmes solved: $n_solves")

    return (
        runways          = runways,
        n_solves         = n_solves,
        selected         = selected,
        produced_value   = produced_value,
        overproduced_value = overproduced_value,
        sheets_cut       = sheets_cut,
        sheets_available = sheets_available,
        waste            = waste,
    )
end
