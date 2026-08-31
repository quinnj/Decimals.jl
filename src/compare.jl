# Exact comparison and hashing. Equality is by numeric value across scales,
# precisions, and number types (1.20 == 1.2 == 12//10); the representation
# still preserves scale. Hashing goes through Base.decompose so decimals hash
# identically to equal Ints, Rationals, and Floats.

# compare u1*10^-s1 vs u2*10^-s2 exactly; -1/0/1
function _cmpuv(u1::Integer, s1::Int, u2::Integer, s2::Int)
    n1 = u1 < zero(u1)
    n2 = u2 < zero(u2)
    n1 != n2 && return n1 ? -1 : 1
    m1 = _tomag256(u1)
    m2 = _tomag256(u2)
    c = 0
    if s1 == s2
        c = m1 < m2 ? -1 : m1 > m2 ? 1 : 0
    elseif s1 < s2
        m1s, ovf = _scaleup(m1, s2 - s1)
        c = ovf ? 1 : m1s < m2 ? -1 : m1s > m2 ? 1 : 0
    else
        m2s, ovf = _scaleup(m2, s1 - s2)
        c = ovf ? -1 : m1 < m2s ? -1 : m1 > m2s ? 1 : 0
    end
    return n1 ? -c : c
end

@inline _cmp(x::AbstractDecimal, y::AbstractDecimal) =
    _cmpuv(x.unscaled, scale(x), y.unscaled, scale(y))

# same-scale fast path: type-level S match collapses to an unscaled compare
@inline function _cmp(x::Decimal{P1, S, T1}, y::Decimal{P2, S, T2}) where {P1, P2, S, T1 <: StorageInt, T2 <: StorageInt}
    a, b = promote(x.unscaled, y.unscaled)
    return a < b ? -1 : a > b ? 1 : 0
end

Base.:(==)(x::AbstractDecimal, y::AbstractDecimal) = _cmp(x, y) == 0
Base.isless(x::AbstractDecimal, y::AbstractDecimal) = _cmp(x, y) < 0
Base.:(<)(x::AbstractDecimal, y::AbstractDecimal) = _cmp(x, y) < 0
Base.:(<=)(x::AbstractDecimal, y::AbstractDecimal) = _cmp(x, y) <= 0

# ---- vs Integer ----

_cmpint(x::AbstractDecimal, y::Integer) = _cmpuv(x.unscaled, scale(x), y, 0)
function _cmpint(x::AbstractDecimal, y::BigInt)
    v = _tobigsigned(x.unscaled)
    w = y * big(10)^scale(x)
    return v < w ? -1 : v > w ? 1 : 0
end

Base.:(==)(x::AbstractDecimal, y::Integer) = _cmpint(x, y) == 0
Base.:(==)(x::Integer, y::AbstractDecimal) = _cmpint(y, x) == 0
Base.isless(x::AbstractDecimal, y::Integer) = _cmpint(x, y) < 0
Base.isless(x::Integer, y::AbstractDecimal) = _cmpint(y, x) > 0
Base.:(<)(x::AbstractDecimal, y::Integer) = _cmpint(x, y) < 0
Base.:(<)(x::Integer, y::AbstractDecimal) = _cmpint(y, x) > 0
Base.:(<=)(x::AbstractDecimal, y::Integer) = _cmpint(x, y) <= 0
Base.:(<=)(x::Integer, y::AbstractDecimal) = _cmpint(y, x) >= 0

# ---- vs Rational ----

# x vs n/d: compare x*d vs n exactly via big cross-multiply (cold path OK)
function _cmprational(x::AbstractDecimal, y::Rational)
    iszero(y.den) && return y.num > 0 ? -1 : 1  # y is ±Inf
    a = _tobigsigned(x.unscaled) * _tobigsigned(y.den)
    b = _tobigsigned(y.num) * big(10)^scale(x)
    return a < b ? -1 : a > b ? 1 : 0
end
_tobigsigned(u::BigInt) = u

