# Definitions for running a feasible combined gas and power flow with network expansion
export solve_ne
export solve_ne_popf

" entry point for running gas and electric power expansion planning only "
function solve_ne(gfile, pfile, gtype, ptype, optimizer; kwargs...)
    return solve_model(gfile, pfile, gtype, ptype, optimizer, post_ne;
        gext=[_GM.ref_add_ne!],
        pext=[_PM.ref_add_on_off_va_bounds!, _PM.ref_add_ne_branch!], kwargs...)
end

"Post all the constraints associated with expansion planning in electric power"
function post_tnep(pm::_PM.AbstractPowerModel)
    _PM.variable_ne_branch_indicator(pm) # variable z in the TPS paper
    _PM.variable_bus_voltage(pm)         # variable v in the TPS paper
    _PM.variable_ne_branch_voltage(pm)   # variable v in the TPS paper
    _PM.variable_gen_power(pm)           # variable p^g, q^g in the TPS paper
    _PM.variable_branch_power(pm)        # variable p,q in the TPS paper
    _PM.variable_dcline_power(pm)        # DC line flows.  Not used in TPS paper
    _PM.variable_ne_branch_power(pm)     # variable p,q in the TPS paper

    _PM.constraint_model_voltage(pm)    # adds upper and lower bounds on voltage and voltage squared, constraint 11 in TPS paper
    _PM.constraint_ne_model_voltage(pm) # adds upper and lower bounds on voltage and voltage squared, constraint 11 in TPS paper

    for i in _PM.ids(pm, :ref_buses)
        _PM.constraint_theta_ref(pm, i) # sets the reference bus phase angle to 0 (not explictly stated in TPS paper)
    end

    for i in _PM.ids(pm, :bus)
        _PM.constraint_ne_power_balance(pm, i) # Kirchoff's laws (constraints 1 and 2 in TPS paper)
    end

    for i in _PM.ids(pm, :branch)
        _PM.constraint_ohms_yt_from(pm, i)              # Ohms laws (constraints 3 and 5 in TPS paper)
        _PM.constraint_ohms_yt_to(pm, i)                # Ohms laws (constraints 4 and 6 in TPS paper)
        _PM.constraint_voltage_angle_difference(pm, i)  # limit on phase angle difference (not explictly stated in TPS paper)
        _PM.constraint_thermal_limit_from(pm, i)        # thermal limit on lines (constraint 7 in TPS paper)
        _PM.constraint_thermal_limit_to(pm, i)          # thermal limit on lines (constraint 8 in TPS paper)
    end

    for i in _PM.ids(pm, :ne_branch)
        _PM.constraint_ne_ohms_yt_from(pm, i)             # Ohms laws (constraints 3 and 5 in TPS paper)
        _PM.constraint_ne_ohms_yt_to(pm, i)               # Ohms laws (constraints 4 and 6 in TPS paper)
        _PM.constraint_ne_voltage_angle_difference(pm, i) # limit on phase angle difference (not explictly stated in TPS paper)
        _PM.constraint_ne_thermal_limit_from(pm, i)       # thermal limit on lines (constraint 7 in TPS paper)
        _PM.constraint_ne_thermal_limit_to(pm, i)         # thermal limit on lines (constraint 8 in TPS paper)
    end
end

