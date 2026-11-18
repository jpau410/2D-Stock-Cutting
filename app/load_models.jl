# load_models.jl: loads the solver files in dependency order. Include this once
# in a process that runs the models (the job runner, the tests); the web server
# does not load them.

const SOLVER_DIR = joinpath(@__DIR__, "..", "solver")

for relative_path in [
    ["src", "constants.jl"],
    ["helper", "structs.jl"],
    ["helper", "build_pattern.jl"],
    ["helper", "grid_scale.jl"],
    ["helper", "item_fitting.jl"],
    ["helper", "lexmax.jl"],
    ["helper", "wastage.jl"],
    ["helper", "reporting.jl"],
    ["helper", "pattern_pool.jl"],
    ["helper", "solve_stats.jl"],
    ["helper", "ip_model.jl"],
    ["helper", "stock_valuation.jl"],
    ["helper", "col_gen.jl"],
    ["src", "Pattern_Generation", "revised_three-staged_dp.jl"],
    ["src", "Pattern_Generation", "fullpack_heuristic.jl"],
    ["src", "Pattern_Diversification", "dichotomic.jl"],
    ["src", "Pattern_Selection", "multi_period_ip.jl"],
    ["src", "Pattern_Selection", "multi_period_col_gen.jl"],
    ["src", "Pattern_Selection", "min_month_ip.jl"],
    ["src", "Pattern_Selection", "infinite_sheet_col_gen.jl"],
]
    include(joinpath(SOLVER_DIR, relative_path...))
end
