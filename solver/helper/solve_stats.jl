using JuMP

# The statistics of a solved selection IP, for comparing runs such as the
# pattern pools of different diversification methods. Each selection function
# takes an optional `stats` Dict and fills it with record_solve_stats!, so all
# of them report the same keys.

"""
    record_solve_stats!(stats, model, n_patterns; solve_seconds = nothing,
                        nodes = nothing) -> Nothing

If `stats` is a Dict, fills it with the statistics of the solved `model`, which
was built over a pool of `n_patterns` patterns. Does nothing if `stats` is
`nothing`. The keys are
  - `"termination_status"` :: `String`, the solver's status
  - `"solve_seconds"`      :: `Float64`
  - `"n_patterns"`         :: `Int`
and, when the solver found a solution,
  - `"objective_value"`, `"objective_bound"`, `"relative_gap"` :: `Float64`
  - `"nodes"`              :: `Int`, the branch-and-bound node count

`solve_seconds` and `nodes` are read from the model's latest solve. A function
that solves more than once passes the totals over all its solves as
`solve_seconds` and `nodes` instead; everything else is the latest solve's.
"""
function record_solve_stats!(
    stats         :: Union{Nothing, Dict{String, Any}},
    model         :: Model,
    n_patterns    :: Int;
    solve_seconds :: Union{Nothing, Real}    = nothing,
    nodes         :: Union{Nothing, Integer} = nothing,
)
    stats === nothing && return nothing

    stats["termination_status"] = string(termination_status(model))
    stats["solve_seconds"]      = solve_seconds === nothing ? solve_time(model) : Float64(solve_seconds)
    stats["n_patterns"]         = n_patterns
    if has_values(model)
        stats["objective_value"] = objective_value(model)
        stats["objective_bound"] = objective_bound(model)
        stats["relative_gap"]    = relative_gap(model)
        stats["nodes"]           = nodes === nothing ? MOI.get(model, MOI.NodeCount()) : Int(nodes)
    end
    return nothing
end
