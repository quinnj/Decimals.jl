# The two public value types, both exact: value == unscaled * 10^-scale.
# `Decimal{P,S,T}` carries precision and scale as type parameters, so a
# Vector{Decimal{P,S,T}} is byte-identical to an Arrow/Parquet/DuckDB decimal
# buffer; `DecimalValue{T}` carries the scale per value, as row-oriented wire
# formats do (a PostgreSQL numeric's dscale).

"""
    Decimals.AbstractDecimal <: Real

Supertype of the package's exact decimal types, [`Decimal`](@ref) (scale fixed
in the type) and [`DecimalValue`](@ref) (scale carried per value). Every
`AbstractDecimal` is an exact rational of the form `unscaled(x) * 10^-scale(x)`;
there are no `NaN` or `Inf` values, so `isfinite` is always `true` and `isnan`
always `false`.
"""
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
_widen(::Type{Int256}) = Int256

# fold parameter validation to a compile-time constant
@generated function _checkdecparams(::Val{P}, ::Val{S}, ::Type{T}) where {P, S, T}
    ok = P isa Int && S isa Int && T <: StorageInt &&
         1 <= P <= _capacity(T) && 0 <= S <= P
    ok && return :(nothing)
    return :(throw(ArgumentError(string("invalid Decimal parameters: precision must be ",
        "an Int in 1:capacity(T) (9/18/38/76 for Int32/Int64/Int128/Int256), ",
        "scale an Int in 0:precision; got Decimal{", $P, ",", $S, ",", $T, "}"))))
end

"""
    Decimal{P, S, T} <: Decimals.AbstractDecimal
    Decimal{P, S}

An exact fixed-scale decimal: the value is `unscaled * 10^-S`, with the
invariant `|unscaled| < 10^P`. `P` is the precision (total decimal digits), `S`
the scale (fractional digits, `0 <= S <= P`), and `T` the storage integer —
`Int32`, `Int64`, `Int128`, or `Decimals.Int256` for `P` up to 9, 18, 38, or 76
respectively. Writing `Decimal{P,S}` fills `T` in from `P`.

The struct holds nothing but the storage integer, so `Vector{Decimal{P,S,T}}`
is byte-identical to an Arrow/Parquet/DuckDB decimal buffer of the same
precision and scale. See [`Decimal64`](@ref) and its siblings for the aliases
naming those tiers.

Constructors are exact or they throw: `Decimal{18,2}(5)`,
`Decimal{18,2}(1//4)`, and `convert` raise `InexactError`/`OverflowError`
rather than round. The exceptions are construction from `AbstractFloat`, which
rounds half-even at scale `S` like every cross-representation float conversion
in Base, and construction from a string, which is `parse` (also half-even).
[`rescale`](@ref) and `round(D, x, mode)` are the explicitly-rounding forms.

`reinterpret(Decimal{P,S,T}, u)` builds a value straight from an unscaled
coefficient without checking the `|u| < 10^P` invariant — the zero-copy wire
decode path, where the invariant is the caller's contract.

```jldoctest
julia> Decimal{18,2}("1234.56")
1234.56

julia> Decimal{18,2}(5) === reinterpret(Decimal{18,2,Int64}, 500)
true
```

Values display as plain digits; `repr`/`show` give the round-trippable typed
form `Decimal{18,2,Int64}("1234.56")`.
"""
struct Decimal{P, S, T <: StorageInt} <: AbstractDecimal
    unscaled::T
    @inline function Decimal{P, S, T}(::typeof(reinterpret), u::Integer) where {P, S, T <: StorageInt}
        _checkdecparams(Val(P), Val(S), T)
        return new{P, S, T}(u % T)
    end
end

# unchecked construction from an unscaled coefficient: the |u| < 10^P invariant
# is the caller's contract, as it is for a zero-copy wire decode
@inline Base.reinterpret(::Type{Decimal{P, S, T}}, u::Integer) where {P, S, T <: StorageInt} =
    Decimal{P, S, T}(reinterpret, u)

"""
    Decimal32{S}

Alias for `Decimal{9,S,Int32}` — the widest precision the 32-bit storage tier
holds. See [`Decimal64`](@ref) for the family.
"""
const Decimal32{S} = Decimal{9, S, Int32}

