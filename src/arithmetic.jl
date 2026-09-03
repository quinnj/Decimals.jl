# Arithmetic. Semantics:
# - `+`/`-` promote both operands and compute at the promoted type; a result
#   that no longer fits throws OverflowError. No operation invents a type wider
#   than the promotion of its inputs, so folds are type-stable; `sum` is the
#   exception and widens one tier through Base.add_sum.
# - `*` is exact: scale S1+S2, precision min(P1+P2, 76), checked.
# - `/` rounds half-even at scale max(S1,S2); `divide(x, y, mode)` picks another
#   mode. There is no global rounding state.

@inline _add_ovf(x::T, y::T) where {T <: Union{Int32, Int64, Int128}} =
    Base.Checked.add_with_overflow(x, y)
@inline _sub_ovf(x::T, y::T) where {T <: Union{Int32, Int64, Int128}} =
    Base.Checked.sub_with_overflow(x, y)

@inline function _add_ovf(x::Int256, y::Int256)
    r = x + y
    return r, ((x >= 0) == (y >= 0)) & ((r >= 0) != (x >= 0))
end
@inline function _sub_ovf(x::Int256, y::Int256)
    r = x - y
    return r, ((x >= 0) != (y >= 0)) & ((r >= 0) != (x >= 0))
end

# Overflow messages are assembled by String concatenation: varargs `string` over
# mixed argument types, and `show` on a RoundingMode, are dynamic calls that
# `juliac --trim` rejects.
@inline _opstr(::RoundingMode{M}) where {M} = String(M)
@inline _opstr(x) = string(x)
@noinline _throwop(op, x, y) =
    throw(OverflowError(String(op) * "(" * _opstr(x) * ", " * _opstr(y) *
                        ") overflows result type"))

# When 3*maxmag fits the storage type, |x|,|y| <= maxmag means x ± y cannot
# wrap, so the only remaining check is the range one: (r + maxmag) taken as
# unsigned exceeds 2*maxmag exactly when |r| > maxmag, which is one add and one
# compare with no abs and no overflow flag. The two tiers whose maximum
# precision fills the storage type (Decimal32, Decimal128) fail the test and
# use the checked kernels below.
@inline _wrapfree(::Type{Decimal{P, S, T}}) where {P, S, T <: StorageInt} =
    _maxmag(Decimal{P, S, T}) <= typemax(T) ÷ 3
@inline function _outofrange(r::T, ::Type{Decimal{P, S, T}}) where {P, S, T <: StorageInt}
    mm = _maxmag(Decimal{P, S, T}) % _utype(T)
    return (r % _utype(T)) + mm > mm + mm
end

for (op, kernel) in ((:+, :_add_ovf), (:-, :_sub_ovf))
    @eval begin
        @inline function Base.$op(x::Decimal{P, S, T}, y::Decimal{P, S, T}) where {P, S, T <: StorageInt}
            if _wrapfree(Decimal{P, S, T})
                r = $op(x.unscaled, y.unscaled)
                _outofrange(r, Decimal{P, S, T}) && _throwop($(QuoteNode(op)), x, y)
                return reinterpret(Decimal{P, S, T}, r)
            end
            u, ovf = $kernel(x.unscaled, y.unscaled)
            (ovf || _mag(u) > _maxmag(Decimal{P, S, T})) && _throwop($(QuoteNode(op)), x, y)
            return reinterpret(Decimal{P, S, T}, u)
        end
        @inline function Base.$op(x::Decimal, y::Decimal)
            RT = promote_type(typeof(x), typeof(y))
            return $op(convert(RT, x), convert(RT, y))
        end
    end
end

# multiply result type: exact product parameters, capped at the 256-bit tier;
# @generated so the computed type is a compile-time constant for inference
@generated function _multype(::Type{Decimal{P1, S1, T1}},
                             ::Type{Decimal{P2, S2, T2}}) where {P1, S1, T1 <: StorageInt, P2, S2, T2 <: StorageInt}
    S = S1 + S2
    S <= 76 || return :(throw(ArgumentError(string("product scale ", $S1, "+", $S2,
                                                   " exceeds the maximum of 76"))))
    P = min(max(P1 + P2, S), 76)
    return :(Decimal{$P, $S, $(_storagetype(P))})
end

