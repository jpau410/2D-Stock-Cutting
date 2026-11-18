# job_runner.jl: runs one job, in its own process.
#
# Usage, from the application folder:
#   julia --project app/job_runner.jl JOB_DIR
#
# JOB_DIR holds input.json, written by the server:
#   {"items": [row, ...], "sheets": [row, ...], "settings": {...}}
# where a row is an object from column name to cell text (see data_input.jl).
# The runner writes, into the same folder,
#   status.json   what it is doing, rewritten as it goes
#   result.json   the results, rewritten after every group, so a run that is
#                 stopped early keeps what it had finished
# and prints the solver's own output, which the server keeps as the job's log.
#
# Each group (one combination of thickness, material and finish) is a separate
# problem. For each group the runner builds the instance, optionally seeds the
# pattern pool with the dichotomic patterns, runs column generation on the
# multi-period model (one period is a year's demand), and places the items of
# every pattern used. It can also work out the months of cover, and the length
# of an infinite roll.
#
# Requires: load_models.jl, data_input.jl, settings.jl, layout.jl

using JSON

include(joinpath(@__DIR__, "load_models.jl"))
include(joinpath(@__DIR__, "data_input.jl"))
include(joinpath(@__DIR__, "settings.jl"))
include(joinpath(@__DIR__, "layout.jl"))

# --- Status and result files ---

# Floats that JSON cannot hold become null, and solver types become plain data
json_safe(x::AbstractFloat) = isfinite(x) ? x : nothing
json_safe(x::Symbol) = String(x)
json_safe(x::AbstractDict) = Dict{String, Any}(string(k) => json_safe(v) for (k, v) in x)
json_safe(x::NamedTuple) = Dict{String, Any}(string(k) => json_safe(v) for (k, v) in pairs(x))
json_safe(x::Union{AbstractVector, Tuple}) = Any[json_safe(v) for v in x]
json_safe(x) = x

# Writes a file so that a reader never sees it half written. The server reads these
# files while the run is writing them, and replacing a file that is being read can
# fail on some systems, so the replacement is tried again.
function write_json_file(path::String, content)
    temporary = path * ".tmp"
    open(temporary, "w") do io
        write(io, JSON.json(json_safe(content)))
    end
    for attempt in 1:20
        try
            mv(temporary, path; force = true)
            return nothing
        catch
            attempt == 20 && rethrow()
            sleep(0.05)
        end
    end
end

const STATUS = Dict{String, Any}("state" => "running", "stage" => "Starting", "group" => 0, "groups" => 0,
                                 "started" => time(), "finished" => nothing, "error" => nothing)

function report_stage(job_dir::String, stage::String; group::Union{Int, Nothing} = nothing, groups::Union{Int, Nothing} = nothing,
                      state::String = "running", error_message::Union{String, Nothing} = nothing)
    STATUS["stage"] = stage
    STATUS["state"] = state
    group  === nothing || (STATUS["group"]  = group)
    groups === nothing || (STATUS["groups"] = groups)
    STATUS["updated"] = time()
    state == "running" || (STATUS["finished"] = time())
    STATUS["error"] = error_message
    println("\n[app] ", stage)
    write_json_file(joinpath(job_dir, "status.json"), STATUS)
end

# --- Building an instance ---

# A year's demand for an item, from its demand in each period. With one period
# that period is a year. With several, a year is periods_per_year times the
# average period, as the multi-period model estimates it.
function annual_demand(demand::Vector{Int}, periods_per_year::Real)::Int
    length(demand) == 1 && return demand[1]
    return round(Int, periods_per_year * sum(demand) / length(demand))
end

# The solver's items for the item records, numbered 1, 2, ... in order, with the
# rotated forms of those that can be turned. The annual demand is the item's
# demand for the models that read a single figure.
function solver_items(records::Vector{ItemRecord}, periods_per_year::Real)::Vector{Item}
    items    = [Item(k, r.item_id, annual_demand(r.demand, periods_per_year), r.value, r.width, r.height)
                for (k, r) in enumerate(records)]
    rotation = Dict{Int, Bool}(k => r.can_rotate for (k, r) in enumerate(records))
    return expand_with_rotations(items; rotation_allowed = rotation)
end

# The clearance keywords of the DP and the models, from the settings
clearance_keywords(c) = (clearance = c.gap, clearance_left = c.left, clearance_right = c.right,
                         clearance_top = c.top, clearance_bottom = c.bottom)

# --- Describing patterns ---

