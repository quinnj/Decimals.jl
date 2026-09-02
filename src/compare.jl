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

# Float64(x) is correctly rounded and therefore monotone, so a strict
# inequality between it and y decides the comparison outright; only an equal
# image needs the exact tie-break, which classifies |y| at x's scale with
# integer arithmetic (floor plus an inexact flag). Other float types take the
# BigInt cross-multiply.
function _cmpfloat(x::AbstractDecimal, y::AbstractFloat)
    isnan(y) && return 2  # sentinel: unordered
    isinf(y) && return y > 0 ? -1 : 1
    y isa Union{Float16, Float32, Float64} || return _cmpfloatbig(x, y)
    yf = Float64(y)
    fx = Float64(x)
    fx < yf && return -1
    fx > yf && return 1
    return _cmpfloattie(x, yf)
end

function _cmpfloattie(x::AbstractDecimal, y::Float64)
    xneg = _isneg(x)
    if iszero(y)
        iszero(x) && return 0
        return xneg ? -1 : 1
    end
    num, pow, _ = Base.decompose(y)
    mag, inexact, status = _floatmagatscale(UInt64(abs(num)), pow, scale(x))
    status == 2 && return _cmpfloatbig(x, y)
    # status 1: |y| exceeds every coefficient at this scale
    c = status == 1 ? -1 :
        (u = _tomag256(x.unscaled); u < mag ? -1 : u > mag ? 1 : (inexact ? -1 : 0))
    return xneg ? -c : c
end

# |y| = m*2^pow at scale s: (floor(|y|*10^s), inexact, status) with status
# 0 ok, 1 = |y|*10^s >= 2^256, 2 = extreme exponent, use the BigInt path
@inline function _floatmagatscale(m::UInt64, pow::Int, s::Int)
    m256 = UInt256(m)
    if pow >= 0
        (pow > 255 || pow > leading_zeros(m256)) && return (zero(UInt256), false, 1)
        mag, ovf = _scaleup(m256 << pow, s)
        return (mag, false, ovf ? 1 : 0)
    end
    k = -pow
    if k <= s
        k > 110 && return (zero(UInt256), false, 2)
        hi, lo = _mul256full(m256, _upow5_256(k))
        hi != zero(UInt256) && return (zero(UInt256), false, 1)
        mag, ovf = _scaleup(lo, s - k)
        return (mag, false, ovf ? 1 : 0)
    end
    k > 87 && return (zero(UInt256), false, 2)
    hi, lo = _mul256full(m256, _upow5_256(k))
    hi != zero(UInt256) && return (zero(UInt256), false, 2)
    q, inexact = _scaledown(lo, k - s, false, RoundToZero)
    return (q, inexact, 0)
end

# exact compare via 2/5-power cross-multiply in BigInt (cold path)
function _cmpfloatbig(x::AbstractDecimal, y::AbstractFloat)
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
# greedy chunked extraction of min(v5(u), s) factors of five: hardware
# divides while the magnitude fits a limb, reciprocal wide divides otherwise —
# trailing-zero-heavy values never pay one wide division per factor
@inline function _strip5u64(m::UInt64, left::Int)
    for k in (27, 13, 6, 3, 1)
        while left >= k
            d = UInt64(5)^k
            q, r = divrem(m, d)
            r == zero(UInt64) || break
            m = q
            left -= k
        end
    end
    return (m, left)
end

function _strip5s(u::T, s::Int) where {T <: StorageInt}
    (u == zero(T) || s == 0) && return (u, s == 0 ? s : 0)
    mw = _tomag256(u)
    left = s
    if mw > UInt256(typemax(UInt64))
        for k in (27, 13, 6, 3, 1)
            while left >= k
                q, r = _divrem_by1(mw, UInt64(5)^k)
                r == zero(UInt256) || break
                mw = q
                left -= k
            end
            mw <= UInt256(typemax(UInt64)) && break
        end
    end
    if mw <= UInt256(typemax(UInt64)) && left > 0
        m64, left = _strip5u64(mw % UInt64, left)
        mw = UInt256(m64)
    end
    v = (mw % _utype(T)) % T
    return (u < zero(T) ? -v : v, left)
end

function Base.decompose(x::Decimal{P, S, T}) where {P, S, T <: StorageInt}
    u, s = _strip5s(x.unscaled, S)
    # the branch on the type parameter folds, so each instantiation returns a
    # concrete machine-integer denominator
    if S <= 27
        return (u, -S, Int64(5)^s)
    elseif S <= 55
        return (u, -S, Int128(5)^s)
    else
        return (u, -S, _upow5_256(s) % Int256)
    end
end

function Base.decompose(x::DecimalValue)
    u, s = _strip5s(x.unscaled, scale(x))
    s <= 27 && return (u, -scale(x), Int64(5)^s)
    s <= 55 && return (u, -scale(x), Int128(5)^s)
    s <= 109 && return (u, -scale(x), _upow5_256(s) % Int256)
    return (_tobigsigned(u), -scale(x), big(5)^s)
end