@inline function Base.:*(x::Decimal{P1, S1, T1},
                         y::Decimal{P2, S2, T2}) where {P1, S1, T1 <: StorageInt, P2, S2, T2 <: StorageInt}
    RT = _multype(Decimal{P1, S1, T1}, Decimal{P2, S2, T2})
    neg = _isneg(x) ⊻ _isneg(y)
    if sizeof(T1) <= 8 && sizeof(T2) <= 8
        m = widemul(_mag(x.unscaled) % UInt64, _mag(y.unscaled) % UInt64)
        m > UInt128(_maxmag(RT)) && _throwop(:*, x, y)
        u = (m % _utype(_storage(RT))) % _storage(RT)
        return reinterpret(RT, neg ? -u : u)
    elseif sizeof(T1) <= 16 && sizeof(T2) <= 16
        m = _widemul256(UInt128(_mag(x.unscaled)), UInt128(_mag(y.unscaled)))
        m > UInt256(_maxmag(RT)) && _throwop(:*, x, y)
        u = (m % _utype(_storage(RT))) % _storage(RT)
        return reinterpret(RT, neg ? -u : u)
    else
        hi, lo = _mul256full(_tomag256(x.unscaled), _tomag256(y.unscaled))
        (hi != zero(UInt256) || lo > UInt256(_maxmag(RT))) && _throwop(:*, x, y)
        u = (lo % _utype(_storage(RT))) % _storage(RT)
        return reinterpret(RT, neg ? -u : u)
    end
end

# division result type: worst-case integer digits of the true quotient
@generated function _divtype(::Type{Decimal{P1, S1, T1}},
                             ::Type{Decimal{P2, S2, T2}}) where {P1, S1, T1 <: StorageInt, P2, S2, T2 <: StorageInt}
    S = max(S1, S2)
    P = max(min(P1 - S1 + S2 + S, 76), S)
    return :(Decimal{$P, $S, $(_storagetype(P))})
end

# round(mag*10^k / d): the scaled dividend usually fits 256 bits; deep-scale
# operands spill into a 512-bit dividend handled by _divrem_512. Returns
# (q, ok); ok=false means the dividend or quotient exceeds any representable
# result (genuine overflow).
@inline function _scaledivround(mag::UInt256, k::Int, d::UInt256, neg::Bool,
                                mode::RoundingMode)
    n, ovf = _scaleup(mag, k)
    if !ovf
        q, _ = _divround(n, d, neg, mode)
        return (q, true)
    end
    return _scaledivround512(mag, k, d, neg, mode)
end

@noinline function _scaledivround512(mag::UInt256, k::Int, d::UInt256, neg::Bool,
                                     mode::RoundingMode)
    if k > 77
        m1, ovf1 = _scaleup(mag, k - 77)
        ovf1 && return (zero(UInt256), false)
        mag = m1
        k = 77
    end
    hi, lo = _mul256full(mag, _upow10(UInt256, k))
    hi >= d && return (zero(UInt256), false)  # quotient >= 2^256
    q, r = _divrem_512(hi, lo, d)
    r == zero(UInt256) && return (q, true)
    complement = d - r
    inc = _roundinc(r < complement, r == complement,
                    (q & one(UInt256)) != zero(UInt256), neg, mode)
    (inc && q == typemax(UInt256)) && return (q, false)
    return (inc ? q + one(UInt256) : q, true)
end

"""
    divide(x, y, mode=RoundNearest)

Divide two decimals, rounding the true quotient at scale `max(scale(x),
scale(y))` with `mode`. `x / y` is exactly `divide(x, y, RoundNearest)`
(half-even) — there is no global rounding state, so a different mode is always
an argument, never a context.

`mode` is any of `RoundNearest`, `RoundNearestTiesAway`, `RoundNearestTiesUp`,
`RoundToZero`, `RoundFromZero`, `RoundDown`, `RoundUp`. Dividing by zero throws
`DivideError`; a quotient too large for the result type throws `OverflowError`.
For `Decimal` operands the result type is derived from the operand parameters
(the widest quotient that can occur, capped at the 76-digit tier); for
[`DecimalValue`](@ref) operands it keeps the promoted storage type and the
runtime scale `max(scale(x), scale(y))`.

```jldoctest
julia> divide(Decimal64{2}("1.00"), Decimal64{2}("3.00"))
0.33

julia> divide(Decimal64{2}("1.00"), Decimal64{2}("3.00"), RoundUp)
0.34
```
"""
@inline function divide(x::Decimal{P1, S1, T1}, y::Decimal{P2, S2, T2},
                        mode::RoundingMode=RoundNearest) where {P1, S1, T1 <: StorageInt, P2, S2, T2 <: StorageInt}
    RT = _divtype(Decimal{P1, S1, T1}, Decimal{P2, S2, T2})
    iszero(y) && throw(DivideError())
    S = scale(RT)
    neg = _isneg(x) ⊻ _isneg(y)
    # quotient*10^S = u1*10^(S - S1 + S2) / u2
    q, ok = _scaledivround(_tomag256(x.unscaled), S - S1 + S2,
                           _tomag256(y.unscaled), neg, mode)
    (!ok || q > UInt256(_maxmag(RT))) && _throwop(:/, x, y)
    u = (q % _utype(_storage(RT))) % _storage(RT)
    return reinterpret(RT, neg ? -u : u)
