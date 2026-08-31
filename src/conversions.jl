# Conversions between decimal types and Integer/Rational/AbstractFloat, plus
# promotion rules. Contract: constructors/`convert` are exact (throwing
# InexactError/OverflowError), except from AbstractFloat, which — like every
# cross-representation float conversion in Base — rounds to the nearest
# representable value (half-even) at the target scale. `round(T, x, mode)`
# is the explicitly-rounding conversion for every source type.

# round an already-scaled UInt256 magnitude by an arbitrary divisor, with mode
@inline function _divround(n::UInt256, d::UInt256, neg::Bool, mode::RoundingMode)
    q, r = _divrem_wide(n, d)
    r == zero(UInt256) && return (q, false)
    complement = d - r
    inc = _roundinc(r < complement, r == complement,
                    (q & one(UInt256)) != zero(UInt256), neg, mode)
    return (inc ? q + one(UInt256) : q, true)
end

@noinline _throwoverflow(DT, x) =
    throw(OverflowError(string(x, " does not fit in ", DT)))
@noinline _throwinexact(DT, x) =
    throw(InexactError(:convert, DT, x))

# finish a Decimal construction from a UInt256 magnitude
@inline function _fromuval(::Type{Decimal{P, S, T}}, mag::UInt256, neg::Bool,
                           x) where {P, S, T <: StorageInt}
    mag > UInt256(_maxmag(Decimal{P, S, T})) && _throwoverflow(Decimal{P, S, T}, x)
    u = (mag % _utype(T)) % T
    return reinterpret(Decimal{P, S, T}, neg ? -u : u)
end

# ---- Integer -> Decimal ----

function Decimal{P, S, T}(x::Integer) where {P, S, T <: StorageInt}
    neg = x < zero(x)
    xm = _tomag256(x)
    mag, ovf = _scaleup(xm, S)
    ovf && _throwoverflow(Decimal{P, S, T}, x)
    return _fromuval(Decimal{P, S, T}, mag, neg, x)
end
Decimal{P, S, T}(x::Bool) where {P, S, T <: StorageInt} = Decimal{P, S, T}(Int(x))

# magnitude of any integer as UInt256
@inline _tomag256(x::Union{Int8, Int16, Int32, Int64}) = UInt256(_mag(Int64(x)))
@inline _tomag256(x::Int128) = UInt256(_mag(x))
@inline _tomag256(x::Int256) = _mag(x)
@inline _tomag256(x::Union{Bool, UInt8, UInt16, UInt32, UInt64, UInt128}) = UInt256(x)
@inline _tomag256(x::UInt256) = x
@noinline function _tomag256(x::BigInt)
    m = abs(x)
    m > _tobig(typemax(UInt256)) && throw(InexactError(:convert, UInt256, x))
    return _fromfullbig(UInt256, m)
end

function Decimal{P, S, T}(x::BigInt) where {P, S, T <: StorageInt}
    mag = abs(x) * big(10)^S
    mag > _tobig(UInt256(_maxmag(Decimal{P, S, T}))) &&
        _throwoverflow(Decimal{P, S, T}, x)
    return _fromuval(Decimal{P, S, T}, _fromfullbig(UInt256, mag), x < 0, x)
end

# ---- Rational -> Decimal ----

function _fromrational(::Type{Decimal{P, S, T}}, x::Rational, mode) where {P, S, T <: StorageInt}
    iszero(x.den) && _throwinexact(Decimal{P, S, T}, x)
    neg = x.num < zero(x.num)
    n = _tomag256(x.num)
    d = _tomag256(x.den)
    num, ovf = _scaleup(n, S)
    ovf && return _fromrational_big(Decimal{P, S, T}, x, mode)
    q, inexact = _divround(num, d, neg, mode)
    (inexact && mode === nothing) && _throwinexact(Decimal{P, S, T}, x)
    return _fromuval(Decimal{P, S, T}, q, neg, x)
end

