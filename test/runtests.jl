using Test
using ConstraintSolver
using JSON
using MathOptInterface, JuMP

const MOI = MathOptInterface
const CS = ConstraintSolver
const MOIU = MOI.Utilities

include("fcts.jl")
include("moi.jl")

include("stable_set.jl")
include("sudoku_fcts.jl")
include("small_special.jl")
include("maximum_weight_matching.jl")
include("small_eq_sum_real.jl")
include("sudoku.jl")
include("killer_sudoku.jl")
include("graph_color.jl")