"Post all the constraints and variables associated with expansion planning in gas networks"
function post_nels(gm::_GM.AbstractGasModel)
    _GM.variable_flow(gm) # variable x in the TPS paper
    _GM.variable_pressure_sqr(gm)  # variable \pi in the TPS paper
    _GM.variable_valve_operation(gm)
    _GM.variable_load_mass_flow(gm)  # variable d in the TPS paper
    _GM.variable_production_mass_flow(gm)  # variable s in the TPS paper

    # expansion variables
    _GM.variable_pipe_ne(gm)
    _GM.variable_compressor_ne(gm)

    _GM.variable_flow_ne(gm)  # variable x in the TPS paper

    for i in _GM.ids(gm, :pipe)
        _GM.constraint_pipe_pressure(gm, i)
        _GM.constraint_pipe_mass_flow(gm,i)
        _GM.constraint_pipe_weymouth(gm,i)
    end

    for i in _GM.ids(gm, :resistor)
        _GM.constraint_resistor_pressure(gm, i)
        _GM.constraint_resistor_mass_flow(gm,i)
        _GM.constraint_resistor_weymouth(gm,i)
    end

    for i in _GM.ids(gm, :junction)
        _GM.constraint_mass_flow_balance_ne(gm, i)
    end

    for i in _GM.ids(gm, :ne_pipe)
        _GM.constraint_pipe_pressure_ne(gm, i)
        _GM.constraint_pipe_ne(gm, i)
        _GM.constraint_pipe_mass_flow_ne(gm,i)
        _GM.constraint_pipe_weymouth_ne(gm, i)
    end

    for i in _GM.ids(gm, :short_pipe)
        _GM.constraint_short_pipe_pressure(gm, i)
        _GM.constraint_short_pipe_mass_flow(gm, i)
    end

    # We assume that we already have a short pipe connecting two nodes
    # and we just want to add a compressor to it. Use constraint
    # constraint_on_off_compressor_flow_expansion to disallow flow
    # if the compressor is not built
    for i in _GM.ids(gm, :compressor)
        _GM.constraint_compressor_ratios(gm, i)
        _GM.constraint_compressor_mass_flow(gm, i)
    end

    for i in _GM.ids(gm, :ne_compressor)
        _GM.constraint_compressor_ratios_ne(gm, i)
        _GM.constraint_compressor_ne(gm, i)
        _GM.constraint_compressor_mass_flow_ne(gm, i)
    end

    for i in _GM.ids(gm, :valve)
        _GM.constraint_on_off_valve_mass_flow(gm, i)
        _GM.constraint_on_off_valve_pressure(gm, i)
    end

    for i in _GM.ids(gm, :regulator)
        _GM.constraint_on_off_regulator_mass_flow(gm, i)
        _GM.constraint_on_off_regulator_pressure(gm, i)
    end
end

# construct the gas flow feasbility problem with demand being the cost model
function post_ne(pm::_PM.AbstractPowerModel, gm::_GM.AbstractGasModel; kwargs...)
    kwargs = Dict(kwargs)
    gas_ne_weight = haskey(kwargs, :gas_ne_weight) ? kwargs[:gas_ne_weight] : 1.0
    power_ne_weight = haskey(kwargs, :power_ne_weight) ? kwargs[:power_ne_weight] : 1.0
    obj_normalization = haskey(kwargs, :obj_normalization) ? kwargs[:obj_normalization] : 1.0

    # Power-only-related variables and constraints.
    post_tnep(pm)

    # Gas-only-related variables and constraints.
    post_nels(gm)

    # Gas-Power related parts of the problem formulation.
    for i in _GM.ids(gm, :delivery)
       constraint_heat_rate_curve(pm, gm, i)
    end

    # Objective function minimizes demand and pressure cost.
    objective_min_ne_cost(pm, gm; gas_ne_weight=gas_ne_weight, power_ne_weight=power_ne_weight, normalization= obj_normalization)
end

function get_ne_solution(pm::_PM.AbstractPowerModel, gm::_GM.AbstractGasModel)
    sol = Dict{AbstractString,Any}()
    _PM.add_setpoint_bus_voltage!(sol, pm)
    _PM.add_setpoint_generator_power!(sol, pm)
    _PM.add_setpoint_branch_flow!(sol, pm)
    _GM.add_junction_pressure_setpoint(sol, gm)
    _GM.add_connection_ne(sol, gm)
    _GM.add_load_mass_flow_setpoint(sol, gm)
    _GM.add_production_mass_flow_setpoint(sol, gm)
    _GM.add_load_volume_setpoint(sol, gm)
    _GM.add_production_volume_setpoint(sol, gm)
    _GM.add_direction_setpoint(sol, gm)
    _GM.add_direction_ne_setpoint(sol,gm)
    _GM.add_valve_setpoint(sol, gm)
    _PM.add_setpoint_branch_ne_flow!(sol, pm)
    _PM.add_setpoint_branch_ne_built!(sol, pm)
    return sol
end