@noinline function _fromrational_big(::Type{Decimal{P, S, T}}, x::Rational,
                                     mode) where {P, S, T <: StorageInt}
    num = abs(_tobigsigned(x.num)) * big(10)^S
    den = abs(_tobigsigned(x.den))
    q, r = divrem(num, den)
    if r != 0
        mode === nothing && _throwinexact(Decimal{P, S, T}, x)
        neg = x.num < zero(x.num)
        inc = _roundinc(2r < den, 2r == den, isodd(q), neg, mode)
        inc && (q += 1)
    end
    q > _tobig(UInt256(_maxmag(Decimal{P, S, T}))) && _throwoverflow(Decimal{P, S, T}, x)
    return _fromuval(Decimal{P, S, T}, _fromfullbig(UInt256, q), x.num < zero(x.num), x)
end

Decimal{P, S, T}(x::Rational) where {P, S, T <: StorageInt} =
    _fromrational(Decimal{P, S, T}, x, nothing)
Decimal{P, S, T}(x::Rational{BigInt}) where {P, S, T <: StorageInt} =
    _fromrational_big(Decimal{P, S, T}, x, nothing)

# _divround with mode === nothing means "must be exact"
@inline function _divround(n::UInt256, d::UInt256, neg::Bool, ::Nothing)
    q, r = _divrem_wide(n, d)
    return (q, r != zero(UInt256))
end

# ---- AbstractFloat -> Decimal ----

function _fromfloat(::Type{Decimal{P, S, T}}, x::AbstractFloat,
                    mode::RoundingMode) where {P, S, T <: StorageInt}
    isfinite(x) || _throwinexact(Decimal{P, S, T}, x)
    iszero(x) && return zero(Decimal{P, S, T})
    num, pow, den = Base.decompose(x)  # x == num * 2^pow / den, den == ±1
    num isa BigInt && return _fromfloat_big(Decimal{P, S, T}, x, mode)
    neg = (num < 0) ⊻ (den < 0)
    m = _tomag256(abs(num))
    if pow >= 0
        pow > 255 && _throwoverflow(Decimal{P, S, T}, x)
        lz = leading_zeros(m)
        pow > lz && _throwoverflow(Decimal{P, S, T}, x)
        mag, ovf = _scaleup(m << pow, S)
        ovf && _throwoverflow(Decimal{P, S, T}, x)
        return _fromuval(Decimal{P, S, T}, mag, neg, x)
    end
    k = -pow
    if k <= S
        # exact: u = m * 5^k * 10^(S-k)
        k > 110 && return _fromfloat_big(Decimal{P, S, T}, x, mode)
        p5 = _upow5_256(k)
        hi, lo = _mul256full(m, p5)
        hi != zero(UInt256) && _throwoverflow(Decimal{P, S, T}, x)
        mag, ovf = _scaleup(lo, S - k)
        ovf && _throwoverflow(Decimal{P, S, T}, x)
        return _fromuval(Decimal{P, S, T}, mag, neg, x)
    end
    k > 87 && return _fromfloat_big(Decimal{P, S, T}, x, mode)
    # u = round(m * 5^k / 10^(k-S)); m*5^k fits 256 bits for k <= 87 (m < 2^53)
    hi, lo = _mul256full(m, _upow5_256(k))
    hi != zero(UInt256) && _throwoverflow(Decimal{P, S, T}, x)
    q, _ = _scaledown(lo, k - S, neg, mode)
    return _fromuval(Decimal{P, S, T}, q, neg, x)
end

@noinline function _fromfloat_big(::Type{Decimal{P, S, T}}, x::AbstractFloat,
                                  mode::RoundingMode) where {P, S, T <: StorageInt}
    num, pow, den = Base.decompose(x)
    neg = (num < 0) ⊻ (den < 0)
    m = big(abs(num))
    if pow >= 0
        mag = (m << pow) * big(10)^S
    else
        k = -pow
        if k <= S
            mag = m * big(5)^k * big(10)^(S - k)
        else
            n = m * big(5)^k
            d = big(10)^(k - S)
            q, r = divrem(n, d)
            if r != 0
                inc = _roundinc(2r < d, 2r == d, isodd(q), neg, mode)
                inc && (q += 1)
            end
            mag = q
        end
    end
    mag > _tobig(UInt256(_maxmag(Decimal{P, S, T}))) && _throwoverflow(Decimal{P, S, T}, x)
    return _fromuval(Decimal{P, S, T}, _fromfullbig(UInt256, mag), neg, x)
