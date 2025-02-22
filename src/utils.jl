export ccat,
	squeeze,
    all_αs,
    all_ws_sansbn,
    flip_batch!,
    shift_batch!,
	cutout_batch!,
	norm_batch!,
    TrainCuIterator,
    EvalCuIterator,
    TestCuIterator,
    CosineAnnealing,
	apply!,
	depthwiseconv!,
	cudnnDepthwiseConvolutionDescriptor
using Adapt
using CUDA
using Flux
import Flux.Optimise.apply!

ccat(X...) = cat(X...; dims=3)

function squeeze(A::AbstractArray) #generalize this?
    if ndims(A) == 3
        if size(A, 3) > 1
            return dropdims(A; dims = (1))
        elseif size(A, 3) == 1
            return dropdims(A; dims = (1, 3))
        end
    elseif ndims(A) == 4
        if size(A, 4) > 1
            return dropdims(A; dims = (1, 2))
        elseif size(A, 4) == 1
            return dropdims(A; dims = (1, 2, 4))
        end
    end
    return A
end

function all_params(submodels)
    ps = Params()
    for submodel in submodels
        Flux.params!(ps, submodel)
    end
    return ps
end

all_αs(model) = Flux.params([model.normal_αs, model.reduce_αs])
all_ws(model) = Flux.params([model.stem, model.cells..., model.global_pooling, model.classifier])

function all_ws_sansbn(model) #without batchnorm params
    all_w = Flux.params([model.stem, model.cells..., model.global_pooling, model.classifier])
    for (i,cell) in enumerate(model.cells)
        for (j,mixedop) in enumerate(cell.mixedops)
            for (k,op) in enumerate(mixedop.ops)
                for (l,layer) in enumerate(op.op)
                    if typeof(layer) <: Flux.BatchNorm
                        delete!(all_w, layer.γ)
                        delete!(all_w, layer.β)
                    end
                end
            end
        end
    end
    for (l,layer) in enumerate(model.stem.layers)
        if typeof(layer) <: Flux.BatchNorm
            delete!(all_w, layer.γ)
            delete!(all_w, layer.β)
        end
    end
    all_w
end

CIFAR_MEAN = [0.49139968f0, 0.48215827f0, 0.44653124f0]
CIFAR_STD = [0.24703233f0, 0.24348505f0, 0.26158768f0]

function flip_batch!(batch::Array{Float32,4})
	flips = falses(size(batch,4))
	for image in 1:size(batch,4)
		orig = copy(batch[:,:,:,image])
		flip = rand(Bool)
		if flip
			flipped = reverse(orig, dims=2)
			batch[:,:,:,image] = flipped
		end
		flips[image] = flip
	end
	flips
end

function shift_batch!(batch::Array{Float32,4})
	shifts = Array{Int64}(undef,size(batch,4),2)
	for image in 1:size(batch,4)
		orig = copy(batch[:,:,:,image])
		shiftx = rand(-4:4)
		shifty = rand(-4:4)
		if shiftx > 0
			batch[1:size(batch,1)-shiftx,:,:,image] = orig[shiftx+1:size(batch,1),:,:]
			batch[size(batch,1)-shiftx+1:size(batch,1),:,:,image] .= 0f0
		elseif shiftx < 0
			batch[1:-shiftx,:,:,image] .= 0f0
			batch[1-shiftx:size(batch,1),:,:,image] = orig[1:size(batch,1)+shiftx,:,:]
		end
		orig = copy(batch[:,:,:,image])
		if shifty > 0
			batch[:,1:size(batch,2)-shifty,:,image] = orig[:,shifty+1:size(batch,2),:]
			batch[:,size(batch,2)-shifty+1:size(batch,2),:,image] .= 0f0
		elseif shifty < 0
			batch[:,1:-shifty,:,image] .= 0f0
			batch[:,1-shifty:size(batch,2),:,image] = orig[:,1:size(batch,2)+shifty,:]
		end
		shifts[image,:] = [shiftx;shifty]
	end
	shifts
end

