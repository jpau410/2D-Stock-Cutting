# run_tests.jl: tests on small toy instances. Run from the application folder:
#   julia --project test/run_tests.jl
#
# They cover the reading and checking of the tables, the placement of items
# against the clearance rules, the three ways of valuing the sheets (on an
# instance small enough to work out by hand), and a whole run of the job runner.
#
# Requires: app/load_models.jl, app/data_input.jl, app/settings.jl, app/layout.jl

using Test, Random, JSON

include(joinpath(@__DIR__, "..", "app", "load_models.jl"))
include(joinpath(@__DIR__, "..", "app", "data_input.jl"))
include(joinpath(@__DIR__, "..", "app", "settings.jl"))
include(joinpath(@__DIR__, "..", "app", "layout.jl"))

# --- Reading and checking the tables ---

@testset "tables" begin
    text = "﻿Item ID;Value;Width (mm);Height;Thickness;Material;Finish;Rotate;Demand_Period_1\r\n" *
           "A;2,5;100;50;1.50;Steel;Brushed;Y;10\r\n"
    @test_throws ErrorException table_from_csv("items", "item_id,value\nA,1\n")

    items_csv = "item_id,value,width,height,thickness,material,finish,can_rotate,demand_period_1,demand_period_2\n" *
                "A,12.5,300,200,1.50,Steel,Brushed,Y,40,\n" *
                "B,6,150,\"400\",1.5,steel,brushed,no,25,5\n" *
                "C,3,100,100,2,Alu,,yes,60,\n"
    items = table_from_csv("items", items_csv)
    @test items.columns[end] == "demand_period_2"
    @test items.rows[1]["thickness"] == "1.50"

    sheets_csv = "sheet_id,width,height,thickness,material,finish,quantity\nS1,2500,1250,1.5,Steel,Brushed,10\nS2,2000,1000,3,Steel,,4\n"
    sheets = table_from_csv("sheets", sheets_csv)

    checked = check_tables(items.rows, sheets.rows)
    @test isempty(checked.problems)
    @test checked.n_periods == 2
    @test [g.label for g in checked.groups] == ["Alu / 2 mm", "Steel / 3 mm", "Steel / Brushed / 1.5 mm"]
    steel = checked.groups[3]
    @test length(steel.items) == 2 && length(steel.sheets) == 1       # "steel" and "Steel" are one material
    @test checked.items[1].can_rotate && !checked.items[2].can_rotate
    @test checked.items[2].demand == [25, 5]
    @test length(checked.warnings) == 2                              # Alu has no sheets, "Steel / 3 mm" has no items

    # A year given as period 1 only is one period
    yearly = check_tables(table_from_csv("items", "item_id,value,width,height,can_rotate,demand_period_1\nA,1,10,10,yes,5\n").rows,
                          table_from_csv("sheets", "sheet_id,width,height,quantity\nS,100,100,1\n").rows)
    @test yearly.n_periods == 1 && length(yearly.groups) == 1 && yearly.groups[1].label == "All items and sheets"

    broken = check_tables([Dict("item_id" => "A", "value" => "x", "width" => "0", "height" => "5", "can_rotate" => "maybe",
                                "demand_period_1" => "1.5"),
                           Dict("item_id" => "a", "value" => "1", "width" => "5", "height" => "5", "can_rotate" => "yes",
                                "demand_period_1" => "1")], [])
    messages = [p.message for p in broken.problems]
    @test any(contains(m, "value must be a number") for m in messages)
    @test any(contains(m, "width must be above 0") for m in messages)
    @test any(contains(m, "can_rotate must be yes or no") for m in messages)
    @test any(contains(m, "whole number") for m in messages)
end

@testset "settings" begin
    defaults = read_settings(default_settings())
    @test defaults.col_gen_time_limit == Inf
    @test defaults.item_holding_rate == DEFAULT_ANNUAL_HOLDING_RATE
    @test_throws ErrorException read_settings(Dict("item_holding_rate" => -0.1))
    @test_throws ErrorException read_settings(Dict("modes" => Dict("stock" => false, "infinite" => false)))
    # The roll takes its own clearance, which is all or nothing
    roll(values) = Dict("modes" => Dict("stock" => false, "infinite" => true), "roll" => values)
    @test read_settings(roll(Dict("gap" => 5, "left" => 10, "right" => 3, "top" => 7, "bottom" => 1))).roll_clearance ==
          (gap = 5.0, left = 10.0, right = 3.0, top = 7.0, bottom = 1.0)
    @test read_settings(roll(Dict("gap" => 0, "left" => 0, "right" => 0, "top" => 0, "bottom" => 0))).roll_clearance.gap == 0
    @test_throws ErrorException read_settings(roll(Dict("gap" => 5, "left" => 0)))        # a free edge with a gap
    @test_throws ErrorException read_settings(roll(Dict("gap" => 0)))                      # margins with no gap
    @test read_settings(Dict("roll" => Dict("gap" => 5, "left" => 0))).stock             # unused when no roll is run
    @test_throws ErrorException read_settings(Dict("modes" => Dict("stock" => false, "infinite" => true, "min_month" => true)))