end

Decimal{P, S, T}(x::AbstractFloat) where {P, S, T <: StorageInt} =
    _fromfloat(Decimal{P, S, T}, x, RoundNearest)

# ---- Decimal <-> Decimal, DecimalValue ----

# core rescaling of (unscaled, scale) into a target Decimal type;
# mode === nothing means exact-or-throw
function _torescaled(::Type{Decimal{P, S, T}}, u::Integer, s::Int, mode,
                     x) where {P, S, T <: StorageInt}
    neg = u < zero(u)
    m = _tomag256(u)
    return _torescaled(Decimal{P, S, T}, m, neg, s, mode, x)
end

function _torescaled(::Type{Decimal{P, S, T}}, m::UInt256, neg::Bool, s::Int,
                     mode, x) where {P, S, T <: StorageInt}
    if s <= S
        mag, ovf = _scaleup(m, S - s)
        ovf && _throwoverflow(Decimal{P, S, T}, x)
    else
        actualmode = mode === nothing ? RoundToZero : mode
        mag, inexact = _scaledown(m, s - S, neg, actualmode)
        (inexact && mode === nothing) && _throwinexact(Decimal{P, S, T}, x)
    end
    return _fromuval(Decimal{P, S, T}, mag, neg, x)
end

Decimal{P, S, T}(x::Decimal) where {P, S, T <: StorageInt} =
    _torescaled(Decimal{P, S, T}, x.unscaled, scale(x), nothing, x)
Decimal{P, S, T}(x::Decimal{P, S, T}) where {P, S, T <: StorageInt} = x
Decimal{P, S, T}(x::DecimalValue) where {P, S, T <: StorageInt} =
    _torescaled(Decimal{P, S, T}, x.unscaled, scale(x), nothing, x)

Decimal{P, S}(x::Real) where {P, S} = Decimal{P, S, _storagetype(P)}(x)

function DecimalValue{T}(x::Decimal) where {T <: StorageInt}
    return DecimalValue{T}(convert(T, x.unscaled), scale(x))
end
DecimalValue(x::Decimal{P, S, T}) where {P, S, T <: StorageInt} = DecimalValue{T}(x.unscaled, S)
DecimalValue{T}(x::DecimalValue) where {T <: StorageInt} =
    DecimalValue{T}(convert(T, x.unscaled), x.scale)
DecimalValue{T}(x::DecimalValue{T}) where {T <: StorageInt} = x

DecimalValue{T}(x::Integer) where {T <: StorageInt} = DecimalValue{T}(convert(T, x), 0)
DecimalValue{T}(x::Bool) where {T <: StorageInt} = DecimalValue{T}(T(x), 0)

function DecimalValue{T}(x::Rational) where {T <: StorageInt}
    iszero(x.den) && _throwinexact(DecimalValue{T}, x)
    d = x.den
    a = trailing_zeros(d)
    rest = d >> a
    b = 0
    while rest % 5 == zero(rest)
        rest = div(rest, 5)
        b += 1
    end
    isone(rest) || _throwinexact(DecimalValue{T}, x)
    s = max(a, b)
    # u = num * 2^(s-a) * 5^(s-b)
    n = _tomag256(x.num)
    sa = s - a
    lz = leading_zeros(n)
    sa > lz && _throwoverflow(DecimalValue{T}, x)
    n <<= sa
    sb = s - b
    if sb > 0
        sb > 110 && _throwoverflow(DecimalValue{T}, x)
        hi, lo = _mul256full(n, _upow5_256(sb))
        hi == zero(UInt256) || _throwoverflow(DecimalValue{T}, x)
        n = lo
    end
    neg = x.num < zero(x.num)
    !_fitsigned(n, neg, T) && _throwoverflow(DecimalValue{T}, x)
    u = (n % _utype(T)) % T
    return DecimalValue{T}(neg ? -u : u, s)
