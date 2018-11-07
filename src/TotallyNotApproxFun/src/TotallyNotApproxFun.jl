module TotallyNotApproxFun

using FastGaussQuadrature
using StaticArrays
using Base.Iterators
using LinearAlgebra

export Fun, ComboFun, approximate, ProductFun, LagrangeFun, VectorFun, MultilinearFun
export Basis, OrthoBasis, ProductBasis, LagrangeBasis
export points, LobattoPoints
export ∇, ∫, ∫Ψ, ∫∇Ψ

#A representation of a T-valued function in an N-Dimensional space.
abstract type Fun{T, N} end

summary(io, fn::Fun{T}) where {T} = show(IOContext(io, :typeinfo=>T), "$(nameof(f))()≈$(value(fn))")

function Base.show(io::IO, f::Fun{T}) where {T}
    if (get(io, :typeinfo, Any) <: typeof(f))
        print(io, "ƒ()≈")
    elseif get(io, :compact, false)
        print(io, "$(nameof(f))()::$T≈")
    else
        print(io, "$(typeof(f))()≈")
    end
    show(IOContext(io, :typeinfo=>T), value(f))
end

#An approximation of the value of a function (used for printing). For now, most of our funs happen to be defined on -1 to 1. In the future, defining funs over a `Space` type would allow us to implement something more precise here.
value(f::Fun{T, N}) where {T, N} = f(@SVector zeros(N))

#A discretization of a (T-valued function)-valued function in an N-Dimensional space.
abstract type Basis{T, N, F<:Fun{T, N}} <: AbstractArray{F, N} end

#A function represented by a linear combination of basis functions
struct ComboFun{T, N, B<:Basis{<:Any, N}, C<:AbstractArray{T}} <: Fun{T, N}
    basis::B
    coeffs::C
end

(f::ComboFun)(x...) = apply(f, SVector(x...))
#f(x) is just sum_i(c_i * b_i(x))
function apply(f::ComboFun, x::AbstractVector)
    i = first(eachindex(f.coeffs))
    y = f.coeffs[i] * apply(f.basis[i], x)
    y -= y
    for i in eachindex(f.coeffs)
        y += f.coeffs[i] * apply(f.basis[i], x)
    end
    return y
end

#A basis corresponding to a set of points, where the basis function i is one(T) at point i and zero(T) everywhere else
abstract type OrthoBasis{T, N, F} <: Basis{T, N, F} end
points(::OrthoBasis) = error("Subtypes of OrthoBasis must define the points function")
approximate(f, b::OrthoBasis) = ComboFun(b, map(f, points(b)))

for op in (:(Base.:+), :(Base.:-), :(Base.zero), :(LinearAlgebra.transpose), :(LinearAlgebra.norm), :(Base.:exp))
    @eval begin
        function $(op)(a::ComboFun{T, N, B}) where {T, N, B <: OrthoBasis}
            ComboFun(a.basis, map($op, a.coeffs))
        end
    end
end
for op in (:(Base.:+), :(Base.:-), :(Base.:*), :(Base.:/), :(Base.:exp), :(Base.:^))
    @eval begin
        function $op(a::ComboFun{T, N, B}, b::ComboFun{S, N, B}) where {T, S, N, B <: OrthoBasis}
            @assert a.basis == b.basis
            ComboFun(a.basis, $op.(a.coeffs, b.coeffs))
        end
        function $op(a::ComboFun{T, N, B}, b) where {T, N, B <: OrthoBasis}
            ComboFun(a.basis, $op.(a.coeffs, b))
        end
        function $op(a::ComboFun{T, N, B}, b::Fun) where {T, N, B <: OrthoBasis}
            throw(NotImplementedError())
        end
        function $op(a, b::ComboFun{T, N, B}) where {T, N, B <: OrthoBasis}
            ComboFun(b.basis, $op.(a, b.coeffs))
        end
        function $op(a::Fun, b::ComboFun{T, N, B}) where {T, N, B <: OrthoBasis}
            throw(NotImplementedError())
        end
    end
end

#A function which is a constant
struct ConstFun{T, N} <: Fun{T, N}
    val::T
end

(f::ConstFun)(x...) = apply(f, SVector(x...))
function apply(f::ConstFun{T, N}, x::AbstractVector) where {T, N}
    f.val
