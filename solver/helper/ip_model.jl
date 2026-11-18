using JuMP
using HiGHS

# The model every selection IP starts from, so all of them are set up and solved
# the same way.
#
# Requires: MIP_REL_GAP, MIP_ABS_GAP (src/constants.jl)

"""
    new_selection_model() -> Model

An empty HiGHS model for a selection IP: silent, and solved until its gap is
within `MIP_REL_GAP` of the cost or within `MIP_ABS_GAP` (src/constants.jl).
"""
function new_selection_model()
    model = Model(HiGHS.Optimizer)
    set_silent(model)
    set_optimizer_attribute(model, "mip_rel_gap", MIP_REL_GAP)
    set_optimizer_attribute(model, "mip_abs_gap", MIP_ABS_GAP)
    return model
end
