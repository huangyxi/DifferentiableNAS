using DifferentiableNAS
using Flux
using Flux: throttle, logitcrossentropy, onecold, onehotbatch, Optimiser
using Zygote: @nograd
using StatsBase: mean
using Parameters
using CUDA
using Distributions
using BSON
using Dates
include("../CIFAR10.jl")
include("../training_utils.jl")
@nograd onehotbatch


argparams = trial_params(batchsize = 32, trainval_fraction = 0.02)

num_ops = length(PRIMITIVES)

optimiser_α = Optimiser(WeightDecay(1e-3),ADAM(3e-4,(0.5,0.999)))
optimiser_w = Optimiser(WeightDecay(3e-4),Momentum(0.025, 0.9))

train, val = get_processed_data(argparams.val_split, argparams.batchsize, argparams.trainval_fraction)
test = get_test_data(argparams.test_fraction)

histepoch = historiessml()
histbatch = historiessml()
losses = [0.0, 0.0]

base_folder = prepare_folder("admm")

cbepoch = CbAll(CUDA.reclaim, GC.gc, histepoch, save_progress, CUDA.reclaim, GC.gc)
cbbatch = CbAll(CUDA.reclaim, GC.gc, histbatch, CUDA.reclaim, GC.gc)

m = DARTSModel(num_cells = 4, channels = 4) |> gpu
zu = ADMMaux(0*vcat(m.normal_αs, m.reduce_αs), 0*vcat(m.normal_αs, m.reduce_αs))
for epoch in 1:argparams.epochs
    @show epoch
    ADMMtrain1st!(loss, m, train, val, optimiser_w, optimiser_α, zu, 3e-3, losses, epoch; cbepoch = cbepoch, cbbatch = cbbatch)
end
