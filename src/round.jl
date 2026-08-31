# Magnitude-domain scaling kernels. All operate on unsigned magnitudes with an
# explicit `neg` sign flag so directed rounding modes resolve correctly; signed
# wrappers live at the bottom. No global state: the rounding mode is always an
# explicit RoundingMode argument (statically dispatched singleton).

# whether to increment |q| given the discarded remainder's relation to half of
# the divisor: below (< half), tie (== half); otherwise above. Caller has
# already handled the exact (remainder == 0) case.
@inline function _roundinc(below::Bool, tie::Bool, qodd::Bool, neg::Bool,
                           mode::RoundingMode)
    mode === RoundToZero && return false
    mode === RoundFromZero && return true
    mode === RoundDown && return neg
    mode === RoundUp && return !neg
    below && return false
    tie || return true
    mode === RoundNearest && return qodd
    mode === RoundNearestTiesAway && return true
    mode === RoundNearestTiesUp && return !neg
    throw(ArgumentError("unsupported rounding mode $mode"))
end

# round(x / 10^k) on a magnitude; returns (result, inexact).
# Valid for any k >= 0 (k beyond the width's table collapses to 0/1).
@inline function _scaledown(x::U, k::Int, neg::Bool,
                            mode::RoundingMode) where {U <: Unsigned}
    (k == 0 || x == zero(U)) && return (x, false)
    if k >= _ndigits10(x)
        # quotient is zero: x < 10^k; classify x against 5*10^(k-1)
        k1 = k - 1
        if k1 > _halfmax(U)
            below, tie = true, false
        else
            half = U(5) * _upow10(U, k1)
            below = x < half
            tie = x == half
        end
        inc = _roundinc(below, tie, false, neg, mode)
        return (inc ? one(U) : zero(U), true)
    end
    q = _divpow10(x, k)
    p10 = _upow10(U, k)
    r = x - q * p10
    r == zero(U) && return (q, false)
    half = p10 >>> 1
    inc = _roundinc(r < half, r == half, (q & one(U)) != zero(U), neg, mode)
    return (inc ? q + one(U) : q, true)
end

# x * 10^k on a magnitude; returns (result, overflowed)
@inline function _scaleup(x::U, k::Int) where {U <: Unsigned}
    (k == 0 || x == zero(U)) && return (x, false)
    (k > _tablemax(U) || x > _maxdiv(U, k)) && return (x, true)
    return (x * _upow10(U, k), false)
end

# unsigned magnitude of a signed value; kernel precondition: x != typemin(T),
# which the Decimal invariant |x| < 10^P < typemax(T) guarantees
@inline _mag(x::T) where {T <: Signed} = unsigned(x < zero(T) ? -x : x)

@inline _withsign(m::U, neg::Bool) where {U <: Unsigned} =
    neg ? -signed(m) : signed(m)

# round(x / 10^k) for signed x; returns (result, inexact)
@inline function _scaledown(x::T, k::Int, mode::RoundingMode) where {T <: Signed}
    neg = x < zero(T)
    q, inexact = _scaledown(_mag(x), k, neg, mode)
    return (_withsign(q, neg), inexact)
end

# x * 10^k for signed x; returns (result, overflowed)
@inline function _scaleup(x::T, k::Int) where {T <: Signed}
    neg = x < zero(T)
    m, ovf = _scaleup(_mag(x), k)
    (ovf || m > unsigned(typemax(T))) && return (x, true)
    return (_withsign(m, neg), false)
end