end

Base.:/(x::Decimal, y::Decimal) = divide(x, y, RoundNearest)

# ---- integer quotient and remainder ----

@inline function _quotremround(n::UInt256, d::UInt256, xneg::Bool,
                               qneg::Bool, mode::RoundingMode)
    q, r = _divrem_wide(n, d)
    r == zero(UInt256) && return (q, r, false)
    complement = d - r
    inc = _roundinc(r < complement, r == complement,
                    isodd(q), qneg, mode)
    return (inc ? q + one(UInt256) : q,
            inc ? complement : r,
            inc ? !xneg : xneg)
end

@inline function _decimalparts(x::D, y::D,
                               mode::RoundingMode) where {D <: Decimal}
    iszero(y) && throw(DivideError())
    xneg = _isneg(x)
    qneg = xneg ⊻ _isneg(y)
    q, r, rneg = _quotremround(_tomag256(x.unscaled),
                               _tomag256(y.unscaled), xneg, qneg, mode)
    return q, qneg, r, rneg
end

@inline function _decimalquotient(::Type{D}, q::UInt256, qneg::Bool,
                                  x, y) where {D <: Decimal}
    qscaled, ovf = _scaleup(q, scale(D))
    (ovf || qscaled > UInt256(_maxmag(D))) && _throwop(:div, x, y)
    return _fromuval(D, qscaled, qneg, x)
end

@inline function _decimaldivrem(x::D, y::D,
                                mode::RoundingMode) where {D <: Decimal}
    q, qneg, r, rneg = _decimalparts(x, y, mode)
    quotient = _decimalquotient(D, q, qneg, x, y)
    return quotient, _fromuval(D, r, rneg, x)
end

@inline function _decimalremainder(x::D, y::D,
                                   mode::RoundingMode) where {D <: Decimal}
    _, _, r, rneg = _decimalparts(x, y, mode)
    return _fromuval(D, r, rneg, x)
end

@inline function Base.div(x::D, y::D,
                          mode::RoundingMode) where {D <: Decimal}
    q, qneg, _, _ = _decimalparts(x, y, mode)
    return _decimalquotient(D, q, qneg, x, y)
end

@inline Base.fld(x::D, y::D) where {D <: Decimal} = div(x, y, RoundDown)
@inline Base.cld(x::D, y::D) where {D <: Decimal} = div(x, y, RoundUp)
Base.rem(x::D, y::D) where {D <: Decimal} = _decimalremainder(x, y, RoundToZero)

for mode in (RoundNearest, RoundNearestTiesAway, RoundNearestTiesUp,
             RoundToZero, RoundFromZero, RoundDown, RoundUp)
    MT = typeof(mode)
    @eval begin
        @inline Base.rem(x::D, y::D, ::$MT) where {D <: Decimal} =
            _decimalremainder(x, y, $mode)
        @inline Base.divrem(x::D, y::D, ::$MT) where {D <: Decimal} =
            _decimaldivrem(x, y, $mode)
    end
end

Base.rem(x::AbstractDecimal, y::AbstractDecimal) = rem(promote(x, y)...)
Base.rem(x::AbstractDecimal, y::Real) = rem(promote(x, y)...)
Base.rem(x::Real, y::AbstractDecimal) = rem(promote(x, y)...)

