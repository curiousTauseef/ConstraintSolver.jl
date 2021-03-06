include("all_different/bipartite.jl")

function init_constraint_struct(::Type{AllDifferentSetInternal}, internals)
    AllDifferentConstraint(
        internals,
        Int[], # pval_mapping will be filled later
        Int[], # vertex_mapping => later
        Int[], # vertex_mapping_bw => later
        Int[], # di_ei => later
        Int[], # di_ej => later
        MatchingInit(),
        Int[]
    )
end

"""
    init_constraint!(com::CS.CoM, constraint::AllDifferentConstraint, fct::MOI.VectorOfVariables, set::AllDifferentSetInternal;
                     active = true)

Initialize the AllDifferentConstraint by filling matching_init
"""
function init_constraint!(
    com::CS.CoM,
    constraint::AllDifferentConstraint,
    fct::MOI.VectorOfVariables,
    set::AllDifferentSetInternal;
    active = true
)
    pvals = constraint.pvals
    nindices = length(constraint.indices)

    min_pvals, max_pvals = extrema(pvals)
    len_range = max_pvals - min_pvals + 1

    num_edges = length(pvals) * nindices

    constraint.pval_mapping = zeros(Int, length(pvals))
    constraint.vertex_mapping = zeros(Int, len_range)
    constraint.vertex_mapping_bw = zeros(Int, nindices + length(pvals))
    constraint.di_ei = zeros(Int, num_edges)
    constraint.di_ej = zeros(Int, num_edges)

    # fill matching_init
    m = nindices
    n = len_range
    constraint.matching_init = MatchingInit(
        0,
        zeros(Int, m),
        zeros(Int, n),
        zeros(Int, m + 1),
        zeros(Int, m + n),
        zeros(Int, m + n),
        zeros(Int, m + n),
        zeros(Bool, m),
        zeros(Bool, n),
    )

    # check if lp model exists and then add an equality constraint for better bound computation
    com.lp_model === nothing && return true # return feasibility

    lp_backend = backend(com.lp_model)
    lp_vidx = create_lp_variable!(com.lp_model, com.lp_x)
    # create == constraint with sum of all variables equal the newly created variable
    sats = [MOI.ScalarAffineTerm(1.0, MOI.VariableIndex(vidx)) for vidx in constraint.indices]
    push!(sats, MOI.ScalarAffineTerm(-1.0, MOI.VariableIndex(lp_vidx)))
    saf = MOI.ScalarAffineFunction(sats, 0.0)
    MOI.add_constraint(lp_backend, saf, MOI.EqualTo(0.0))
    
    constraint.bound_rhs = [BoundRhsVariable(lp_vidx, typemin(Int), typemax(Int))]

    # if constraints are part of the all different constraint
    # the all different constraint can be split more parts to get better bounds
    # i.e https://github.com/Wikunia/ConstraintSolver.jl/issues/114
    for sc_idx in constraint.sub_constraint_idxs
        lp_vidx = create_lp_variable!(com.lp_model, com.lp_x)
        # create == constraint with sum of all variables equal the newly created variable
        sats = [MOI.ScalarAffineTerm(1.0, MOI.VariableIndex(vidx)) for vidx in com.constraints[sc_idx].indices]
        push!(sats, MOI.ScalarAffineTerm(-1.0, MOI.VariableIndex(lp_vidx)))
        saf = MOI.ScalarAffineFunction(sats, 0.0)
        MOI.add_constraint(lp_backend, saf, MOI.EqualTo(0.0))
        push!(constraint.bound_rhs, BoundRhsVariable(lp_vidx, typemin(Int), typemax(Int)))
    end
    return true # still feasible
end

"""
    get_alldifferent_extrema(sorted_min, sorted_max, len)

`sorted_max` should be desc and `sorted_min` asc
Return the minimum and maximum sum using `len` values of sorted_min/sorted_max while satisfying the all different constraint
"""
function get_alldifferent_extrema(sorted_min, sorted_max, len)
    max_sum = sorted_max[1]
    last_val = max_sum
    for i=2:len
        if sorted_max[i] >= last_val
            last_val -= 1 
        else 
            last_val = sorted_max[i]
        end
        max_sum += last_val
    end

    min_sum = sorted_min[1]
    last_val = min_sum
    for i=2:len
        if sorted_min[i] <= last_val
            last_val += 1 
        else 
            last_val = sorted_min[i]
        end
        min_sum += last_val
    end

    return min_sum, max_sum
end

