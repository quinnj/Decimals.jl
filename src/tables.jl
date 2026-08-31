# Compile-time constant tables for the kernel layer. BigInt is used only here,
# at table-construction time; nothing at runtime touches it.

# build an unsigned value from a BigInt, 64 bits at a time (works for any width)
function _fromfullbig(::Type{U}, x::BigInt) where {U <: Unsigned}
    x >= 0 || throw(ArgumentError("negative"))
    r = zero(U)
    s = 0
    while x > 0
        r |= U(UInt64(x & 0xffffffffffffffff)) << s
        x >>= 64
        s += 64
    end
    return r
end

_tobig(x::Unsigned) = BigInt(x)
function _tobig(x::UInt256)
    r = big(0)
    for i in 3:-1:0
        r = (r << 64) | big((x >> (64 * i)) % UInt64)
    end
    return r
end

# largest k such that 10^k fits the width
_tablemax(::Type{UInt32}) = 9
_tablemax(::Type{UInt64}) = 19
_tablemax(::Type{UInt128}) = 38
_tablemax(::Type{UInt256}) = 77

# max representable decimal digit count for the width
_maxdigits(::Type{UInt32}) = 10
_maxdigits(::Type{UInt64}) = 20
_maxdigits(::Type{UInt128}) = 39
_maxdigits(::Type{UInt256}) = 78

_buildpow10(::Type{U}) where {U} =
    U[_fromfullbig(U, big(10)^k) for k in 0:_tablemax(U)]

const UPOW10_32 = _buildpow10(UInt32)
const UPOW10_64 = _buildpow10(UInt64)
const UPOW10_128 = _buildpow10(UInt128)
const UPOW10_256 = _buildpow10(UInt256)

_pow10tbl(::Type{UInt32}) = UPOW10_32
_pow10tbl(::Type{UInt64}) = UPOW10_64
_pow10tbl(::Type{UInt128}) = UPOW10_128
_pow10tbl(::Type{UInt256}) = UPOW10_256

# 10^k for 0 <= k <= _tablemax(U)
@inline function _upow10(::Type{U}, k::Int) where {U <: Unsigned}
    @boundscheck 0 <= k <= _tablemax(U) || throw(BoundsError(_pow10tbl(U), k + 1))
    return @inbounds _pow10tbl(U)[k + 1]
end

# typemax(U) ÷ 10^k, for scale-up overflow checks; index k in 1:_tablemax
_buildmaxdiv(::Type{U}) where {U} =
    U[_fromfullbig(U, div(_tobig(typemax(U)), big(10)^k)) for k in 1:_tablemax(U)]

const MAXDIV_32 = _buildmaxdiv(UInt32)
const MAXDIV_64 = _buildmaxdiv(UInt64)
const MAXDIV_128 = _buildmaxdiv(UInt128)
const MAXDIV_256 = _buildmaxdiv(UInt256)

_maxdivtbl(::Type{UInt32}) = MAXDIV_32
_maxdivtbl(::Type{UInt64}) = MAXDIV_64
_maxdivtbl(::Type{UInt128}) = MAXDIV_128
_maxdivtbl(::Type{UInt256}) = MAXDIV_256

@inline function _maxdiv(::Type{U}, k::Int) where {U <: Unsigned}
    @boundscheck 1 <= k <= _tablemax(U) || throw(BoundsError(_maxdivtbl(U), k))
    return @inbounds _maxdivtbl(U)[k]
end

# largest k such that 5*10^k fits the width (for half-of-10^(k+1) tie compares)
function _findhalfmax(::Type{U}) where {U}
    tm = _tobig(typemax(U))
    k = 0
    while 5 * big(10)^(k + 1) <= tm
        k += 1
    end
    return k
end

const HALFMAX_32 = _findhalfmax(UInt32)
const HALFMAX_64 = _findhalfmax(UInt64)
const HALFMAX_128 = _findhalfmax(UInt128)
const HALFMAX_256 = _findhalfmax(UInt256)

_halfmax(::Type{UInt32}) = HALFMAX_32
_halfmax(::Type{UInt64}) = HALFMAX_64
_halfmax(::Type{UInt128}) = HALFMAX_128
_halfmax(::Type{UInt256}) = HALFMAX_256

# decimal digit count: bits-based estimate (1233/4096 ≈ log10(2), slightly under)
# then one table compare to correct
@inline function _ndigits10(x::U) where {U <: Unsigned}
    x == zero(U) && return 1
    bits = (8 * sizeof(U)) - leading_zeros(x)
    t = ((bits - 1) * 1233) >> 12
    t + 1 > _tablemax(U) && return _maxdigits(U)
    return t + 1 + (x >= _upow10(U, t + 1) ? 1 : 0)
end