# The patterns used by a plan as plain data. `quantities` maps a pattern id to
# the number of times it is cut in each period; `sheet_of` maps a solver sheet id
# to its record. Each pattern carries the position of every item on its sheet.
#
# With `roll = true` the patterns are shelves of a roll. A shelf is drawn as a
# sheet as wide as the roll and as tall as the shelf plus the gap above and below
# it, with the left and right margins at its sides. The top and bottom margins are
# not drawn: they only limited how tall the shelf could be. Along the roll, a shelf
# counts its own height plus one gap towards the length.
function describe_patterns(patterns::Vector{Pattern}, quantities::Dict{Int, Vector{Int}}, instance::Instance,
                           records::Vector{ItemRecord}, sheet_of::Dict{Int, SheetRecord}, clearance;
                           roll::Bool = false, shelf_heights::Union{Nothing, Vector{Float64}} = nothing)
    by_id  = Dict(p.pattern_id => p for p in patterns)
    sheets = Dict(s.sheet_id => s for s in instance.sheets)
    described = Dict{String, Any}[]
    for pattern_id in sort(collect(keys(quantities)))
        pattern  = by_id[pattern_id]
        sheet    = sheets[pattern.sheet_id]
        shown    = clearance
        if roll
            sheet = Sheet(sheet.sheet_id, 1, sheet.width, shelf_heights[pattern_id] + 2 * clearance.gap)
            shown = merge(clearance, (top = clearance.gap, bottom = clearance.gap))
        end
        layout   = layout_pattern(pattern, instance, sheet; clearance_keywords(shown)...)
        counts   = Dict{String, Int}(records[k].item_id => c for (k, c) in enumerate(pattern.item_counts) if c > 0)
        entry = Dict{String, Any}(
            "pattern" => pattern_id,
            "quantity" => sum(quantities[pattern_id]),
            "quantity_by_period" => quantities[pattern_id],
            "item_counts" => counts,
            "value" => sum(records[k].value * c for (k, c) in enumerate(pattern.item_counts)),
            "utilisation" => layout.utilisation,
            "layout" => Dict{String, Any}(
                "width" => layout.width, "height" => layout.height,
                "items" => [Dict{String, Any}("item_id" => records[p.original_part_id].item_id, "rotated" => p.rotated,
                                              "x" => p.x, "y" => p.y, "w" => p.w, "h" => p.h) for p in layout.items],
                "gaps" => [Dict{String, Any}("x" => g.x, "y" => g.y, "w" => g.w, "h" => g.h) for g in layout.gaps],
                "problems" => layout.problems),
        )
        if roll
            entry["shelf_height"] = shelf_heights[pattern_id]
        else
            record = sheet_of[pattern.sheet_id]
            entry["sheet_id"] = record.sheet_id
            entry["sheet_width"] = record.width
            entry["sheet_height"] = record.height
        end
        push!(described, entry)
    end
    return described
end

# --- A group of items and sheets ---

# The part ids (positions in `records`) of the items that can be placed on at
# least one of the instance's sheets under the clearance
function placeable_item_positions(instance::Instance, clearance)::Set{Int}
    placeable = Set{Int}()
    for sheet in instance.sheets
        for item in items_fitting_sheet(instance.items, sheet, clearance.gap, clearance.left, clearance.right,
                                        clearance.top, clearance.bottom)
            push!(placeable, item.original_part_id)
        end
    end
    return placeable
end

# The totals of an items table, in items and in value, as shown at the top of a
# group's results: the demand, how much of it the sheets supply and how much is
# bought in, and what is left over after the demand is met
function item_totals(table::Vector{Dict{String, Any}})
    units(key)  = sum((it[key] for it in table); init = 0.0)
    worth(key)  = sum((it["value"] * it[key] for it in table); init = 0.0)
    return Dict{String, Any}(
        "demand_units" => units("demand"), "demand_value" => worth("demand"),
        "from_sheets_units" => units("from_sheets"), "from_sheets_value" => worth("from_sheets"),
        "bought_units" => units("bought"), "bought_value" => worth("bought"),
        "left_over_units" => units("left_over"), "left_over_value" => worth("left_over"),
    )
end

