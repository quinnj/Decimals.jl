# The two public value types.
#
# `Decimal{P,S,T}`: fixed-scale exact decimal, value == unscaled * 10^-S, with
# the invariant |unscaled| < 10^P. P (precision) and S (scale) are type
# parameters so a Vector{Decimal{P,S,T}} is byte-identical to an
# Arrow/Parquet/DuckDB decimal buffer. T is the storage integer; constructors
# derive it from P when not given.
#
# `DecimalValue{T}`: runtime-scale exact decimal for row-oriented wire values
# (e.g. PostgreSQL numeric, whose scale travels per value).

abstract type AbstractDecimal <: Real end

const StorageInt = Union{Int32, Int64, Int128, Int256}

# max decimal digits P such that 10^P - 1 always fits T
_capacity(::Type{Int32}) = 9
_capacity(::Type{Int64}) = 18
_capacity(::Type{Int128}) = 38
_capacity(::Type{Int256}) = 76

_storagetype(P::Int) = P <= 9 ? Int32 : P <= 18 ? Int64 : P <= 38 ? Int128 : Int256

_utype(::Type{Int32}) = UInt32
_utype(::Type{Int64}) = UInt64
_utype(::Type{Int128}) = UInt128
_utype(::Type{Int256}) = UInt256

_widen(::Type{Int32}) = Int64
_widen(::Type{Int64}) = Int128
_widen(::Type{Int128}) = Int256

# fold parameter validation to a compile-time constant
@generated function _checkdecparams(::Val{P}, ::Val{S}, ::Type{T}) where {P, S, T}
    ok = P isa Int && S isa Int && T <: StorageInt &&
         1 <= P <= _capacity(T) && 0 <= S <= P
    ok && return :(nothing)
    return :(throw(ArgumentError(string("invalid Decimal parameters: precision must be ",
        "an Int in 1:capacity(T) (9/18/38/76 for Int32/Int64/Int128/Int256), ",
        "scale an Int in 0:precision; got Decimal{", $P, ",", $S, ",", $T, "}"))))
end

struct Decimal{P, S, T <: StorageInt} <: AbstractDecimal
    unscaled::T
    @inline function Decimal{P, S, T}(::typeof(reinterpret), u::Integer) where {P, S, T <: StorageInt}
        _checkdecparams(Val(P), Val(S), T)
        return new{P, S, T}(u % T)
    end
end

# raw (unchecked) construction from an unscaled coefficient; the |u| < 10^P
# invariant is the caller's contract, exactly as in zero-copy wire decode
@inline Base.reinterpret(::Type{Decimal{P, S, T}}, u::Integer) where {P, S, T <: StorageInt} =
    Decimal{P, S, T}(reinterpret, u)

const Decimal32{S} = Decimal{9, S, Int32}
const Decimal64{S} = Decimal{18, S, Int64}
const Decimal128{S} = Decimal{38, S, Int128}
const Decimal256{S} = Decimal{76, S, Int256}

struct DecimalValue{T <: StorageInt} <: AbstractDecimal
    unscaled::T
    scale::Int32
    @inline function DecimalValue{T}(u::Integer, scale::Integer) where {T <: StorageInt}
        0 <= scale <= 16383 ||
            throw(ArgumentError("DecimalValue scale must be in 0:16383, got $scale"))
        return new{T}(convert(T, u), scale % Int32)
    end
end

DecimalValue(u::T, scale::Integer) where {T <: StorageInt} = DecimalValue{T}(u, scale)
DecimalValue(u::Integer, scale::Integer) = DecimalValue{Int64}(u, scale)

# accessors
"""
    Decimals.unscaled(x) -> Integer

The unscaled coefficient of a decimal: `x == unscaled(x) * 10^-scale(x)`.
"""
@inline unscaled(x::Decimal) = x.unscaled
@inline unscaled(x::DecimalValue) = x.unscaled

"""
    Decimals.scale(x) -> Int

The scale (count of fractional decimal digits) of a decimal value.
"""
@inline scale(::Decimal{P, S}) where {P, S} = S
@inline scale(::Type{<:Decimal{P, S}}) where {P, S} = S
@inline scale(x::DecimalValue) = Int(x.scale)

