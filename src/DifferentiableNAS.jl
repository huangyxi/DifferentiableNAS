module DifferentiableNAS

using Flux
using Base.Iterators
using StatsBase: mean
using Zygote
using LinearAlgebra

include("DARTSModel.jl")

include("DARTSTraining.jl")
include("ActivationTraining.jl")
include("MaskedTraining.jl")
include("ScalingTraining.jl")
include("ADMMTraining.jl")

include("utils.jl")

end # module