function solve_stock_group(job_dir::String, data, group::Group, settings; group_number::Int, group_count::Int)
    n_periods = data.n_periods
    ppy       = n_periods == 1 ? 1.0 : settings.periods_per_year
    records   = ItemRecord[data.items[k] for k in group.items]
    sheet_records = SheetRecord[data.sheets[k] for k in group.sheets if data.sheets[k].quantity > 0]

    out = Dict{String, Any}(
        "kind" => "stock", "label" => group.label,
        "key" => Dict("thickness" => group.thickness, "material" => group.material, "finish" => group.finish),
        "periods" => n_periods, "periods_per_year" => ppy,
    )
    period_demands = Int[records[k].demand[m] for k in eachindex(records), m in 1:n_periods]
    totals = vec(sum(period_demands; dims = 2))

    # One row for each item. `from_sheets` is the demand the sheets supply, and
    # `left_over` what is cut beyond demand and left in stock at the end.
    items_table(cut, bought, left_over, fits) = Dict{String, Any}[
        Dict{String, Any}("item_id" => r.item_id, "value" => r.value, "width" => r.width, "height" => r.height,
                          "can_rotate" => r.can_rotate, "demand_by_period" => r.demand, "demand" => totals[k],
                          "annual_demand" => annual_demand(r.demand, ppy),
                          "cut" => cut[k], "from_sheets" => totals[k] - bought[k], "bought" => bought[k],
                          "left_over" => left_over[k], "fits" => fits[k])
        for (k, r) in enumerate(records)
    ]

    if isempty(sheet_records)
        out["status"] = "no_sheets"
        out["message"] = "No sheets with stock in this group, so all demand is bought in."
        out["items"] = items_table(zeros(Int, length(records)), Float64.(totals), zeros(Float64, length(records)),
                                   fill(false, length(records)))
        out["summary"] = merge(item_totals(out["items"]),
                               Dict{String, Any}("sheets_in_stock" => 0, "sheets_used" => 0, "sheets_left" => 0))
        return out
    end

    sheets = [Sheet(k, r.quantity, r.width, r.height) for (k, r) in enumerate(sheet_records)]
    sheet_of = Dict{Int, SheetRecord}(k => r for (k, r) in enumerate(sheet_records))
    instance = Instance(solver_items(records, ppy), sheets)
    fits = placeable_item_positions(instance, settings.clearance)
    out["sheets"] = [Dict{String, Any}("sheet_id" => r.sheet_id, "width" => r.width, "height" => r.height,
                                        "quantity" => r.quantity) for r in sheet_records]

    initial_patterns = Pattern[]
    if settings.pool_preseed
        report_stage(job_dir, "Group $group_number of $group_count ($(group.label)): seeding the pattern pool with dichotomic patterns";
                     group = group_number, groups = group_count)
        initial_patterns = dichotomic_pattern_generation(instance; clearance_keywords(settings.clearance)...)
        out["seed_patterns"] = length(initial_patterns)
    end

    report_stage(job_dir, "Group $group_number of $group_count ($(group.label)): column generation and integer programme";
                 group = group_number, groups = group_count)
    stats = Dict{String, Any}()
    started = time()
    result = solve_col_gen_multi_period(
        instance, period_demands;
        periods_per_year = ppy,
        initial_patterns = initial_patterns,
        item_holding_rate = settings.item_holding_rate,
        clearance_keywords(settings.clearance)...,
        max_iterations = settings.max_iterations,
        time_limit = settings.col_gen_time_limit,
        ip_time_limit = settings.ip_time_limit,
        stats = stats,
    )
    seconds = time() - started
    plan = result.solution
    out["solver"] = Dict{String, Any}(
        "seconds" => seconds, "iterations" => result.iterations, "patterns_generated" => length(result.patterns),
        "stop_reason" => String(result.stop_reason), "lp_value" => result.lp_value, "lp_bound" => result.lp_bound,
        "ip_value" => result.ip_value, "ip_gap" => result.ip_gap, "ip_status" => result.ip_status,
        "final_step" => String(result.final_step),
    )
    if plan === nothing
        out["status"] = "no_plan"
        out["message"] = "The integer programme did not finish with a plan. Try a longer time limit."
        return out
    end

    # What each period cuts, and the plan's totals per item
    quantities = Dict{Int, Vector{Int}}()
    for m in 1:n_periods, chosen in plan.solutions[m].selected
        get!(quantities, chosen.pattern_id, zeros(Int, n_periods))[m] += chosen.quantity
    end
    n_items = length(records)
    cut      = [sum(plan.solutions[m].items_produced[k] for m in 1:n_periods) for k in 1:n_items]
    bought   = [sum(plan.bought[k, :]) for k in 1:n_items]
    left_over = [plan.inventory[k, n_periods] for k in 1:n_items]
    out["items"] = items_table(cut, bought, left_over, [k in fits for k in 1:n_items])
    out["periods_cut"] = [Dict{String, Any}("demand_units" => sum(period_demands[:, m]),
                                            "sheets_used" => sum((c.quantity for c in plan.solutions[m].selected); init = 0),
                                            "bought_units" => sum(plan.bought[:, m]),
                                            "in_stock_units" => sum(plan.inventory[:, m]),
                                            "waste_fraction" => plan.waste_by_period[m].waste_fraction) for m in 1:n_periods]

    sheets_cut_of = Dict{Int, Int}()
    for (pattern_id, by_period) in quantities
        sheet_id = result.patterns[findfirst(p -> p.pattern_id == pattern_id, result.patterns)].sheet_id
        sheets_cut_of[sheet_id] = get(sheets_cut_of, sheet_id, 0) + sum(by_period)
    end
    for entry in out["sheets"]
        k = findfirst(r -> r.sheet_id == entry["sheet_id"], sheet_records)
        entry["used"]   = get(sheets_cut_of, k, 0)
        entry["usable"] = haskey(result.sheet_costs, k)      # false if no item fits on it
    end

    sheets_used = sum(e["used"] for e in out["sheets"]; init = 0)
    sheets_in_stock = sum(r.quantity for r in sheet_records)
    out["status"] = "ok"
    out["summary"] = merge(item_totals(out["items"]), Dict{String, Any}(
        "sheets_in_stock" => sheets_in_stock, "sheets_used" => sheets_used, "sheets_left" => sheets_in_stock - sheets_used,
        "waste_fraction" => plan.waste.waste_fraction, "waste_area" => plan.waste.waste_area,
        "used_sheet_area" => plan.waste.cut_sheet_area,
    ))
    out["patterns"] = describe_patterns(result.patterns, quantities, instance, records, sheet_of, settings.clearance)

    if settings.min_month
        report_stage(job_dir, "Group $group_number of $group_count ($(group.label)): months of cover";
                     group = group_number, groups = group_count)
        cover = solve_ip_min_month(instance, result.patterns)
        if cover === nothing
            out["min_month"] = Dict{String, Any}("status" => "no_plan")
        else
            cover_quantities = Dict{Int, Vector{Int}}(c.pattern_id => [c.quantity] for c in cover.selected)
            out["min_month"] = Dict{String, Any}(
                "status" => "ok", "solves" => cover.n_solves,
                "runways" => Dict{String, Any}(records[k].item_id => cover.runways[k] for k in 1:n_items),
                "sheets_cut" => cover.sheets_cut, "sheets_available" => cover.sheets_available,
                "waste_fraction" => cover.waste.waste_fraction, "produced_value" => cover.produced_value,
                "patterns" => describe_patterns(result.patterns, cover_quantities, instance, records, sheet_of, settings.clearance),
            )
        end
    end
    return out
