export ADMMtrain1st!, euclidmap, regterm

using Flux
using Flux: onehotbatch
using Juno
using Base.Iterators
using StatsBase: mean
using Zygote
using Zygote: @nograd
using LinearAlgebra
using CUDA
include("utils.jl")
include("DARTSModel.jl")

function euclidmap(aus, cardinality)
    for i in 1:size(aus,1)
        to_mask = sortperm(aus[i])[1:length(aus[i])-cardinality]
        for j in to_mask
            aus[i][j] = 0
        end
    end
    aus
end

function regterm(m::DARTSModel, zs, us)
    as = vcat([exp.(n) for n in m.normal_αs], [exp.(n) for n in m.reduce_αs])
    out = 0.0
    for (a, z, u) in zip(as, zs, us)
        out += sum(abs2,a - z + u)
    end
    out
end

function ADMMtrain1st!(loss, model, train, val, opt_w, opt_α, zs, us, ρ=1e-3, losses=[0.0,0.0]; cbepoch = () -> (), cbbatch = () -> ())
    w = all_ws_sansbn(model)
    α = all_αs(model)
    local train_loss
    local val_loss
    for (i, train_batch, val_batch) in zip(1:length(train), CuIterator(train), CuIterator(val))
        gsw = gradient(w) do
            train_loss = loss(model, train_batch...)
            return train_loss
        end
        losses[1] = train_loss
        foreach(CUDA.unsafe_free!, train_batch)
        Flux.Optimise.update!(opt_w, w, gsw)
        CUDA.reclaim()
        gsα = gradient(α) do
            val_loss = loss(model, val_batch...) + ρ/2*regterm(model, zs, us)
            return val_loss
        end
        losses[2] = val_loss
        foreach(CUDA.unsafe_free!, val_batch)
        Flux.Optimise.update!(opt_α, α, gsα)
        CUDA.reclaim()
        if i%10 == 0
            as = vcat([exp.(n) for n in model.normal_αs], [exp.(n) for n in model.reduce_αs])
            display(softmax.(as))
            zs = euclidmap(as+us, 1)
            display(zs)
            us += as - zs
            display(us)
        end
        cbbatch()
    end
    cbepoch()
end