end
WrapFun(x) = ConstFun(x)
WrapFun(x::Fun) = x

#A function which is a product of one-dimensional functions
struct ProductFun{T, N, F <: Tuple{Vararg{Fun{T, 1}, N}}} <: Fun{T, N}
    funs::F
    ProductFun(funs::Fun{T, 1}) where {T} = new{T, 1, Tuple{typeof(funs)}}((funs,))
    ProductFun(funs::Fun{T, 1}...) where {T} = new{T, length(funs), typeof(funs)}(funs)
end
function ProductFun(args...)
    if any(isa.(args, Fun))
        return ProductFun(WrapFun.(args))
    else
        return prod(args)
    end
end

(f::ProductFun)(x...) = apply(f, SVector(x...))
function apply(f::ProductFun{T, N}, x::AbstractVector) where {T, N}
    y = apply(f.funs[1], SVector(x[1]))
    for i in 1:N
        y *= apply(f.funs[i], SVector(x[i]))
    end
    y
end

#A basis which is an outer product of one-dimensional bases
struct ProductBasis{T, N, B <: Tuple{Vararg{OrthoBasis{T, 1}, N}}} <: OrthoBasis{T, N, Fun{T, N}}
    bases::B
    ProductBasis(basis::OrthoBasis{T, 1}) where {T} = new{T, 1, Tuple{typeof(basis)}}((basis,))
    ProductBasis(bases::OrthoBasis{T, 1}...) where {T} = new{T, length(bases), typeof(bases)}(bases)
end
Base.size(b::ProductBasis) = map(length, b.bases)
Base.eltype(b::ProductBasis{T, N}) where {T, N} = ProductFun{T, N, Tuple{map(eltype, b.bases)...}}
Base.getindex(b::ProductBasis, i::Int...)::eltype(b) = ProductFun(map(getindex, b.bases, i)...)
points(b::ProductBasis) = collect(product(map(points, b.bases)...))
#Base.Broadcast.broadcastable(b::ProductBasis) = SArray{Tuple{size(b)...}}(b) #TODO generalize to non-static children

#The minimum-degree polynomial function which is 1 at the nth point and 0 at the other points
struct LagrangeFun{T, P <: AbstractVector{T}} <: Fun{T, 1}
    points::P
    n::Int
end

LagrangeFun(points::AbstractVector, n) = LagrangeFun{eltype(points), typeof(points)}(points, n)
(f::LagrangeFun)(x...) = apply(f, SVector(x...))
#This method is mostly here for clarity, it probably shouldn't be called (TODO specialize somewhere with a stable interpolation routine)
function apply(f::LagrangeFun{T}, x::AbstractVector{S}) where {T, S}
    @assert length(x) == 1
    T′ = promote_type(T, S)
    T′ = Base.promote_op(/, T′, T′)
    y = one(T′)
    for i in eachindex(f.points)
        if i != f.n
            y *= (x[1] - f.points[i])/(f.points[f.n] - f.points[i])
        end
    end
    y::T′
end

#A basis of polynomials
struct LagrangeBasis{T, P <: AbstractVector{T}} <: OrthoBasis{T, 1, LagrangeFun{T, P}}
    points::P
end

Base.size(b::LagrangeBasis) = size(b.points)
Base.getindex(b::LagrangeBasis, i::Int) = LagrangeFun(b.points, i)
points(b::LagrangeBasis) = b.points
#Base.Broadcast.broadcastable(b::LagrangeBasis) = SArray{Tuple{size(b)...}}(b) #TODO generalize to non-static children

#A vector representing Lobatto Points
struct LobattoPoints{T, N} <: AbstractVector{T} end

Base.size(p::LobattoPoints{T, N}) where {T, N} = (N,)
@generated function Base.getindex(p::LobattoPoints{T, N}, i::Int) where {T, N}
    return :($(SVector{N, T}(gausslobatto(N)[1]))[i])
end
LobattoPoints(n) = LobattoPoints{Float64, n + 1}()
#Base.Broadcast.broadcastable(p::LobattoPoints) = SArray{Tuple{size(p)...}}(p)

function MultilinearFun(x₀, x₁, y₀, y₁)
    x₀, x₁, y₀, y₁ = (SVector(x₀), SVector(x₁), SVector(y₀), SVector(y₁))
    ComboFun(ProductBasis(LagrangeBasis.(SVector.(x₀, x₁))...), SVector.(collect(product(SVector.(y₀, y₁)...))))