end

# --- Placing items ---

@testset "placement follows the clearance rules" begin
    rng = MersenneTwister(1)
    rules = [
        (0.0, 0.0, 0.0, 0.0, 0.0), (5.0, 5.0, 5.0, 5.0, 5.0), (5.0, 0.0, 0.0, 0.0, 0.0), (5.0, 10.0, 0.0, 0.0, 0.0),
        (5.0, 0.0, 10.0, 0.0, 10.0), (3.5, 0.0, 0.0, 5.0, 5.0), (5.0, 0.0, 5.0, 10.0, 0.0),
    ]
    checked = 0
    for trial in 1:20, (gap, left, right, top, bottom) in rules
        items = [Item(k, "I$k", 10, round(rand(rng, 1:20) * 1.0), 10.0 * rand(rng, 5:40), 10.0 * rand(rng, 5:40)) for k in 1:5]
        instance = Instance(expand_with_rotations(items), [Sheet(1, 5, 1000.0, 800.0), Sheet(2, 5, 640.0, 410.0)])
        for sheet in instance.sheets
            pattern = generate_pattern_dp_revised_three_staged(instance, sheet.sheet_id; clearance = gap,
                clearance_left = left, clearance_right = right, clearance_top = top, clearance_bottom = bottom)
            pattern === nothing && continue
            layout = layout_pattern(pattern, instance, sheet; clearance = gap, clearance_left = left,
                clearance_right = right, clearance_top = top, clearance_bottom = bottom)
            isempty(layout.problems) || @info "layout problem" trial gap left right top bottom layout.problems
            @test isempty(layout.problems)
            checked += 1
        end
    end
    @test checked > 100
end

# --- Buying in is the last resort ---

# One item, 100 by 100 with value 2, and three sheet sizes: S1 (500 by 200, three in stock)
# holds 10 items, so its best packing is worth 20; S2 (1000 by 200, three in stock) holds 20,
# worth 40; S3 (90 by 90, five in stock) holds none, so it has no pattern and is never cut.
# Every total is worked out by hand.
@testset "buy in last, then the cheapest sheets" begin
    instance = Instance([Item(1, "A", 10, 2.0, 100.0, 100.0)],
                        [Sheet(1, 3, 500.0, 200.0), Sheet(2, 3, 1000.0, 200.0), Sheet(3, 5, 90.0, 90.0)])
    found = [generate_pattern_dp_revised_three_staged(instance, id) for id in 1:3]
    @test found[3] === nothing
    pool = [Pattern(k, p.sheet_id, p.value, p.shelves, p.item_counts) for (k, p) in enumerate(found[1:2])]
    @test [p.value for p in pool] == [20.0, 40.0]

    # The best packing of each sheet type is a constant, found once from the DP
    sheet_costs = Dict(p.sheet_id => p.value for p in pool)
    @test sheet_costs == Dict(1 => 20.0, 2 => 40.0)

    quiet(f) = redirect_stdout(f, devnull)
    ip(demand) = quiet() do
        solve_ip_multi_period(instance, pool, reshape([demand], 1, 1); periods_per_year = 1,
                              sheet_costs = sheet_costs, item_holding_rate = 0.15)
    end

    # The costs given must cover every sheet that can be cut, and be at least the value of its patterns
    @test_throws ErrorException solve_ip_multi_period(instance, pool, reshape([10], 1, 1); periods_per_year = 1,
                                                                    sheet_costs = Dict(1 => 20.0))
    @test_throws ErrorException solve_ip_multi_period(instance, pool, reshape([10], 1, 1); periods_per_year = 1,
                                                      sheet_costs = Dict(1 => 20.0, 2 => 30.0))
    sheets_used(plan) = Dict(pool[c.pattern_id].sheet_id => c.quantity for c in plan.solutions[1].selected)

    # The weight: 180 is the value of every sheet in the pool, held for a year at 15%,
    # over the lowest item value of 2
    @test buy_in_weight(instance.sheets[1:2], Dict(1 => 20.0, 2 => 40.0), instance.items, 0.15, 1, 1) == floor(180 * 1.15 / 2) + 1

    # Enough sheets: nothing is bought in, and the cheapest sheet that meets the demand is cut
    plan = ip(10)
    @test plan.bought[1, 1] == 0
    @test sheets_used(plan) == Dict(1 => 1)
    @test plan.costs.sheet_opportunity_cost == 20 && plan.costs.total == 20

    # Even a demand that takes nearly every sheet is met from the sheets: five sheets hold at
    # most 3 * 20 + 2 * 10 = 80 items, so 85 needs all six
    plan = ip(85)
    @test plan.bought[1, 1] == 0
    @test plan.sheets_cut == 6

    # Too few sheets (the pool holds 30 + 60 = 90 items): every sheet is cut, and the rest is bought in
    plan = ip(100)
    @test sheets_used(plan) == Dict(1 => 3, 2 => 3)
    @test plan.bought[1, 1] == 10
    @test plan.costs.buy_cost == 20                       # at the item value, without the weight
    @test plan.costs.sheet_opportunity_cost == 3 * 20 + 3 * 40
    @test plan.costs.total == 20 + 180
    @test plan.buy_weight > 1

    # One unit short is bought, not covered by cutting less
    plan = ip(91)
    @test plan.bought[1, 1] == 1 && plan.sheets_cut == 6

    # Column generation reaches the same plans from no patterns at all, and finds the same
    # sheet costs, whatever it starts from
    for (demand, bought, cut) in ((10, 0, 1), (100, 10, 6))
        found = quiet() do
            solve_col_gen_multi_period(instance, reshape([demand], 1, 1); periods_per_year = 1)
        end
        @test found.solution.bought[1, 1] == bought
        @test found.solution.sheets_cut == cut
        @test found.sheet_costs == sheet_costs
    end
    seeded = quiet() do
        solve_col_gen_multi_period(instance, reshape([10], 1, 1); periods_per_year = 1,
                                   initial_patterns = [Pattern(1, 1, 10.0, pool[1].shelves, [5])])
    end
    @test seeded.sheet_costs == sheet_costs

    # With several periods the demand of each is still met from the sheets first
    plan = quiet() do
        solve_ip_multi_period(instance, pool, [10 10]; periods_per_year = 2, sheet_costs = sheet_costs,
                              item_holding_rate = 0.15)
    end
    @test all(plan.bought .== 0)
    @test plan.sheets_cut == 2