Base.:(==)(x::AbstractDecimal, y::Rational) = _cmprational(x, y) == 0
Base.:(==)(x::Rational, y::AbstractDecimal) = _cmprational(y, x) == 0
Base.isless(x::AbstractDecimal, y::Rational) = _cmprational(x, y) < 0
Base.isless(x::Rational, y::AbstractDecimal) = _cmprational(y, x) > 0
Base.:(<)(x::AbstractDecimal, y::Rational) = _cmprational(x, y) < 0
Base.:(<)(x::Rational, y::AbstractDecimal) = _cmprational(y, x) > 0

# ---- vs AbstractFloat ----

# exact compare via 2/5-power cross-multiply in BigInt (cold path for now)
function _cmpfloat(x::AbstractDecimal, y::AbstractFloat)
    isnan(y) && return 2  # sentinel: unordered
    isinf(y) && return y > 0 ? -1 : 1
    num, pow, den = Base.decompose(y)
    yneg = (num < 0) ⊻ (den < 0)
    xneg = _isneg(x)
    if iszero(x) || iszero(y)
        iszero(x) && iszero(y) && return 0
        iszero(x) && return yneg ? 1 : -1
        return xneg ? -1 : 1
    end
    xneg != yneg && return xneg ? -1 : 1
    # |x| vs |y|: u*10^-s vs m*2^pow  =>  u*2^-s*5^-s vs m*2^pow
    u = _tobig(_tomag256(x.unscaled))
    m = big(abs(num))
    s = scale(x)
    e = pow + s  # compare u vs m * 5^s * 2^e
    rhs = m * big(5)^s
    if e >= 0
        rhs <<= e
    else
        u <<= -e
    end
    c = u < rhs ? -1 : u > rhs ? 1 : 0
    return xneg ? -c : c
end

Base.:(==)(x::AbstractDecimal, y::AbstractFloat) = _cmpfloat(x, y) == 0
Base.:(==)(x::AbstractFloat, y::AbstractDecimal) = _cmpfloat(y, x) == 0
function Base.isless(x::AbstractDecimal, y::AbstractFloat)
    c = _cmpfloat(x, y)
    return c == 2 || c < 0  # everything isless NaN
end
function Base.isless(x::AbstractFloat, y::AbstractDecimal)
    isnan(x) && return false
    return _cmpfloat(y, x) > 0
end
Base.:(<)(x::AbstractDecimal, y::AbstractFloat) = _cmpfloat(x, y) == -1
Base.:(<)(x::AbstractFloat, y::AbstractDecimal) = _cmpfloat(y, x) == 1

# ---- hashing ----

# x == num * 2^pow / den. Base's generic Real hash requires num/den in lowest
# terms apart from powers of two (it strips those itself), so we strip the
# common factors of five: u/(2^S*5^S) -> (u/5^r) / (2^S*5^(S-r)).
@inline _divrem5(u::Union{Int32, Int64}) = divrem(u, 5)
@inline function _divrem5(u::Int128)
    # avoid __udivti3: m ÷ 5 == 2*(m ÷ 10) + (m%10 >= 5), via one magic divide
    m = _mag(u)
    q = _divpow10(m, 1) << 1
    r = m - q * UInt128(5)
    if r >= UInt128(5)
        q += one(UInt128)
        r -= UInt128(5)
    end
    sq = q % Int128
    return (u < 0 ? -sq : sq, u < 0 ? -(r % Int64) : r % Int64)
end
@inline function _divrem5(u::Int256)
    m = _mag(u)
    q, r = _divrem_by1(m, UInt64(5))
    sq = q % Int256
    return (u < 0 ? -sq : sq, u < 0 ? -(r % Int64) : (r % Int64))
end

function _strip5s(u::T, s::Int) where {T <: StorageInt}
    u == zero(T) && return (u, 0)
    while s > 0
        q, r = _divrem5(u)
        iszero(r) || break
        u = q
        s -= 1
    end
    return (u, s)
end

function Base.decompose(x::Decimal{P, S, T}) where {P, S, T <: StorageInt}
    u, s = _strip5s(x.unscaled, S)
    return (u, -S, _upow5_256(s) % Int256)  # 5^76 < typemax(Int256)
end

function Base.decompose(x::DecimalValue)
    u, s = _strip5s(x.unscaled, scale(x))
    s <= 109 && return (u, -scale(x), _upow5_256(s) % Int256)
    return (_tobigsigned(u), -scale(x), big(5)^s)
end