"""
    update_best_bound_constraint!(com::CS.CoM,
        constraint::AllDifferentConstraint,
        fct::MOI.VectorOfVariables,
        set::AllDifferentSetInternal,
        vidx::Int,
        lb::Int,
        ub::Int
    )

Update the bound constraint associated with this constraint. This means that the `bound_rhs` bounds will be changed according to 
the possible values the all different constraint allows. 
i.e if we have 4 variables all between 1 and 10 the maximum sum is 10+9+8+7 and the minimum sum is 1+2+3+4
Additionally one of the variables can be bounded using `vidx`, `lb` and `ub`
"""
function update_best_bound_constraint!(com::CS.CoM,
    constraint::AllDifferentConstraint,
    fct::MOI.VectorOfVariables,
    set::AllDifferentSetInternal,
    vidx::Int,
    lb::Int,
    ub::Int
)
    constraint.bound_rhs === nothing && return
    search_space = com.search_space

    # compute bounds
    # get the maximum/minimum value for each variable
    max_vals = zeros(Int, length(constraint.indices))
    min_vals = zeros(Int, length(constraint.indices))
    for i=1:length(constraint.indices)
        v_idx = constraint.indices[i]
        if v_idx == vidx
            max_vals[i] = ub
            min_vals[i] = lb
        else
            min_vals[i] = search_space[v_idx].min
            max_vals[i] = search_space[v_idx].max
        end
    end
    
    # sort the max_vals desc and obtain bound by enforcing all different
    sort!(max_vals; rev=true)
    # sort the min_vals asc and obtain bound by enforcing all different
    sort!(min_vals)
  
    min_sum, max_sum = get_alldifferent_extrema(min_vals, max_vals, length(constraint.indices))

    constraint.bound_rhs[1].lb = min_sum
    constraint.bound_rhs[1].ub = max_sum

    i = 1
    for sc_idx in constraint.sub_constraint_idxs
        i += 1
        sub_constraint = com.constraints[sc_idx]
        min_sum, max_sum = get_alldifferent_extrema(min_vals, max_vals, length(sub_constraint.indices))
        constraint.bound_rhs[i].lb = min_sum
        constraint.bound_rhs[i].ub = max_sum
    end
end