for mode in (RoundNearest, RoundNearestTiesAway, RoundNearestTiesUp,
             RoundToZero, RoundFromZero, RoundDown, RoundUp)
    MT = typeof(mode)
    @eval begin
        Base.rem(x::AbstractDecimal, y::AbstractDecimal, ::$MT) =
            rem(promote(x, y)..., $mode)
        Base.rem(x::AbstractDecimal, y::Real, ::$MT) = rem(promote(x, y)..., $mode)
        Base.rem(x::Real, y::AbstractDecimal, ::$MT) = rem(promote(x, y)..., $mode)
    end
end

Base.mod(x::AbstractDecimal, y::AbstractDecimal) = rem(x, y, RoundDown)
Base.mod(x::AbstractDecimal, y::Real) = rem(x, y, RoundDown)
Base.mod(x::Real, y::AbstractDecimal) = rem(x, y, RoundDown)

# scale-preserving multiply by a machine integer (multiplying by an integer
# should not widen the scale the way promotion-based multiply would)
const _MulInt = Union{Base.BitInteger, Int256, UInt256}

@generated function _mulinttype(::Type{Decimal{P, S, T}}, ::Type{I}) where {P, S, T <: StorageInt, I}
    P2 = min(P + _intdigits(I), 76)
    return :(Decimal{$P2, $S, $(_storagetype(P2))})
end

@inline function Base.:*(x::Decimal{P, S, T}, y::_MulInt) where {P, S, T <: StorageInt}
    RT = _mulinttype(Decimal{P, S, T}, typeof(y))
    neg = _isneg(x) ⊻ (y < zero(y))
    if sizeof(T) <= 8 && sizeof(y) <= 8
        m = widemul(_mag(x.unscaled) % UInt64, (_tomag256(y) % UInt64))
        m > UInt128(_maxmag(RT)) && _throwop(:*, x, y)
        u = (m % _utype(_storage(RT))) % _storage(RT)
        return reinterpret(RT, neg ? -u : u)
    end
    hi, lo = _mul256full(_tomag256(x.unscaled), _tomag256(y))
    (hi != zero(UInt256) || lo > UInt256(_maxmag(RT))) && _throwop(:*, x, y)
    u = (lo % _utype(_storage(RT))) % _storage(RT)
    return reinterpret(RT, neg ? -u : u)
end
Base.:*(y::_MulInt, x::Decimal) = x * y

function Base.:*(x::Decimal{P, S}, y::BigInt) where {P, S}
    RT = Decimal{76, S, Int256}
    product = _tobigsigned(x.unscaled) * y
    abs(product) > _tobig(UInt256(_maxmag(RT))) && _throwop(:*, x, y)
    return reinterpret(RT, convert(Int256, product))
end
Base.:*(y::BigInt, x::Decimal) = x * y

function Base.:*(x::DecimalValue{T}, y::_MulInt) where {T <: StorageInt}
    neg = _isneg(x) ⊻ (y < zero(y))
    hi, lo = _mul256full(_tomag256(x.unscaled), _tomag256(y))
    (hi != zero(UInt256) || !_fitsigned(lo, neg, T)) && _throwvalop(:*)
    u = (lo % _utype(T)) % T
    return DecimalValue{T}(neg ? -u : u, x.scale)
end
Base.:*(y::_MulInt, x::DecimalValue) = x * y

function Base.:*(x::DecimalValue{T}, y::BigInt) where {T <: StorageInt}
    product = _tobigsigned(x.unscaled) * y
    lo = _tobigsigned(typemin(T))
    hi = _tobigsigned(typemax(T))
    (product < lo || product > hi) && _throwvalop(:*)
    return DecimalValue{T}(convert(T, product), x.scale)
end
Base.:*(y::BigInt, x::DecimalValue) = x * y

# ---- round/trunc/floor/ceil within the type ----

# number of digits to drop, saturating instead of overflowing on huge `digits`
@inline function _roundshift(s::Int, digits::Integer)
    digits < s - typemax(Int) && return typemax(Int)
    return s - Int(digits)
end

function Base.round(x::Decimal{P, S, T}, mode::RoundingMode=RoundNearest;
                    digits::Integer=0) where {P, S, T <: StorageInt}
    digits >= S && return x
    k = _roundshift(S, digits)
    neg = _isneg(x)
    q, _ = _scaledown(_mag(x), k, neg, mode)
    mag, ovf = _scaleup(q, k)
    (ovf || mag > _maxmag(Decimal{P, S, T})) && _throwop(:round, x, mode)
    u = (mag % _utype(T)) % T
    return reinterpret(Decimal{P, S, T}, neg ? -u : u)
