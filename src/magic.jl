# Division by 10^k via Granlund–Montgomery invariant-integer multiplication.
# Julia/LLVM does NOT strength-reduce (U)Int128/256 division even by constants
# (it emits __udivti3 libcalls), and our k is usually a runtime value anyway,
# so we precompute (M, s, add) triples per width and divide with one mulhi.

# Round-up method: with F = N+s and M = ⌈2^F/d⌉, ⌊x*M/2^F⌋ == ⌊x/d⌋ for all
# 0 <= x < 2^N iff e = M*d - 2^F <= 2^s (Granlund–Montgomery Thm 4.2).
# When M needs N+1 bits (add == true) we store M - 2^N and use the
# Hacker's Delight fixup: q = (t + ((x - t) >> 1)) >> (s - 1), t = mulhi(x, M).
function _magic(d::BigInt, N::Int)
    for s in 0:(2 * N)
        M = cld(big(2)^(N + s), d)
        e = M * d - big(2)^(N + s)
        e <= big(2)^s || continue
        M < big(2)^N && return (M, s, false)
        (M < big(2)^(N + 1) && s >= 1) && return (M - big(2)^N, s, true)
    end
    return error("no magic constant for divisor $d at width $N")
end

function _buildmagic(::Type{U}) where {U <: Unsigned}
    N = 8 * sizeof(U)
    entries = Tuple{U, Int32, Bool}[]
    for k in 1:_tablemax(U)
        M, s, add = _magic(big(10)^k, N)
        push!(entries, (_fromfullbig(U, M), Int32(s), add))
    end
    return entries
end

const MAGIC_32 = _buildmagic(UInt32)
const MAGIC_64 = _buildmagic(UInt64)
const MAGIC_128 = _buildmagic(UInt128)
const MAGIC_256 = _buildmagic(UInt256)

_magictbl(::Type{UInt32}) = MAGIC_32
_magictbl(::Type{UInt64}) = MAGIC_64
_magictbl(::Type{UInt128}) = MAGIC_128
_magictbl(::Type{UInt256}) = MAGIC_256

# truncating x ÷ 10^k, one mulhi + shift, no division; requires 0 <= k <= _tablemax(U)
@inline function _divpow10(x::U, k::Int) where {U <: Unsigned}
    k == 0 && return x
    @boundscheck 1 <= k <= _tablemax(U) || throw(BoundsError(_magictbl(U), k))
    M, s, add = @inbounds _magictbl(U)[k]
    t = _mulhi(x, M)
    add || return t >>> s
    return (((x - t) >>> 1) + t) >>> (s - 1)
end