end

function DecimalValue{T}(x::AbstractFloat) where {T <: StorageInt}
    isfinite(x) || _throwinexact(DecimalValue{T}, x)
    iszero(x) && return zero(DecimalValue{T})
    num, pow, den = Base.decompose(x)
    neg = (num < 0) ⊻ (den < 0)
    # normalize: fold the mantissa's trailing 2-factors into the exponent so
    # the resulting scale is minimal
    tz = trailing_zeros(num)
    num >>= tz
    pow += tz
    m = _tomag256(abs(num))
    if pow >= 0
        lz = leading_zeros(m)
        pow > lz && _throwoverflow(DecimalValue{T}, x)
        m <<= pow
        s = 0
    else
        k = -pow
        k > 110 && _throwoverflow(DecimalValue{T}, x)
        hi, lo = _mul256full(m, _upow5_256(k))
        hi == zero(UInt256) || _throwoverflow(DecimalValue{T}, x)
        m = lo
        s = k
    end
    !_fitsigned(m, neg, T) && _throwoverflow(DecimalValue{T}, x)
    u = (m % _utype(T)) % T
    return DecimalValue{T}(neg ? -u : u, s)
end

# unqualified defaults: floats/rationals convert exactly, which typically needs
# wide storage (the exact decimal of a Float64 can carry ~55+ digits)
DecimalValue(x::AbstractFloat) = DecimalValue{Int256}(x)
DecimalValue(x::Rational) = DecimalValue{Int256}(x)
DecimalValue(x::Integer) = DecimalValue{Int64}(x)

# ---- rounding conversions ----

Base.round(::Type{DT}, x::Real,
           mode::RoundingMode=RoundNearest) where {DT <: Decimal} = _round(DT, x, mode)
# disambiguate against Base round(::Type, ::Rational[, mode])
Base.round(::Type{DT}, x::Rational,
           mode::RoundingMode=RoundNearest) where {DT <: Decimal} = _round(DT, x, mode)

# fill in the storage type when the target is written Decimal{P,S}
_round(::Type{Decimal{P, S}}, x, mode::RoundingMode) where {P, S} =
    _round(Decimal{P, S, _storagetype(P)}, x, mode)

_round(::Type{Decimal{P, S, T}}, x::Rational, mode::RoundingMode) where {P, S, T <: StorageInt} =
    _fromrational(Decimal{P, S, T}, x, mode)
_round(::Type{Decimal{P, S, T}}, x::Rational{BigInt}, mode::RoundingMode) where {P, S, T <: StorageInt} =
    _fromrational_big(Decimal{P, S, T}, x, mode)
_round(::Type{Decimal{P, S, T}}, x::AbstractFloat, mode::RoundingMode) where {P, S, T <: StorageInt} =
    _fromfloat(Decimal{P, S, T}, x, mode)
_round(::Type{Decimal{P, S, T}}, x::Integer, mode::RoundingMode) where {P, S, T <: StorageInt} =
    Decimal{P, S, T}(x)
_round(::Type{Decimal{P, S, T}}, x::Decimal, mode::RoundingMode) where {P, S, T <: StorageInt} =
    _torescaled(Decimal{P, S, T}, x.unscaled, scale(x), mode, x)
_round(::Type{Decimal{P, S, T}}, x::DecimalValue, mode::RoundingMode) where {P, S, T <: StorageInt} =
    _torescaled(Decimal{P, S, T}, x.unscaled, scale(x), mode, x)

"""
    rescale(D, x, mode=RoundNearest)

Convert a decimal to the target decimal type `D`, rounding with `mode` when
the target scale cannot represent `x` exactly. `convert`/constructors are the
exact-or-throw counterpart.
"""
rescale(::Type{DT}, x::AbstractDecimal,
        mode::RoundingMode=RoundNearest) where {DT <: Decimal} = _round(DT, x, mode)