end

Base.trunc(x::Decimal; digits::Integer=0) = round(x, RoundToZero; digits)
Base.floor(x::Decimal; digits::Integer=0) = round(x, RoundDown; digits)
Base.ceil(x::Decimal; digits::Integer=0) = round(x, RoundUp; digits)

function Base.round(x::DecimalValue{T}, mode::RoundingMode=RoundNearest;
                    digits::Integer=0) where {T <: StorageInt}
    digits >= scale(x) && return x
    k = _roundshift(scale(x), digits)
    neg = _isneg(x)
    q, _ = _scaledown(_tomag256(x.unscaled), k, neg, mode)
    mag, ovf = _scaleup(q, k)
    (ovf || !_fitsigned(mag, neg, T)) && _throwvalop(:round)
    u = (mag % _utype(T)) % T
    return DecimalValue{T}(neg ? -u : u, x.scale)
end

Base.trunc(x::DecimalValue; digits::Integer=0) = round(x, RoundToZero; digits)
Base.floor(x::DecimalValue; digits::Integer=0) = round(x, RoundDown; digits)
Base.ceil(x::DecimalValue; digits::Integer=0) = round(x, RoundUp; digits)

# ---- sum: accumulate one tier wider ----

_sumtype(::Type{Decimal{P, S, T}}) where {P, S, T <: Union{Int32, Int64}} =
    Decimal{38, S, Int128}
_sumtype(::Type{Decimal{P, S, Int128}}) where {P, S} = Decimal{76, S, Int256}
_sumtype(::Type{Decimal{P, S, Int256}}) where {P, S} = Decimal{P, S, Int256}

# widening a tier (Int32/Int64 -> Int128, Int128 -> Int256) is a sign-extension
# of the unscaled value at the same scale, so it preserves the invariant and
# needs no check
@inline _sumwiden(x::Decimal{P, S, T}) where {P, S, T <: Union{Int32, Int64}} =
    reinterpret(Decimal{38, S, Int128}, Int128(x.unscaled))
@inline _sumwiden(x::Decimal{P, S, Int128}) where {P, S} =
    reinterpret(Decimal{76, S, Int256}, Int256(x.unscaled))
@inline _sumwiden(x::Decimal{P, S, Int256}) where {P, S} = x

Base.add_sum(x::Decimal, y::Decimal) = _sumwiden(x) + _sumwiden(y)
Base.reduce_first(::typeof(Base.add_sum), x::Decimal) = _sumwiden(x)
Base.reduce_empty(::typeof(Base.add_sum), ::Type{D}) where {D <: Decimal} =
    zero(_sumtype(D))

# Narrow-tier columnar sum: every |unscaled| < 10^18, so an Int128 accumulator
# cannot overflow below 1.7e20 elements; the adds need no check and the loop
# vectorizes. Int128-tier arrays keep the checked add_sum path.
function Base.sum(v::AbstractArray{Decimal{P, S, T}};
                  dims=:, init=nothing) where {P, S, T <: Union{Int32, Int64}}
    (dims === (:) && init === nothing) ||
        return Base._sum(v, dims; (init === nothing ? (;) : (; init))...)
    s = zero(Int128)
    @inbounds @simd for i in eachindex(v)
        s += Int128(v[i].unscaled)
    end
    return reinterpret(Decimal{38, S, Int128}, s)
end

# at a fixed scale the coefficients order exactly as the values do, so min/max
# reduce to Base's integer reductions over the reinterpreted array; keyword
# forms and empty arrays fall back to the generic element-wise reduction
for (f, op) in ((:maximum, :max), (:minimum, :min))
    @eval function Base.$f(v::Array{Decimal{P, S, T}}; kw...) where {P, S, T <: StorageInt}
        (isempty(kw) && !isempty(v)) || return Base.mapreduce(identity, $op, v; kw...)
        return reinterpret(Decimal{P, S, T}, $f(reinterpret(T, v)))
    end
end

# ---- DecimalValue arithmetic (runtime scales) ----

@noinline _throwvalop(op) =
    throw(OverflowError(string(op, " overflows the DecimalValue storage type")))