@inline Base.precision(::Type{<:Decimal{P}}) where {P} = P
@inline Base.precision(::Decimal{P}) where {P} = P

@inline _storage(::Type{Decimal{P, S, T}}) where {P, S, T <: StorageInt} = T
@inline _storage(::Type{DecimalValue{T}}) where {T <: StorageInt} = T

# largest legal magnitude for the type: 10^P - 1, folded to a literal
@generated function _maxmag(::Type{Decimal{P, S, T}}) where {P, S, T <: StorageInt}
    return :($(_fromfullbig(_utype(T), big(10)^P - 1)))
end

@inline _mag(x::Decimal) = _mag(x.unscaled)
@inline _mag(x::DecimalValue) = _mag(x.unscaled)
@inline _isneg(x::Union{Decimal, DecimalValue}) = x.unscaled < 0

Base.zero(::Type{Decimal{P, S, T}}) where {P, S, T <: StorageInt} =
    reinterpret(Decimal{P, S, T}, zero(T))
Base.zero(::Type{DecimalValue{T}}) where {T <: StorageInt} = DecimalValue{T}(zero(T), 0)
Base.zero(x::AbstractDecimal) = zero(typeof(x))

function Base.one(::Type{Decimal{P, S, T}}) where {P, S, T <: StorageInt}
    S < P || throw(OverflowError("Decimal{$P,$S} cannot represent 1 (scale == precision)"))
    return reinterpret(Decimal{P, S, T}, T(_upow10(_utype(T), S)))
end
Base.one(::Type{DecimalValue{T}}) where {T <: StorageInt} = DecimalValue{T}(one(T), 0)
Base.one(x::AbstractDecimal) = one(typeof(x))

Base.typemax(::Type{Decimal{P, S, T}}) where {P, S, T <: StorageInt} =
    reinterpret(Decimal{P, S, T}, _maxmag(Decimal{P, S, T}) % T)
Base.typemin(::Type{Decimal{P, S, T}}) where {P, S, T <: StorageInt} =
    reinterpret(Decimal{P, S, T}, -(_maxmag(Decimal{P, S, T}) % T))

# smallest positive representable step
Base.eps(::Type{Decimal{P, S, T}}) where {P, S, T <: StorageInt} =
    reinterpret(Decimal{P, S, T}, one(T))
Base.eps(x::Decimal) = eps(typeof(x))

Base.widen(::Type{Decimal{P, S, T}}) where {P, S, T <: StorageInt} =
    Decimal{_capacity(_widen(T)), S, _widen(T)}
Base.widen(::Type{DecimalValue{T}}) where {T <: StorageInt} = DecimalValue{_widen(T)}

Base.signbit(x::AbstractDecimal) = x.unscaled < 0
Base.iszero(x::AbstractDecimal) = iszero(x.unscaled)
Base.isfinite(::AbstractDecimal) = true
Base.isnan(::AbstractDecimal) = false
Base.isinf(::AbstractDecimal) = false

Base.abs(x::Decimal{P, S, T}) where {P, S, T <: StorageInt} =
    reinterpret(Decimal{P, S, T}, abs(x.unscaled))
Base.abs(x::DecimalValue{T}) where {T <: StorageInt} = DecimalValue{T}(abs(x.unscaled), x.scale)

Base.:-(x::Decimal{P, S, T}) where {P, S, T <: StorageInt} =
    reinterpret(Decimal{P, S, T}, -x.unscaled)
Base.:-(x::DecimalValue{T}) where {T <: StorageInt} = DecimalValue{T}(-x.unscaled, x.scale)
Base.:+(x::AbstractDecimal) = x

function Base.isinteger(x::Decimal{P, S}) where {P, S}
    S == 0 && return true
    _, inexact = _scaledown(_mag(x), S, false, RoundToZero)
    return !inexact
end
function Base.isinteger(x::DecimalValue)
    x.scale == 0 && return true
    _, inexact = _scaledown(_mag(x), Int(x.scale), false, RoundToZero)
    return !inexact
end