end

# Items in stock cost one period's share of the yearly rate for each period they are in stock
# at the end of, and what is left at the end of the horizon is charged one more period. The
# item is worth 2 and the rate is 15% a year; one S1 sheet holds 10 items and costs 20.
@testset "holding cost of items" begin
    instance = Instance([Item(1, "A", 10, 2.0, 100.0, 100.0)], [Sheet(1, 3, 500.0, 200.0)])
    pool = [generate_pattern_dp_revised_three_staged(instance, 1)]
    holding(demand, per_year) = redirect_stdout(devnull) do
        solve_ip_multi_period(instance, pool, demand; periods_per_year = per_year, sheet_costs = Dict(1 => pool[1].value),
                              item_holding_rate = 0.15)
    end

    # One period that is a year: 5 items left at the end are held an extra period, a year
    plan = holding(reshape([5], 1, 1), 1)
    @test plan.costs.item_holding ≈ 0.15 * 2 * 5
    @test plan.costs.total ≈ 20 + 1.5

    # Two periods, two a year: 10 cut in the first leaves 5, held to the end of it (0.075 * 2 * 5),
    # and then used in the second
    plan = holding([5 5], 2)
    @test plan.sheets_cut == 1
    @test plan.costs.item_holding ≈ 0.075 * 2 * 5

    # 7 left after the first period and 4 after the second: 11 item-periods, not a year for the last 4
    plan = holding([3 3], 2)
    @test plan.sheets_cut == 1
    @test plan.costs.item_holding ≈ 0.075 * 2 * (7 + 4)
end

# --- The infinite sheet with different margins ---

