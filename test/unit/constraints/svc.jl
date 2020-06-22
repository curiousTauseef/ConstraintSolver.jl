@testset "SVC" begin
    m = Model(optimizer_with_attributes(CS.Optimizer, "no_prune" => true, "logging" => []))
    @variable(m, -5 <= x <= 5, Int)
    @variable(m, -5 <= y <= 5, Int)
    @constraint(m, x <= y)
    optimize!(m)
    com = JuMP.backend(m).optimizer.model.inner
    
    constraint = com.constraints[1]
    @test constraint isa CS.SingleVariableConstraint

    # doesn't check the length
    @test !CS.is_solved_constraint(constraint, constraint.std.fct, constraint.std.set, [3,2])
    @test CS.is_solved_constraint(constraint, constraint.std.fct, constraint.std.set, [2,2])
    @test CS.is_solved_constraint(constraint, constraint.std.fct, constraint.std.set, [1,2])

    constr_indices = constraint.std.indices
    @test CS.still_feasible(com, constraint, constraint.std.fct, constraint.std.set, -5, constr_indices[2])
    @test CS.fix!(com, com.search_space[constr_indices[2]], 3)
    @test !CS.still_feasible(com, constraint, constraint.std.fct, constraint.std.set, 4, constr_indices[1])
    @test CS.still_feasible(com, constraint, constraint.std.fct, constraint.std.set, 3, constr_indices[1])

    # need to create a backtrack_vec to reverse pruning
    dummy_backtrack_obj = CS.BacktrackObj(com)
    push!(com.backtrack_vec, dummy_backtrack_obj)
    # reverse previous fix
    CS.reverse_pruning!(com, 1)
    com.c_backtrack_idx = 1

    @test CS.still_feasible(com, constraint, constraint.std.fct, constraint.std.set, 4, constr_indices[1])

    m = Model(optimizer_with_attributes(CS.Optimizer, "no_prune" => true, "logging" => []))
    @variable(m, -5 <= x <= 5, Int)
    @variable(m, -5 <= y <= 5, Int)
    @constraint(m, x <= y)
    optimize!(m)
    com = JuMP.backend(m).optimizer.model.inner
    constraint = com.constraints[1]

    # feasible and no changes
    @test CS.prune_constraint!(com, constraint, constraint.std.fct, constraint.std.set)
    for ind in constr_indices
        @test sort(CS.values(com.search_space[ind])) == -5:5
    end
    @test CS.fix!(com, com.search_space[constr_indices[2]], 4)
    @test CS.prune_constraint!(com, constraint, constraint.std.fct, constraint.std.set)
    @test sort(CS.values(com.search_space[1])) == -5:4
  

    m = Model(optimizer_with_attributes(CS.Optimizer, "no_prune" => true, "logging" => []))
    @variable(m, -5 <= x <= 5, Int)
    @variable(m, -5 <= y <= 5, Int)
    @constraint(m, x <= y)
    optimize!(m)
    com = JuMP.backend(m).optimizer.model.inner
    constraint = com.constraints[1]

    # Should be synced to the other variables
    @test CS.remove_above!(com, com.search_space[constr_indices[2]], 1)
    @test CS.prune_constraint!(com, constraint, constraint.std.fct, constraint.std.set)
    for ind in constr_indices
        @test sort(CS.values(com.search_space[ind])) == -5:1
    end
end