function cutout_batch!(batch::Array{Float32,4}, cutout::Int = -1)
	cutouts = Array{Int64}(undef,size(batch,4),2)
	if cutout > 0
		for image in 1:size(batch,4)
			cutx = rand(1:size(batch,1))
			cuty = rand(1:size(batch,2))
			minx = maximum([cutx-cutout÷2,1])
			maxx = minimum([cutx+cutout÷2-1,size(batch,1)])
			miny = maximum([cuty-cutout÷2,1])
			maxy = minimum([cuty+cutout÷2-1,size(batch,2)])
			batch[minx:maxx,miny:maxy,:,image] .= 0f0
			cutouts[image,:] = [cutx;cuty]
		end
	end
end

function norm_batch!(batch::Array{Float32,4})
	mean_im = repeat(reshape(CIFAR_MEAN, (1,1,3,1)), outer = [32,32,1,size(batch,4)])
	std_im = repeat(reshape(CIFAR_STD, (1,1,3,1)), outer = [32,32,1,size(batch,4)])
	batch = (batch.-mean_im)./std_im
end


mutable struct TrainCuIterator{B}
    batches::B
    previous::Any
    TrainCuIterator(batches) = new{typeof(batches)}(batches)
end
function Base.iterate(c::TrainCuIterator, state...)
    item = iterate(c.batches, state...)
    isdefined(c, :previous) && foreach(CUDA.unsafe_free!, c.previous)
    item === nothing && return nothing
    batch, next_state = item
	flip_batch!(batch[1])
	shift_batch!(batch[1])
	norm_batch!(batch[1])
    cubatch = map(x -> adapt(CuArray, x), batch)
    c.previous = cubatch
	return cubatch, next_state
end

mutable struct EvalCuIterator{B}
    batches::B
    previous::Any
    EvalCuIterator(batches) = new{typeof(batches)}(batches)
end
function Base.iterate(c::EvalCuIterator, state...)
    item = iterate(c.batches, state...)
    isdefined(c, :previous) && foreach(CUDA.unsafe_free!, c.previous)
    item === nothing && return nothing
    batch, next_state = item
	flip_batch!(batch[1])
	shift_batch!(batch[1])
	norm_batch!(batch[1])
	cutout_batch!(batch[1], 16)
    cubatch = map(x -> adapt(CuArray, x), batch)
    c.previous = cubatch
    return cubatch, next_state
end

mutable struct TestCuIterator{B}
    batches::B
    previous::Any
    TestCuIterator(batches) = new{typeof(batches)}(batches)
end
function Base.iterate(c::TestCuIterator, state...)
    item = iterate(c.batches, state...)
    isdefined(c, :previous) && foreach(CUDA.unsafe_free!, c.previous)
    item === nothing && return nothing
    batch, next_state = item
	norm_batch!(batch[1])
    cubatch = map(x -> adapt(CuArray, x), batch)
    c.previous = cubatch
    return cubatch, next_state
end


mutable struct CosineAnnealing
  tmax::Int64
  t::Int64
end

CosineAnnealing(tmax::Int64 = 1) = CosineAnnealing(tmax, 0)

function Flux.Optimise.apply!(o::CosineAnnealing, x, Δ)
  tmax = o.tmax
  t = o.t
  Δ .*= (1 + cos(t/tmax*pi))/2
  return Δ
end

import NNlib: depthwiseconv!, ∇depthwiseconv_data!, ∇depthwiseconv_filter!

using CUDA.APIUtils: @workspace