"""
    Decimal64{S}
    Decimal32{S}
    Decimal128{S}
    Decimal256{S}

Aliases for the four storage tiers at their maximum precision, matching the
decimal widths of Arrow, Parquet, and DuckDB:

| alias | expands to | digits | bits |
|---|---|---|---|
| `Decimal32{S}` | `Decimal{9,S,Int32}` | 9 | 32 |
| `Decimal64{S}` | `Decimal{18,S,Int64}` | 18 | 64 |
| `Decimal128{S}` | `Decimal{38,S,Int128}` | 38 | 128 |
| `Decimal256{S}` | `Decimal{76,S,Decimals.Int256}` | 76 | 256 |

`S` is the scale, so `Decimal64{2}` is the usual money type. Use
`Decimal{P,S}` directly when a schema pins a precision narrower than the tier's
maximum.

```jldoctest
julia> Decimal64{2} === Decimal{18,2,Int64}
true
```
"""
const Decimal64{S} = Decimal{18, S, Int64}

"""
    Decimal128{S}

Alias for `Decimal{38,S,Int128}`. See [`Decimal64`](@ref) for the family.
"""
const Decimal128{S} = Decimal{38, S, Int128}

"""
    Decimal256{S}

Alias for `Decimal{76,S,Decimals.Int256}`, the widest tier. See
[`Decimal64`](@ref) for the family.
"""
const Decimal256{S} = Decimal{76, S, Int256}

"""
    DecimalValue{T} <: Decimals.AbstractDecimal
    DecimalValue(unscaled, scale)

An exact decimal whose scale travels with the value instead of with the type:
`unscaled * 10^-scale`, where `scale` is an `Int32` in `0:16383`. `T` is the
storage integer (`Int32`, `Int64`, `Int128`, or `Decimals.Int256`); the bare
`DecimalValue(u, s)` constructor infers it from `u`, defaulting to `Int64`.

This is the type for row-oriented wire values that carry their own scale — a
PostgreSQL `numeric`'s per-value `dscale`, or the output of
[`normalize`](@ref) — and for values whose scale is not known until runtime.
It is still isbits, but it is one word wider than [`Decimal`](@ref) and its
arithmetic aligns scales at run time rather than at compile time, so prefer
`Decimal{P,S}` for columnar data.

Like `Decimal`, conversions in are exact-or-throw except from `AbstractFloat`,
where `DecimalValue(x)` produces the *exact* binary expansion of `x` (that is
what a runtime scale is for) rather than rounding to a fixed scale.
[`rescale`](@ref) moves a value to another scale.

```jldoctest
julia> DecimalValue(12345, 3)
12.345

julia> repr(DecimalValue(0.1))
"DecimalValue{Decimals.Int256}(\\"0.1000000000000000055511151231257827021181583404541015625\\")"
```
"""
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

The unscaled coefficient of a decimal: `x == unscaled(x) * 10^-scale(x)`. The
returned integer is the value's storage type, and is exactly the coefficient an
Arrow/Parquet/DuckDB buffer stores. `reinterpret(typeof(x), unscaled(x))`
rebuilds `x`.
"""
@inline unscaled(x::Decimal) = x.unscaled
@inline unscaled(x::DecimalValue) = x.unscaled

"""
    Decimals.scale(x) -> Int
    Decimals.scale(::Type{<:Decimal}) -> Int

The scale (count of fractional decimal digits) of a decimal value: the `S`
parameter for a [`Decimal`](@ref), the stored per-value scale for a
[`DecimalValue`](@ref). The companion precision is `Base.precision`, which is
defined for `Decimal` types only. `scale` accepts a `Decimal` *type* as well as
a value, since the scale is a type parameter there.
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
Base.eps(x::DecimalValue{T}) where {T <: StorageInt} = DecimalValue{T}(one(T), x.scale)

Base.floatmin(::Type{D}) where {D <: Decimal} = eps(D)
Base.floatmax(::Type{D}) where {D <: Decimal} = typemax(D)

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
function Base.abs(x::DecimalValue{T}) where {T <: StorageInt}
    x.unscaled == typemin(T) && throw(OverflowError("abs overflows DecimalValue{$T}"))
    return DecimalValue{T}(abs(x.unscaled), x.scale)
end

Base.:-(x::Decimal{P, S, T}) where {P, S, T <: StorageInt} =
    reinterpret(Decimal{P, S, T}, -x.unscaled)
function Base.:-(x::DecimalValue{T}) where {T <: StorageInt}
    x.unscaled == typemin(T) && throw(OverflowError("- overflows DecimalValue{$T}"))
    return DecimalValue{T}(-x.unscaled, x.scale)
end
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