"""
    prune_constraint!(com::CS.CoM, constraint::AllDifferentConstraint, fct::MOI.VectorOfVariables, set::AllDifferentSetInternal; logs = true)

Reduce the number of possibilities given the `AllDifferentConstraint`.
Return whether still feasible and throws a warning if infeasible and `logs` is set to `true`
"""
function prune_constraint!(
    com::CS.CoM,
    constraint::AllDifferentConstraint,
    fct::MOI.VectorOfVariables,
    set::AllDifferentSetInternal;
    logs = true,
)
    indices = constraint.indices
    pvals = constraint.pvals
    nindices = length(indices)

    search_space = com.search_space
    fixed_vals, unfixed_indices = fixed_vs_unfixed(search_space, indices)

    fixed_vals_set = Set(fixed_vals)
    # check if one value is used more than once
    if length(fixed_vals_set) < length(fixed_vals)
        logs && @warn "The problem is infeasible"
        return false
    end

    bfixed = true
    current_fixed_vals = fixed_vals

    while bfixed
        new_fixed_vals = Int[]
        bfixed = false
        for i = 1:length(unfixed_indices)
            pi = unfixed_indices[i]
            vidx = indices[pi]
            @views c_search_space = search_space[vidx]
            if !CS.isfixed(c_search_space)
                for pv in current_fixed_vals
                    if has(c_search_space, pv)
                        if !rm!(com, c_search_space, pv)
                            logs && @warn "The problem is infeasible"
                            return false
                        end

                        if nvalues(c_search_space) == 1
                            only_value = CS.value(c_search_space)
                            push!(fixed_vals, only_value)
                            push!(new_fixed_vals, only_value)
                            bfixed = true
                            break
                        end
                    end
                end
            end
        end
        current_fixed_vals = new_fixed_vals
    end

    if length(fixed_vals) == nindices
        return true
    end

    min_pvals, max_pvals = extrema(pvals)
    len_range = max_pvals - min_pvals + 1

    # find maximum_matching for infeasible check and Berge's lemma
    # building graph
    # ei = indices, ej = possible values
    # i.e ei=[1,2,1] ej = [1,2,2] => 1->[1,2], 2->[2]
    min_pvals_m1 = min_pvals - 1

    pval_mapping = constraint.pval_mapping
    vertex_mapping = constraint.vertex_mapping
    vertex_mapping_bw = constraint.vertex_mapping_bw

    vc = 1
    for i in indices
        vertex_mapping_bw[vc] = i
        vc += 1
    end
    pvc = 1
    for pv in pvals
        pval_mapping[pvc] = pv
        vertex_mapping[pv-min_pvals_m1] = vc
        vertex_mapping_bw[vc] = pv
        vc += 1
        pvc += 1
    end
    num_nodes = vc

    # count the number of edges
    num_edges = 0
    @inbounds for i in indices
        num_edges += nvalues(search_space[i])
    end

    di_ei = constraint.di_ei
    di_ej = constraint.di_ej
    di_ei .= 0
    di_ej .= 0

    # add edge from each index to the possible values
    edge_counter = 0
    vc = 0
    @inbounds for i in indices
        vc += 1
        if isfixed(search_space[i])
            edge_counter += 1
            di_ei[edge_counter] = vc
            di_ej[edge_counter] =
                vertex_mapping[CS.value(search_space[i])-min_pvals_m1] - nindices
        else
            for pv in view_values(search_space[i])
                edge_counter += 1
                di_ei[edge_counter] = vc
                di_ej[edge_counter] = vertex_mapping[pv-min_pvals_m1] - nindices
            end
        end
    end

    matching_init = constraint.matching_init
    matching_init.l_in_len = num_edges
    maximum_matching = bipartite_cardinality_matching(
        di_ei,
        di_ej,
        vc,
        len_range;
        l_sorted = true,
        matching_init = matching_init,
    )
    if maximum_matching.weight != nindices
        logs && @warn "Infeasible (No maximum matching was found)"
        return false
    end

    # directed edges for strongly connected components
    vc = 0
    edge_counter = 0
    @inbounds for i in indices
        vc += 1
        if isfixed(search_space[i])
            edge_counter += 1
            di_ei[edge_counter] = vc
            di_ej[edge_counter] = vertex_mapping[CS.value(search_space[i])-min_pvals_m1]
        else
            for pv in view_values(search_space[i])
                edge_counter += 1
                if pv == pval_mapping[maximum_matching.match[vc]]
                    di_ei[edge_counter] = vc
                    di_ej[edge_counter] = vertex_mapping[pv-min_pvals_m1]
                else
                    di_ei[edge_counter] = vertex_mapping[pv-min_pvals_m1]
                    di_ej[edge_counter] = vc
                end
            end
        end
    end

    # if we have more values than indices
    if length(pvals) > nindices
        # add extra node which has all values as input which are used in the maximum matching
        # and the ones in maximum matching as inputs see: http://www.minicp.org (Part 6)
        # the direction is opposite to that of minicp
        used_in_maximum_matching = Dict{Int,Bool}()
        for pval in pvals
            used_in_maximum_matching[pval] = false
        end
        vc = 0
        for i in indices
            vc += 1
            for pv in view_values(search_space[i])
                if pv == pval_mapping[maximum_matching.match[vc]]
                    used_in_maximum_matching[pv] = true
                    break
                end
            end
        end
        new_vertex = num_nodes + 1
        for kv in used_in_maximum_matching
            # not in maximum matching
            edge_counter += 1
            if length(di_ei) >= edge_counter
                if !kv.second
                    di_ei[edge_counter] = new_vertex
                    di_ej[edge_counter] = vertex_mapping[kv.first-min_pvals_m1]
                else
                    di_ei[edge_counter] = vertex_mapping[kv.first-min_pvals_m1]
                    di_ej[edge_counter] = new_vertex
                end
            else
                if !kv.second
                    push!(di_ei, new_vertex)
                    push!(di_ej, vertex_mapping[kv.first-min_pvals_m1])
                else
                    push!(di_ei, vertex_mapping[kv.first-min_pvals_m1])
                    push!(di_ej, new_vertex)
                end
            end
        end
    end

    sccs_map = strong_components_map(di_ei[1:edge_counter], di_ej[1:edge_counter])

    # remove the left over edges from the search space
    vmb = vertex_mapping_bw
    for (src, dst) in zip(di_ei, di_ej)
        # only zeros coming afterwards
        if src == 0
            break
        end
        # edges to the extra node don't count
        if src > num_nodes || dst > num_nodes
            continue
        end

        # if in same strong component -> part of a cycle -> part of a maximum matching
        if sccs_map[src] == sccs_map[dst]
            continue
        end
        #  remove edges in maximum matching and then edges which are part of a cycle
        if src <= nindices &&
           dst == vertex_mapping[pval_mapping[maximum_matching.match[src]]-min_pvals_m1]
            continue
        end


        cind = vmb[dst]
        if !rm!(com, search_space[cind], vmb[src])
            logs && @warn "The problem is infeasible"
            return false
        end

        # if only one value possible make it fixed
        if nvalues(search_space[cind]) == 1
            only_value = CS.value(search_space[cind])
        end
    end

    return true
end

"""
    still_feasible(com::CoM, constraint::AllDifferentConstraint, fct::MOI.VectorOfVariables, set::AllDifferentSetInternal, vidx::Int, value::Int)

Return whether the constraint can be still fulfilled when setting a variable with index `vidx` to `value`.
"""
function still_feasible(
    com::CoM,
    constraint::AllDifferentConstraint,
    fct::MOI.VectorOfVariables,
    set::AllDifferentSetInternal,
    vidx::Int,
    value::Int,
)
    indices = constraint.indices
    for i = 1:length(indices)
        if indices[i] == vidx
            continue
        end
        if issetto(com.search_space[indices[i]], value)
            return false
        end
    end
    return true
end

function is_solved_constraint(
    constraint::AllDifferentConstraint,
    fct::MOI.VectorOfVariables,
    set::AllDifferentSetInternal,
    values::Vector{Int}
)
    return allunique(values)
end