end

# --- A roll ---

function solve_roll_group(job_dir::String, data, group::Group, settings; group_number::Int, group_count::Int)
    n_periods = data.n_periods
    ppy       = n_periods == 1 ? 1.0 : settings.periods_per_year
    all_records = ItemRecord[data.items[k] for k in group.items]
    out = Dict{String, Any}(
        "kind" => "roll", "label" => group.label,
        "key" => Dict("thickness" => group.thickness, "material" => group.material, "finish" => group.finish),
    )

    width = get(settings.roll_widths, group.label, nothing)
    if width === nothing || width <= 0
        out["status"] = "error"
        out["message"] = "No roll width was given for this group."
        return out
    end
    out["roll_width"] = width
    out["shelf_height_limit"] = settings.roll_shelf_height
    roll_clearance = settings.roll_clearance
    out["clearance"] = Dict{String, Any}(string(k) => v for (k, v) in pairs(roll_clearance))

    # Items that cannot be placed on the roll are left out, and listed
    roll_sheet = Sheet(1, 1, width, settings.roll_shelf_height)
    everything = Instance(solver_items(all_records, ppy), [roll_sheet])
    placeable  = placeable_item_positions(everything, roll_clearance)
    records    = ItemRecord[r for (k, r) in enumerate(all_records) if k in placeable]
    out["left_out"] = [r.item_id for (k, r) in enumerate(all_records) if !(k in placeable)]
    if isempty(records)
        out["status"] = "error"
        out["message"] = "No item can be placed on a roll of this width."
        return out
    end

    instance = Instance(solver_items(records, ppy), [roll_sheet])
    report_stage(job_dir, "Group $group_number of $group_count ($(group.label)): infinite sheet column generation";
                 group = group_number, groups = group_count)
    started = time()
    result = solve_col_gen_infinite_sheet(
        instance;
        clearance_keywords(roll_clearance)...,
        max_iterations = settings.max_iterations,
        time_limit = settings.col_gen_time_limit,
        ip_time_limit = settings.ip_time_limit,
    )
    out["solver"] = Dict{String, Any}(
        "seconds" => time() - started, "iterations" => result.iterations, "stop_reason" => String(result.stop_reason),
        "patterns_generated" => length(result.patterns), "lp_value" => result.lp_value, "lp_bound" => result.lp_bound, "ip_gap" => result.ip_gap,
        "ip_status" => result.ip_status, "final_step" => String(result.final_step),
    )
    if result.solution === nothing
        out["status"] = "no_plan"
        out["message"] = "The integer programme did not finish with a plan. Try a longer time limit."
        return out
    end

    quantities = Dict{Int, Vector{Int}}(c.pattern_id => [c.quantity] for c in result.solution.selected)
    shelves = describe_patterns(result.patterns, quantities, instance, records, Dict{Int, SheetRecord}(), roll_clearance;
                                roll = true, shelf_heights = result.shelf_heights)
    n_items = length(records)
    cut = [sum(c.quantity * result.patterns[c.pattern_id].item_counts[k] for c in result.solution.selected; init = 0)
           for k in 1:n_items]
    out["status"] = "ok"
    out["roll_length"] = result.cost
    out["shelves_cut"] = result.shelves_cut
    out["waste"] = result.waste
    out["items"] = [Dict{String, Any}("item_id" => r.item_id, "value" => r.value, "width" => r.width, "height" => r.height,
                                      "can_rotate" => r.can_rotate, "demand" => instance.items[k].demand, "cut" => cut[k],
                                      "left_over" => max(0, cut[k] - instance.items[k].demand))
                    for (k, r) in enumerate(records)]
    out["shelves"] = shelves
    return out