function _valaligned(x::DecimalValue{T}, y::DecimalValue{T}) where {T <: StorageInt}
    sx, sy = scale(x), scale(y)
    s = max(sx, sy)
    ux, uy = x.unscaled, y.unscaled
    if sx < s
        ux, ovf = _scaleup(ux, s - sx)
        ovf && _throwvalop(:align)
    elseif sy < s
        uy, ovf = _scaleup(uy, s - sy)
        ovf && _throwvalop(:align)
    end
    return ux, uy, s
end

for (op, kernel) in ((:+, :_add_ovf), (:-, :_sub_ovf))
    @eval begin
        function Base.$op(x::DecimalValue{T}, y::DecimalValue{T}) where {T <: StorageInt}
            ux, uy, s = _valaligned(x, y)
            u, ovf = $kernel(ux, uy)
            ovf && _throwvalop($(QuoteNode(op)))
            return DecimalValue{T}(u, s)
        end
        Base.$op(x::DecimalValue, y::DecimalValue) = $op(promote(x, y)...)
    end
end

function Base.:*(x::DecimalValue{T}, y::DecimalValue{T}) where {T <: StorageInt}
    s = scale(x) + scale(y)
    s <= 16383 || _throwvalop(:*)
    neg = _isneg(x) ⊻ _isneg(y)
    hi, lo = _mul256full(_tomag256(x.unscaled), _tomag256(y.unscaled))
    (hi != zero(UInt256) || !_fitsigned(lo, neg, T)) && _throwvalop(:*)
    u = (lo % _utype(T)) % T
    return DecimalValue{T}(neg ? -u : u, s)
end
Base.:*(x::DecimalValue, y::DecimalValue) = *(promote(x, y)...)

function divide(x::DecimalValue{T}, y::DecimalValue{T},
                mode::RoundingMode=RoundNearest) where {T <: StorageInt}
    iszero(y) && throw(DivideError())
    s = max(scale(x), scale(y))
    neg = _isneg(x) ⊻ _isneg(y)
    q, ok = _scaledivround(_tomag256(x.unscaled), s - scale(x) + scale(y),
                           _tomag256(y.unscaled), neg, mode)
    (!ok || !_fitsigned(q, neg, T)) && _throwvalop(:/)
    u = (q % _utype(T)) % T
    return DecimalValue{T}(neg ? -u : u, s)
end
divide(x::DecimalValue, y::DecimalValue, mode::RoundingMode=RoundNearest) =
    divide(promote(x, y)..., mode)

@inline function _valueparts(x::DecimalValue{T}, y::DecimalValue{T},
                             mode::RoundingMode) where {T <: StorageInt}
    iszero(y) && throw(DivideError())
    s = max(scale(x), scale(y))
    xm, xovf = _scaleup(_tomag256(x.unscaled), s - scale(x))
    ym, yovf = _scaleup(_tomag256(y.unscaled), s - scale(y))
    (xovf || yovf) && return _valueparts_big(x, y, mode, s)
    qneg = _isneg(x) ⊻ _isneg(y)
    q, r, rneg = _quotremround(xm, ym, _isneg(x), qneg, mode)
    return q, r, rneg, s
end

@noinline function _valueparts_big(x::DecimalValue, y::DecimalValue,
                                   mode::RoundingMode, s::Int)
    xm = abs(_tobigsigned(x.unscaled)) * big(10)^(s - scale(x))
    ym = abs(_tobigsigned(y.unscaled)) * big(10)^(s - scale(y))
    q, r = divrem(xm, ym)
    iszero(r) && return (q, r, false, s)
    qneg = _isneg(x) ⊻ _isneg(y)
    complement = ym - r
    inc = _roundinc(r < complement, r == complement, isodd(q), qneg, mode)
    return (inc ? q + 1 : q,
            inc ? complement : r,
            inc ? !_isneg(x) : _isneg(x),
            s)
end

@inline function _valuefrommag(::Type{T}, mag::UInt256, neg::Bool,
                               s::Int) where {T <: StorageInt}
    !_fitsigned(mag, neg, T) && _throwvalop(:rem)
    u = (mag % _utype(T)) % T
    return DecimalValue{T}(neg ? -u : u, s)
end