end

∫(f::ComboFun) = sum(∫.(f.basis) .* f.coeffs)

∫(f::ProductFun) = prod(∫.(f.funs)...)

@generated function ∫(f::LagrangeFun{T, <:LobattoPoints{T, N}}) where {T, N}
    return :($(SVector{N, T}(gausslobatto(N)[2]))[f.n])
end

@generated function Base.map(::typeof(∫), b::LagrangeBasis{T, <:LobattoPoints{T, N}}) where {T, N}
    return :($(SVector{N, T}(gausslobatto(N)[2])))
end

function ∫(f::ComboFun{T, N, <:ProductBasis{T, N}}) where {T, N}
    t = map(basis -> map(∫, basis), f.basis.bases) #these are actually the weights
    sum(prod.(collect(product(t...))) .* f.coeffs)
end

∇(f::ComboFun) = sum(∇(b) * c for (b, c) in zip(f.basis, f.coeffs))

∇(f::ComboFun{<:Any, <:Any, <:LagrangeBasis{<:Any, <:SVector{2}}}) = (f.coeffs[2] - f.coeffs[1])/(f.basis.points[2] - f.basis.points[1])

∇(f::LagrangeFun) = ComboFun(spectralderivative(f.points)[:#=?=#, f.n], LagrangeBasis(f.points)) #TODO generate

∇(b::LagrangeBasis) = [ComboFun(spectralderivative(b.points)[:#=?=#, n], LagrangeBasis(b.points)) for n in eachindex(points)] #TODO generate

function ∇(f::ComboFun{<:Any, N, <:ProductBasis{<:Any, N, <:Tuple{Vararg{<:LagrangeBasis}}}}) where {N} #TODO generate
    things = [mapslices(c-> spectralderivative(b.points) * c, f.coeffs, dims=i) for (i, b) in enumerate(f.basis.bases)]
    ComboFun(SVector.(things...), f.basis)
end

function ∫∇Ψ(f::ComboFun{S, N, B}) where {T, S, N, B<:ProductBasis{T, N}}
    t = map(basis -> map(∫, basis), f.basis.bases) #these are actually the weights
    ω = prod.(collect(product(t...)))
    return ComboFun(sum(mapslices(c->D(f.basis.bases[n])' * c, ω.(getindex.(f.coeffs, n)), dims=n) for n in 1:N), f.basis.bases)
end

function ∫Ψ(f::ComboFun)
    return ComboFun(f.coeffs .* map(∫, f.basis), f.basis)
end





#OVERRIDES

StaticArrays.SVector(i::CartesianIndex) = SVector(Tuple(i))

function Base.collect(it::Base.Iterators.ProductIterator{TT}) where {TT<:Tuple{Vararg{LobattoPoints}}}
    sproduct(it.iterators)
end

_length(::Type{LobattoPoints{T, N}}) where {T, N} = N
_eltype(::Type{LobattoPoints{T, N}}) where {T, N} = T
using Base.Cartesian
@generated function sproduct(points::TT) where {N, TT<:Tuple{Vararg{LobattoPoints, N}}}
    lengths = map(_length, TT.parameters)
    eltypes = map(_eltype, TT.parameters)
    M = prod(lengths)
    I = CartesianIndices((lengths...,))
    quote
        Base.@_inline_meta
        @nexprs $N j->(P_j = points[j])
        @nexprs $N j->(S_j = length(P_j))
        @nexprs $M j->(elem_j = @ntuple $N k-> P_k[($I)[j][k]])
        @ncall $M SArray{Tuple{$(lengths...)}, Tuple{$(eltypes...)}, $N, $M} elem
    end
end

#1 function to interpolate global coefficients to local -1 to 1 for basis
#  a) only store scale in type domain
#  b) store scale and offset

function Base.collect(it::Base.Iterators.ProductIterator{<:Tuple{Vararg{SArray}}})
    SArray{Tuple{size(it)...},eltype(it),ndims(it),length(it)}(it...)
end

function Base.collect(it::Base.Iterators.ProductIterator{<:Tuple{Vararg{LobattoPoints}}})
    SArray{Tuple{size(it)...},eltype(it),ndims(it),length(it)}(it...)
end

end