end

# --- The job ---

function run_job(job_dir::String)
    input    = JSON.parsefile(joinpath(job_dir, "input.json"))
    settings = read_settings(get(input, "settings", Dict{String, Any}()))
    data = check_tables(get(input, "items", []), get(input, "sheets", []))
    isempty(data.problems) || error("the data has errors: " * join((p.message for p in first(data.problems, 3)), "; "))

    chosen(group) = settings.groups === nothing || group.label in settings.groups
    stock_groups = settings.stock ? [g for g in data.groups if chosen(g) && !isempty(g.items)] : Group[]
    roll_groups  = settings.infinite ? [g for g in data.groups if chosen(g) && !isempty(g.items)] : Group[]
    total = length(stock_groups) + length(roll_groups)
    total > 0 || error("no group is chosen to run")

    result = Dict{String, Any}(
        "state" => "running", "created" => time(), "n_periods" => data.n_periods,
        "settings" => json_safe(input["settings"]), "stock" => Dict{String, Any}[], "roll" => Dict{String, Any}[],
        "warnings" => [Dict("table" => w.table, "row" => w.row, "message" => w.message) for w in data.warnings],
    )
    number = 0
    for (kind, groups, solve) in (("stock", stock_groups, solve_stock_group), ("roll", roll_groups, solve_roll_group))
        for group in groups
            number += 1
            report_stage(job_dir, "Group $number of $total ($(group.label))"; group = number, groups = total)
            outcome = try
                solve(job_dir, data, group, settings; group_number = number, group_count = total)
            catch err
                println(sprint(showerror, err, catch_backtrace()))
                Dict{String, Any}("kind" => kind, "label" => group.label, "status" => "error",
                                  "message" => sprint(showerror, err))
            end
            push!(result[kind], outcome)
            write_json_file(joinpath(job_dir, "result.json"), result)
        end
    end
    result["state"] = "done"
    write_json_file(joinpath(job_dir, "result.json"), result)
    report_stage(job_dir, "Finished"; state = "done")
end

function main(args::Vector{String})
    length(args) == 1 || error("usage: julia --project app/job_runner.jl JOB_DIR")
    job_dir = abspath(args[1])

    # Errors go down the same pipe as the output, so the server's log has both
    redirect_stderr(stdout)

    try
        run_job(job_dir)
    catch err
        println(sprint(showerror, err, catch_backtrace()))
        report_stage(job_dir, "Stopped by an error"; state = "error", error_message = sprint(showerror, err))
        exit(1)
    end
end

isfile(PROGRAM_FILE) && samefile(PROGRAM_FILE, @__FILE__) && main(ARGS)
