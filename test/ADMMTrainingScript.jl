using DifferentiableNAS
using Flux
using Flux: throttle, logitcrossentropy, onecold, onehotbatch
using Zygote: @nograd
using StatsBase: mean
using Parameters
using CUDA
using Distributions
using BSON
using Dates
include("CIFAR10.jl")
@nograd onehotbatch

@with_kw struct trial_params
    epochs::Int = 50
    batchsize::Int = 64
    throttle_::Int = 20
    val_split::Float32 = 0.5
    trainval_fraction::Float32 = 1.0
    test_fraction::Float32 = 1.0
end

argparams = trial_params(val_split = 0.1, batchsize=32, trainval_fraction = 0.01)

num_ops = length(PRIMITIVES)

losscb() = @show(loss(m, test[1] |> gpu, test[2] |> gpu))
throttled_losscb = throttle(losscb, argparams.throttle_)
function loss(m, x, y)
    @show logitcrossentropy(squeeze(m(x)), y)
end

acccb() = @show(accuracy_batched(m, val))
function accuracy(m, x, y; pert = [])
    out = mean(onecold(m(x, αs = pert), 1:10) .== onecold(y, 1:10))
end
function accuracy_batched(m, xy; pert = [])
    CUDA.reclaim()
    GC.gc()
    score = 0.0
    count = 0
    for batch in CuIterator(xy)
        @show acc = accuracy(m, batch..., pert = pert)
        score += acc*length(batch)
        count += length(batch)
        CUDA.reclaim()
        GC.gc()
    end
    display(score / count)
    score / count
end
function accuracy_unbatched(m, xy; pert = [])
    CUDA.reclaim()
    GC.gc()
    xy = xy | gpu
    acc = accuracy(m, xy..., pert = pert)
    foreach(CUDA.unsafe_free!, xy)
    CUDA.reclaim()
    GC.gc()
    acc
end

optimizer_α = ADAM(3e-4,(0.9,0.999))
optimizer_w = Nesterov(0.025,0.9) #change?

val_batchsize = 32
train, val = get_processed_data(argparams.val_split, argparams.batchsize, argparams.trainval_fraction, val_batchsize)
test = get_test_data(argparams.test_fraction)

Base.@kwdef mutable struct historiessm
    normal_αs_sm::Vector{Vector{Array{Float32, 1}}}
    reduce_αs_sm::Vector{Vector{Array{Float32, 1}}}
    activations::Vector{Dict}
    accuracies::Vector{Float32}
end

function (hist::historiessm)()#accuracies = false)
    push!(hist.normal_αs_sm, softmax.(copy(m.normal_αs)) |> cpu)
    push!(hist.reduce_αs_sm, softmax.(copy(m.reduce_αs)) |> cpu)
    push!(hist.activations, copy(m.activations.currentacts) |> cpu)

    CUDA.reclaim()
    GC.gc()
end
histepoch = historiessm([],[],[],[])
histbatch = historiessm([],[],[],[])

datesnow = Dates.now()
base_folder = string("test/models/admm_", datesnow)
mkpath(base_folder)
function save_progress()
    m_cpu = m |> cpu
    normal = m_cpu.normal_αs
    reduce = m_cpu.reduce_αs
    BSON.@save joinpath(base_folder, "model.bson") m_cpu argparams optimizer_α optimizer_w
    BSON.@save joinpath(base_folder, "alphas.bson") normal reduce argparams optimizer_α optimizer_w
    BSON.@save joinpath(base_folder, "histepoch.bson") histepoch
    BSON.@save joinpath(base_folder, "histbatch.bson") histbatch
end

struct CbAll
    cbs
end
CbAll(cbs...) = CbAll(cbs)

(cba::CbAll)() = foreach(cb -> cb(), cba.cbs)
cbepoch = CbAll(CUDA.reclaim, GC.gc, histepoch, save_progress, CUDA.reclaim, GC.gc)
cbbatch = CbAll(CUDA.reclaim, GC.gc, histbatch, CUDA.reclaim, GC.gc)


m = DARTSModel(num_cells = 4, channels = 4)
m = gpu(m)
zs = 0*vcat(m.normal_αs, m.reduce_αs)
us = 0*vcat(m.normal_αs, m.reduce_αs)
Flux.@epochs 10 ADMMtrain1st!(loss, m, train, val, optimizer_w, optimizer_α, zs, us, 1e-3; cbepoch = cbepoch, cbbatch = cbbatch)
