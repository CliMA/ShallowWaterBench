module GPUMeshing

export GPU

using SimpleMeshing
using .Meshing

using StructsOfArrays

struct GPU <: Meshing.Backend end
import .Meshing: storage, overelems

function storage(::Type{T}, mesh::PeriodicCartesianMesh{N, GPU}) where {T, N}
    inds = elems(mesh)
    underlying = StructOfArrays(T, CuArray, map(length, axes(inds))...)
    return OffsetArray(underlying, inds.indices)
end

function storage(::Type{T}, mesh::GhostCartesianMesh{N, GPU}) where {T, N}
    inds = elems(mesh).indices
    inds = ntuple(N) do i
        I = inds[i]
        (first(I)-1):(last(I)+1)
    end

    underlying = StructOfArrays(T, CuArray, map(length, inds)...)
    return OffsetArray(underlying, inds)
end

const LAUNCH_LOG = Dict{Symbol, Bool}()
function overelems(f::F, mesh::CartesianMesh{N, GPU}, args...) where {F, N}

    function kernelf(f::F, elems, mesh, args...) where F
        i = (blockIdx().x-1) * blockDim().x + threadIdx().x
        i > length(elems) && return nothing
        I = elems[i]
        f(I, mesh, args...)
        return nothing
    end

    # The below does this:
    # @cuda threads=length(elems(mesh)) kernelf(f, elems(mesh), mesh, args...)
    cuargs = (f, elems(mesh), mesh, args...)
    GC.@preserve cuargs begin
        kernel_args = map(x->adapt(CUDAnative.Adaptor(), x), cuargs)

        kernel_tt = Tuple{Core.Typeof.(kernel_args)...}
        kernel = cufunction(kernelf, kernel_tt)

        n = length(elems(mesh))
        threads = min(n, CUDAnative.maxthreads(kernel))
        blocks = ceil(Int, n / threads)

	fname = nameof(f)
	if !haskey(LAUNCH_LOG, fname)
            @info("kernel configuration", fname, N, threads, blocks,
                  CUDAnative.maxthreads(kernel),
                  CUDAnative.registers(kernel),
                  CUDAnative.memory(kernel))
            LAUNCH_LOG[fname] = true
        end

        kernel(kernel_args...; threads=threads, blocks=blocks)
    end
    return nothing
end

##
# Compatibility with other packages
##
using Adapt
using OffsetArrays

_adapt(x) = x
_adapt(x::Tuple) = map(_adapt, x)
_adapt(x::AbstractArray) = adapt(CuArray, x)
using StaticArrays
_adapt(x::StaticArray) = x
_adapt(mesh::PeriodicCartesianMesh) = PeriodicCartesianMesh(GPU(), mesh.inds)
_adapt(mesh::GhostCartesianMesh) = GhostCartesianMesh(GPU(), mesh.inds)
_adapt(mesh::LocalCartesianMesh) = LocalCartesianMesh(_adapt(mesh.mesh), mesh.neighbor_ranks, map(_adapt, mesh.synced_storage))


Adapt.adapt_structure(to, x::OffsetArray) = OffsetArray(adapt(to, parent(x)), x.offsets)
Base.Broadcast.BroadcastStyle(::Type{<:OffsetArray{<:Any, <:Any, AA}}) where AA = Base.Broadcast.BroadcastStyle(AA)

using StructsOfArrays
using CuArrays
using CUDAnative

StructsOfArrays._type_with_eltype(::Type{<:CuArray}, T, N) = CuArray{T, N}
StructsOfArrays._type_with_eltype(::Type{CuDeviceArray{_T,_N,AS}}, T, N) where{_T,_N,AS} = CuDeviceArray(T,N,AS)

StructsOfArrays._type(::Type{<:CuArray}) = CuArray
StructsOfArrays._type(::Type{<:CuDeviceArray}) = CuDeviceArray

##
# Hacks
##
import Base.Broadcast
Broadcast.broadcasted(::Broadcast.DefaultArrayStyle{1}, ::typeof(+), r::AbstractUnitRange, x::Real) = Base._range(first(r) + x, nothing, nothing, length(r))

##
# GPU broadcasting
##
using GPUArrays
GPUArrays.backend(::Type{<:OffsetArray{<:Any, <:Any, AA}}) where AA<:GPUArray = GPUArrays.backend(AA)
@inline function Base.copyto!(dest::OffsetArray{<:Any, <:Any, <:GPUArray}, bc::Broadcast.Broadcasted{Nothing})
    axes(dest) == axes(bc) || Broadcast.throwdm(axes(dest), axes(bc))
    bc′ = Broadcast.preprocess(dest, bc)
    gpu_call(dest, (dest, bc′)) do state, dest, bc′
        let I = CartesianIndex(@cartesianidx(dest))
            @inbounds dest[I] = bc′[I]
        end
        return
    end

    return dest
end

##
# Compatibility between TotallyNotApproxFun and CUDAnative
##
import TotallyNotApproxFun: Fun, Basis
_adapt(x::Fun) = x
_adapt(x::Basis) = x

##
# Support for CUDA-aware MPI
#
# TODO:
# - We need a way to query for MPI support
##
import MPI
function MPI.Isend(buf::CuArray{T}, dest::Integer, tag::Integer,
                            comm::MPI.Comm) where T
    _buf = CuArrays.buffer(buf)
    GC.@preserve _buf begin
        MPI.Isend(Base.unsafe_convert(Ptr{T}, _buf), length(buf), dest, tag, comm)
    end
end

function MPI.Irecv!(buf::CuArray{T}, src::Integer, tag::Integer,
    comm::MPI.Comm) where T
    _buf = CuArrays.buffer(buf)
    GC.@preserve _buf begin
        MPI.Irecv!(Base.unsafe_convert(Ptr{T}, _buf), length(buf), src, tag, comm)
    end
end

##
# Support for CUDA pinned host buffers
##
import CUDAdrv
function alloc(::Type{T}, dims) where T
    r_ptr = Ref{Ptr{Cvoid}}()
    nbytes = prod(dims) * sizeof(T)
    CUDAdrv.@apicall(:cuMemAllocHost, (Ptr{Ptr{Cvoid}}, Csize_t), r_ptr, nbytes)
    unsafe_wrap(Array, convert(Ptr{T}, r_ptr[]), dims, #=own=#false)
end

function free(arr)
    CUDAdrv.@apicall(:cuMemFreeHost, (Ptr{Cvoid},), arr)
end

end # module