function rescale(x::DecimalValue{T}, s::Integer,
                 mode::RoundingMode=RoundNearest) where {T <: StorageInt}
    s == scale(x) && return x
    neg = _isneg(x)
    m = _tomag256(x.unscaled)
    if s > scale(x)
        mag, ovf = _scaleup(m, Int(s) - scale(x))
        ovf && _throwoverflow(DecimalValue{T}, x)
    else
        mag, _ = _scaledown(m, scale(x) - Int(s), neg, mode)
    end
    !_fitsigned(mag, neg, T) && _throwoverflow(DecimalValue{T}, x)
    u = (mag % _utype(T)) % T
    return DecimalValue{T}(neg ? -u : u, s)
end

# ---- Decimal -> Integer ----

function _tointeger(::Type{I}, x::AbstractDecimal, mode) where {I}
    neg = _isneg(x)
    actualmode = mode === nothing ? RoundToZero : mode
    q, inexact = _scaledown(_tomag256(x.unscaled), scale(x), neg, actualmode)
    (inexact && mode === nothing) && _throwinexact(I, x)
    # q < 2^255 always (magnitudes are bounded by 10^76-ish), so Int256 is safe
    sv = q % Int256
    return convert(I, neg ? -sv : sv)
end

(::Type{I})(x::AbstractDecimal) where {I <: Integer} = _tointeger(I, x, nothing)
Base.Bool(x::AbstractDecimal) = _tointeger(Bool, x, nothing)
Base.round(::Type{I}, x::AbstractDecimal,
           mode::RoundingMode=RoundNearest) where {I <: Integer} =
    _tointeger(I, x, mode)
Base.trunc(::Type{I}, x::AbstractDecimal) where {I <: Integer} =
    _tointeger(I, x, RoundToZero)
Base.floor(::Type{I}, x::AbstractDecimal) where {I <: Integer} =
    _tointeger(I, x, RoundDown)
Base.ceil(::Type{I}, x::AbstractDecimal) where {I <: Integer} =
    _tointeger(I, x, RoundUp)

# ---- Decimal -> Rational ----

function Base.Rational{I}(x::AbstractDecimal) where {I <: Integer}
    s = scale(x)
    den = s <= _tablemax(UInt128) ? convert(I, _upow10(UInt128, s)) :
          convert(I, _tobig(_upow10(UInt256, min(s, _tablemax(UInt256)))))
    return convert(I, x.unscaled) // den
end
Base.Rational(x::Decimal{P, S, T}) where {P, S, T <: StorageInt} = Rational{T}(x)
Base.Rational(x::DecimalValue{T}) where {T <: StorageInt} = Rational{T}(x)

# ---- Decimal -> AbstractFloat ----

# 10^k exactly representable as Float64, k in 0:22
const _FPOW10 = Float64[10.0^k for k in 0:22]

function _tofloat(::Type{F}, u::Integer, s::Int) where {F <: AbstractFloat}
    # fast path (Float64 only — narrowing afterwards would double-round):
    # numerator and denominator both exact, so the division rounds correctly
    if F === Float64 && s <= 22 && -9007199254740992 <= u <= 9007199254740992
        return Float64(Int64(u)) / @inbounds(_FPOW10[s + 1])
    end
    return _tofloat_slow(F, u, s)
end