using CUDA.CUDNN:
    cudnnConvolutionForward,
    cudnnConvolutionForward!,
    cudnnConvolutionBackwardFilter,
    cudnnConvolutionBackwardData,
    cudnnGetConvolutionNdForwardOutputDim,
    cudnnSetConvolutionMathType,
    cudnnSetConvolutionReorderType,
    cudnnSetConvolutionGroupCount,
    cudnnFindConvolutionForwardAlgorithmEx,
        cudnnConvolutionFwdAlgoPerf_t,
    cudnnFindConvolutionBackwardFilterAlgorithmEx,
        cudnnConvolutionBwdFilterAlgoPerf_t,
    cudnnFindConvolutionBackwardDataAlgorithmEx,
        cudnnConvolutionBwdDataAlgoPerf_t,
    cudnnConvolutionDescriptor,
        cudnnConvolutionDescriptor_t,
        cudnnCreateConvolutionDescriptor,
        cudnnSetConvolutionNdDescriptor,
        cudnnDestroyConvolutionDescriptor,
    cudnnConvolutionMode_t,
        CUDNN_CONVOLUTION,       # 0
        CUDNN_CROSS_CORRELATION, # 1
    cudnnActivationMode_t,
        CUDNN_ACTIVATION_SIGMOID,      # 0
        CUDNN_ACTIVATION_RELU,         # 1
        CUDNN_ACTIVATION_TANH,         # 2
        CUDNN_ACTIVATION_CLIPPED_RELU, # 3
        CUDNN_ACTIVATION_ELU,          # 4
        CUDNN_ACTIVATION_IDENTITY,     # 5
    cudnnNanPropagation_t,
        CUDNN_NOT_PROPAGATE_NAN, # 0
        CUDNN_PROPAGATE_NAN,     # 1
    cudnnMathType_t,
        CUDNN_DEFAULT_MATH,                    # 0
        CUDNN_TENSOR_OP_MATH,                  # 1
        CUDNN_TENSOR_OP_MATH_ALLOW_CONVERSION, # 2
        CUDNN_FMA_MATH,                        # 3
    cudnnReorderType_t,
        CUDNN_DEFAULT_REORDER, # 0
        CUDNN_NO_REORDER,      # 1
    cudnnConvolutionFwdAlgo_t,
        CUDNN_CONVOLUTION_FWD_ALGO_IMPLICIT_GEMM,         # 0
        CUDNN_CONVOLUTION_FWD_ALGO_IMPLICIT_PRECOMP_GEMM, # 1
        CUDNN_CONVOLUTION_FWD_ALGO_GEMM,                  # 2
        CUDNN_CONVOLUTION_FWD_ALGO_DIRECT,                # 3
        CUDNN_CONVOLUTION_FWD_ALGO_FFT,                   # 4
        CUDNN_CONVOLUTION_FWD_ALGO_FFT_TILING,            # 5
        CUDNN_CONVOLUTION_FWD_ALGO_WINOGRAD,              # 6
        CUDNN_CONVOLUTION_FWD_ALGO_WINOGRAD_NONFUSED,     # 7
        CUDNN_CONVOLUTION_FWD_ALGO_COUNT,                 # 8
    cudnnConvolutionBwdFilterAlgo_t,
        CUDNN_CONVOLUTION_BWD_FILTER_ALGO_0,                 # 0, /* non-deterministic */
        CUDNN_CONVOLUTION_BWD_FILTER_ALGO_1,                 # 1,
        CUDNN_CONVOLUTION_BWD_FILTER_ALGO_FFT,               # 2,
        CUDNN_CONVOLUTION_BWD_FILTER_ALGO_3,                 # 3, /* non-deterministic */
        CUDNN_CONVOLUTION_BWD_FILTER_ALGO_WINOGRAD,          # 4, /* not implemented */
        CUDNN_CONVOLUTION_BWD_FILTER_ALGO_WINOGRAD_NONFUSED, # 5,
        CUDNN_CONVOLUTION_BWD_FILTER_ALGO_FFT_TILING,        # 6,
        CUDNN_CONVOLUTION_BWD_FILTER_ALGO_COUNT,             # 7
    cudnnConvolutionBwdDataAlgo_t,
        CUDNN_CONVOLUTION_BWD_DATA_ALGO_0,                 # 0, /* non-deterministic */
        CUDNN_CONVOLUTION_BWD_DATA_ALGO_1,                 # 1,
        CUDNN_CONVOLUTION_BWD_DATA_ALGO_FFT,               # 2,
        CUDNN_CONVOLUTION_BWD_DATA_ALGO_FFT_TILING,        # 3,
        CUDNN_CONVOLUTION_BWD_DATA_ALGO_WINOGRAD,          # 4,
        CUDNN_CONVOLUTION_BWD_DATA_ALGO_WINOGRAD_NONFUSED, # 5,
        CUDNN_CONVOLUTION_BWD_DATA_ALGO_COUNT,             # 6
    cudnnTensorFormat_t,
        CUDNN_TENSOR_NCHW,        # 0, /* row major (wStride = 1, hStride = w) */
        CUDNN_TENSOR_NHWC,        # 1, /* feature maps interleaved ( cStride = 1 )*/
        CUDNN_TENSOR_NCHW_VECT_C, # 2, /* each image point is vector of element of C, vector length in data type */
    cudnnDataType,
    convdims,
    math_mode,
    handle,
	scalingParameter,
	cudnnTensorDescriptor,
	cudnnFilterDescriptor,
	cudnnConvolutionBwdDataAlgoPerf,
	cudnnConvolutionBwdFilterAlgoPerf,
	cudnnConvolutionBackwardData,
	cudnnConvolutionBackwardFilter