# 20 items, each 100 by 100, on a roll 1000 wide whose tallest shelf is 500, with a gap of 5 and
# margins of 10 (left), 30 (right), 20 (top) and 40 (bottom). A shelf is 1000 - 40 = 960 wide, so
# 9 stacks fit across (9 * 100 + 8 * 5 = 940), and at most 500 - 60 = 440 tall, so a stack holds up
# to 4 items (4 * 100 + 3 * 5 = 415). 20 items need 3 rows of 9, each row costing its height plus
# a gap (3 * 105 = 315), and one more gap closes the roll: 320 long. The top and bottom margins
# only limit how tall a shelf can be, so they are not in the length (or in the drawing of a shelf).
@testset "infinite sheet with different margins" begin
    items = expand_with_rotations([Item(1, "A", 20, 1.0, 100.0, 100.0)])
    roll_sheet = Sheet(1, 1, 1000.0, 500.0)
    roll = Instance(items, [roll_sheet])
    margins = (clearance = 5.0, clearance_left = 10.0, clearance_right = 30.0, clearance_top = 20.0, clearance_bottom = 40.0)

    found = redirect_stdout(devnull) do
        solve_col_gen_infinite_sheet(roll; margins...)
    end
    @test found.cost ≈ 320
    @test maximum(found.shelf_heights) <= 500 - 20 - 40

    # Each shelf is drawn as a sheet as wide as the roll and as tall as the shelf plus the gap above and
    # below, with the left and right margins at its sides, and every item meets them
    shown = merge(margins, (clearance_top = 5.0, clearance_bottom = 5.0))
    for (k, shelf) in enumerate(found.patterns)
        drawn = Sheet(1, 1, 1000.0, found.shelf_heights[k] + 2 * 5.0)
        layout = layout_pattern(shelf, roll, drawn; shown...)
        @test isempty(layout.problems)
        @test layout.width == 1000 && layout.height == found.shelf_heights[k] + 10
        @test all(item.x >= 10 && item.x + item.w <= 1000 - 30 for item in layout.items)
        @test all(item.y >= 5 && item.y + item.h <= layout.height - 5 for item in layout.items)
    end

    # An item too tall for a shelf once the margins are taken off (460 against 500 - 60 = 440)
    # cannot be placed, though it would fit the tallest shelf without them
    tall = expand_with_rotations([Item(1, "T", 1, 1.0, 100.0, 460.0)]; rotation_allowed = Dict(1 => false))
    @test isempty(items_fitting_sheet(tall, roll_sheet, 5.0, 10.0, 30.0, 20.0, 40.0))
    @test length(items_fitting_sheet(tall, roll_sheet, 5.0, 10.0, 30.0, 0.0, 0.0)) == 1
end

# --- A whole run ---

@testset "job runner" begin
    mktempdir() do dir
        items = [
            Dict("item_id" => "A", "value" => "12.5", "width" => "300", "height" => "200", "thickness" => "1.5", "material" => "Steel",
                 "finish" => "", "can_rotate" => "yes", "demand_period_1" => "40", "demand_period_2" => "20"),
            Dict("item_id" => "B", "value" => "6", "width" => "150", "height" => "400", "thickness" => "1.5", "material" => "Steel",
                 "finish" => "", "can_rotate" => "no", "demand_period_1" => "25", "demand_period_2" => "10"),
            Dict("item_id" => "C", "value" => "3", "width" => "100", "height" => "100", "thickness" => "1.5", "material" => "Steel",
                 "finish" => "", "can_rotate" => "yes", "demand_period_1" => "60", "demand_period_2" => "30"),
        ]
        sheets = [Dict("sheet_id" => "S1", "width" => "1200", "height" => "1000", "thickness" => "1.5", "material" => "Steel",
                       "finish" => "", "quantity" => "10"),
                  Dict("sheet_id" => "S2", "width" => "800", "height" => "800", "thickness" => "1.5", "material" => "Steel",
                       "finish" => "", "quantity" => "5")]
        settings = Dict("modes" => Dict("stock" => true, "min_month" => true, "infinite" => true), "pool_preseed" => true,
                        "periods_per_year" => 12, "limits" => Dict("ip_time_limit" => 60),
                        "roll" => Dict("widths" => Dict("Steel / 1.5 mm" => 1250)))
        write(joinpath(dir, "input.json"), JSON.json(Dict("items" => items, "sheets" => sheets, "settings" => settings)))

        runner = joinpath(@__DIR__, "..", "app", "job_runner.jl")
        project = normpath(joinpath(@__DIR__, ".."))
        @test success(pipeline(`$(Base.julia_cmd()) --project=$project $runner $dir`; stdout = devnull))

        result = JSON.parsefile(joinpath(dir, "result.json"))
        @test result["state"] == "done" && result["n_periods"] == 2
        stock = only(result["stock"])
        @test stock["status"] == "ok"
        @test stock["min_month"]["status"] == "ok"
        patterns = vcat(stock["patterns"], stock["min_month"]["patterns"])
        @test !isempty(patterns)
        @test all(isempty(p["layout"]["problems"]) for p in patterns)
        roll = only(result["roll"])
        @test roll["status"] == "ok" && roll["roll_length"] > 0
        @test all(isempty(p["layout"]["problems"]) for p in roll["shelves"])
        status = JSON.parsefile(joinpath(dir, "status.json"))
        @test status["state"] == "done"
    end
end