@noinline function _tofloat_slow(::Type{F}, u::Integer, s::Int) where {F}
    iszero(u) && return zero(F)
    num = abs(_tobigsigned(u))
    den = big(10)^s
    nbits = ndigits(num, base=2)
    dbits = ndigits(den, base=2)
    e = nbits - dbits
    if e >= 0
        num < den << e && (e -= 1)
    else
        num << -e < den && (e -= 1)
    end
    p = precision(F)
    emin = exponent(floatmin(F))
    emax = exponent(floatmax(F))
    e > emax && return u < zero(u) ? -F(Inf) : F(Inf)
    shift = max(e, emin) - (p - 1)
    if shift >= 0
        q, r = divrem(num, den << shift)
        divisor = den << shift
    else
        q, r = divrem(num << -shift, den)
        divisor = den
    end
    complement = divisor - r
    (r > complement || (r == complement && isodd(q))) && (q += 1)
    value = ldexp(F(q), shift)
    return u < zero(u) ? -value : value
end

_tobigsigned(u::Integer) = big(u)
_tobigsigned(u::Int256) = (n = _tobig(_mag(u)); u < 0 ? -n : n)

Base.Float64(x::AbstractDecimal) = _tofloat(Float64, x.unscaled, scale(x))
Base.Float32(x::AbstractDecimal) = _tofloat(Float32, x.unscaled, scale(x))
Base.Float16(x::AbstractDecimal) = _tofloat(Float16, x.unscaled, scale(x))
Base.AbstractFloat(x::AbstractDecimal) = Float64(x)

# ---- promotion ----

_intdigits(::Type{Bool}) = 1
_intdigits(::Type{Int8}) = 3
_intdigits(::Type{UInt8}) = 3
_intdigits(::Type{Int16}) = 5
_intdigits(::Type{UInt16}) = 5
_intdigits(::Type{Int32}) = 10
_intdigits(::Type{UInt32}) = 10
_intdigits(::Type{Int64}) = 19
_intdigits(::Type{UInt64}) = 20
_intdigits(::Type{Int128}) = 39
_intdigits(::Type{UInt128}) = 39
_intdigits(::Type{Int256}) = 77
_intdigits(::Type{UInt256}) = 78

# @generated so the computed type is a compile-time constant for inference
@generated function Base.promote_rule(::Type{Decimal{P1, S1, T1}},
                                      ::Type{Decimal{P2, S2, T2}}) where {P1, S1, T1 <: StorageInt, P2, S2, T2 <: StorageInt}
    S = max(S1, S2)
    P = min(max(P1 - S1, P2 - S2) + S, 76)
    return :(Decimal{$P, $S, $(_storagetype(P))})
end

@generated function Base.promote_rule(::Type{Decimal{P, S, T}},
                                      ::Type{I}) where {P, S, T <: StorageInt, I <: Union{Bool, Base.BitInteger, Int256}}
    P2 = min(max(P - S, _intdigits(I)) + S, 76)
    return :(Decimal{$P2, $S, $(_storagetype(P2))})
end

Base.promote_rule(::Type{<:AbstractDecimal}, ::Type{F}) where {F <: AbstractFloat} = F

Base.promote_rule(::Type{Decimal{P, S, T}}, ::Type{Rational{I}}) where {P, S, T <: StorageInt, I} =
    Rational{promote_type(T, I)}
Base.promote_rule(::Type{DecimalValue{T}}, ::Type{Rational{I}}) where {T <: StorageInt, I} =
    Rational{promote_type(T, I)}

Base.promote_rule(::Type{DecimalValue{T1}}, ::Type{DecimalValue{T2}}) where {T1 <: StorageInt, T2 <: StorageInt} =
    DecimalValue{promote_type(T1, T2)}
Base.promote_rule(::Type{DecimalValue{T1}}, ::Type{Decimal{P, S, T}}) where {T1 <: StorageInt, P, S, T <: StorageInt} =
    DecimalValue{promote_type(T1, T)}
@generated function Base.promote_rule(::Type{DecimalValue{T}},
                                      ::Type{I}) where {T <: StorageInt, I <: Union{Bool, Base.BitInteger, Int256, UInt256}}
    ibits = 8 * sizeof(I) + (I <: Unsigned)
    bits = min(max(8 * sizeof(T), ibits), 256)
    PT = bits <= 32 ? Int32 : bits <= 64 ? Int64 : bits <= 128 ? Int128 : Int256
    return :(DecimalValue{$PT})
end