function nnlibPadding(dims)
    pd = NNlib.padding(dims)
    if !all(pd[1:2:end] .== pd[2:2:end])
        @warn "cuDNN does not support asymmetric padding; defaulting to symmetric choice" maxlog=1
    end
    return pd[1:2:end]
end
const CUDNNFloat = Union{Float16,Float32,Float64}

function cudnnDepthwiseConvolutionDescriptor(cdims::DepthwiseConvDims, x::DenseCuArray{T}) where T
    cudnnConvolutionDescriptor(convdims(nnlibPadding(cdims),size(x)), convdims(NNlib.stride(cdims),size(x)), convdims(NNlib.dilation(cdims),size(x)), CUDNN_CONVOLUTION, cudnnDataType(T), CUDNN_TENSOR_OP_MATH, CUDNN_DEFAULT_REORDER, Cint(size(x,3)))
end

function depthwiseconv!(y::DenseCuArray{T}, x::DenseCuArray{T}, w::DenseCuArray{T}, cdims::DepthwiseConvDims;
               alpha=1, beta=0, algo=-1) where T<:Union{Float16,Float32,Float64}
    d = cudnnDepthwiseConvolutionDescriptor(cdims, x)
    cudnnConvolutionForward!(y, w, x, d; alpha, beta, z=y)
end

function ∇depthwiseconv_data!(dx::DenseCuArray{T}, dy::DenseCuArray{T}, w::DenseCuArray{T},
                     cdims::DepthwiseConvDims; alpha=1, beta=0, algo=-1) where T<:CUDNNFloat
    alpha, beta = scalingParameter(T,alpha), scalingParameter(T,beta);
    xDesc, yDesc, wDesc = cudnnTensorDescriptor(dx), cudnnTensorDescriptor(dy), cudnnFilterDescriptor(w)
    convDesc = cudnnDepthwiseConvolutionDescriptor(cdims, dx)
    p = cudnnConvolutionBwdDataAlgoPerf(wDesc, w, yDesc, dy, convDesc, xDesc, dx)
    @workspace size=p.memory workspace->cudnnConvolutionBackwardData(handle(), alpha, wDesc, w, yDesc, dy, convDesc, p.algo, workspace, sizeof(workspace), beta, xDesc, dx)
    return dx
end

function ∇depthwiseconv_filter!(dw::DenseCuArray{T}, x::DenseCuArray{T}, dy::DenseCuArray{T},
                       cdims::DepthwiseConvDims; alpha=1, beta=0, algo=-1) where T<:CUDNNFloat
    alpha, beta = scalingParameter(T,alpha), scalingParameter(T,beta);
    xDesc, yDesc, wDesc = cudnnTensorDescriptor(x), cudnnTensorDescriptor(dy), cudnnFilterDescriptor(dw)
    convDesc = cudnnDepthwiseConvolutionDescriptor(cdims, x)
    p = cudnnConvolutionBwdFilterAlgoPerf(xDesc, x, yDesc, dy, convDesc, wDesc, dw);
    @workspace size=p.memory workspace->cudnnConvolutionBackwardFilter(handle(), alpha, xDesc, x, yDesc, dy, convDesc, p.algo, workspace, sizeof(workspace), beta, wDesc, dw);
    return dw
end