@noinline function _valuefrommag(::Type{T}, mag::BigInt, neg::Bool,
                                 s::Int) where {T <: StorageInt}
    limit = neg ? -_tobigsigned(typemin(T)) : _tobigsigned(typemax(T))
    mag > limit && _throwvalop(:rem)
    u = convert(T, neg ? -mag : mag)
    return DecimalValue{T}(u, s)
end

@inline function _valuequotient(::Type{T}, q::UInt256, neg::Bool,
                                s::Int) where {T <: StorageInt}
    mag, ovf = _scaleup(q, s)
    (ovf || !_fitsigned(mag, neg, T)) && _throwvalop(:div)
    u = (mag % _utype(T)) % T
    return DecimalValue{T}(neg ? -u : u, s)
end

@noinline function _valuequotient(::Type{T}, q::BigInt, neg::Bool,
                                  s::Int) where {T <: StorageInt}
    iszero(q) && return DecimalValue{T}(0, s)
    mag = q * big(10)^s
    limit = neg ? -_tobigsigned(typemin(T)) : _tobigsigned(typemax(T))
    mag > limit && _throwvalop(:div)
    u = convert(T, neg ? -mag : mag)
    return DecimalValue{T}(u, s)
end

@inline function _valuedivrem(x::DecimalValue{T}, y::DecimalValue{T},
                              mode::RoundingMode) where {T <: StorageInt}
    q, r, rneg, s = _valueparts(x, y, mode)
    quotient = _valuequotient(T, q, _isneg(x) ⊻ _isneg(y), s)
    remainder = _valuefrommag(T, r, rneg, s)
    return quotient, remainder
end

@inline function _valueremainder(x::DecimalValue{T}, y::DecimalValue{T},
                                 mode::RoundingMode) where {T <: StorageInt}
    _, r, rneg, s = _valueparts(x, y, mode)
    return _valuefrommag(T, r, rneg, s)
end

@inline function _valuequotient(x::DecimalValue{T}, y::DecimalValue{T},
                                mode::RoundingMode) where {T <: StorageInt}
    q, _, _, s = _valueparts(x, y, mode)
    return _valuequotient(T, q, _isneg(x) ⊻ _isneg(y), s)
end

@inline Base.div(x::DecimalValue{T}, y::DecimalValue{T},
                 mode::RoundingMode) where {T <: StorageInt} =
    _valuequotient(x, y, mode)
@inline Base.fld(x::DecimalValue{T}, y::DecimalValue{T}) where {T <: StorageInt} =
    div(x, y, RoundDown)
@inline Base.cld(x::DecimalValue{T}, y::DecimalValue{T}) where {T <: StorageInt} =
    div(x, y, RoundUp)
Base.rem(x::DecimalValue{T}, y::DecimalValue{T}) where {T <: StorageInt} =
    _valueremainder(x, y, RoundToZero)

for mode in (RoundNearest, RoundNearestTiesAway, RoundNearestTiesUp,
             RoundToZero, RoundFromZero, RoundDown, RoundUp)
    MT = typeof(mode)
    @eval begin
        @inline Base.rem(x::DecimalValue{T}, y::DecimalValue{T},
                         ::$MT) where {T <: StorageInt} =
            _valueremainder(x, y, $mode)
        @inline Base.divrem(x::DecimalValue{T}, y::DecimalValue{T},
                            ::$MT) where {T <: StorageInt} =
            _valuedivrem(x, y, $mode)
    end
end

Base.:/(x::DecimalValue, y::DecimalValue) = divide(x, y, RoundNearest)

divide(x::Decimal, y::DecimalValue, mode::RoundingMode=RoundNearest) =
    divide(promote(x, y)..., mode)
divide(x::DecimalValue, y::Decimal, mode::RoundingMode=RoundNearest) =
    divide(promote(x, y)..., mode)

# ---- Base.Checked aliases ----

# Arithmetic is already checked (throws on overflow); the explicit names let
# generic checked-arithmetic code find these types.
Base.Checked.checked_add(x::AbstractDecimal, y::AbstractDecimal) = x + y
Base.Checked.checked_sub(x::AbstractDecimal, y::AbstractDecimal) = x - y
Base.Checked.checked_mul(x::AbstractDecimal, y::AbstractDecimal) = x * y
Base.Checked.checked_neg(x::AbstractDecimal) = -x
Base.Checked.checked_abs(x::AbstractDecimal) = abs(x)
