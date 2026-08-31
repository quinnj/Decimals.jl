# Wide unsigned division: 256-bit dividends without BigInt. Divisors up to 64
# bits use Möller–Granlund reciprocal 2-by-1 steps; wider divisors use Knuth's
# Algorithm D over 64-bit limbs. The only libcalls are one 128-bit divide to
# form a reciprocal (by-1 path) and Base's divrem on the 128÷128 fast path.

# 128÷64 schoolbook in base 2^32 (Hacker's Delight divlu): two hardware
# 64-bit divides, no libcall. Requires hi < d (the quotient fits 64 bits).
@inline function _divlu(hi::UInt64, lo::UInt64, d::UInt64)
    B32 = UInt64(1) << 32
    s = leading_zeros(d)
    d <<= s
    hi = s == 0 ? hi : (hi << s) | (lo >>> (64 - s))
    lo <<= s
    dh = d >>> 32
    dl = d & 0x00000000ffffffff
    lohi = lo >>> 32
    lolo = lo & 0x00000000ffffffff
    q1 = hi ÷ dh
    r1 = hi - q1 * dh
    while q1 >= B32 || q1 * dl > (r1 << 32) | lohi
        q1 -= one(UInt64)
        r1 += dh
        r1 >= B32 && break
    end
    m1 = (hi << 32) | lohi
    m1 -= q1 * d  # wrapping; true value < d fits 64 bits
    q0 = m1 ÷ dh
    r0 = m1 - q0 * dh
    while q0 >= B32 || q0 * dl > (r0 << 32) | lolo
        q0 -= one(UInt64)
        r0 += dh
        r0 >= B32 && break
    end
    m0 = (m1 << 32) | lolo
    m0 -= q0 * d
    return ((q1 << 32) | q0, m0 >>> s)
end

# reciprocal for 2-by-1 division: v = ⌊(2^128 - 1)/d⌋ - 2^64, d normalized.
# (2^128 - 1)/d = 2^64 + ((2^64-1-d)*2^64 + (2^64-1))/d, and the second
# term's high word is < d, so one libcall-free _divlu computes it.
@inline function _recip2x1(d::UInt64)
    q, _ = _divlu(typemax(UInt64) - d, typemax(UInt64), d)
    return q
end

# GMP's udiv_qrnnd_preinv: (n1,n0) ÷ d with precomputed reciprocal v.
# Preconditions: d normalized (top bit set), n1 < d.
@inline function _div2x1(n1::UInt64, n0::UInt64, d::UInt64, v::UInt64)
    t = widemul(n1, v)
    t += _u128(n1 + one(UInt64), n0)  # two-limb wrapping add, per GMP
    q1 = _hi64(t)
    q0 = _lo64(t)
    r = n0 - q1 * d
    if r > q0
        q1 -= one(UInt64)
        r += d
    end
    if r >= d
        q1 += one(UInt64)
        r -= d
    end
    return (q1, r)
end

# 256 ÷ 64 via reciprocal 2-by-1 steps, skipping leading zero limbs
function _divrem_by1(u::UInt256, d64::UInt64)
    lz = leading_zeros(d64)
    d = d64 << lz
    l0, l1, l2, l3 = _limbs(u)
    if lz == 0
        u4 = zero(UInt64)
    else
        rs = 64 - lz
        u4 = l3 >>> rs
        l3 = (l3 << lz) | (l2 >>> rs)
        l2 = (l2 << lz) | (l1 >>> rs)
        l1 = (l1 << lz) | (l0 >>> rs)
        l0 = l0 << lz
    end
    if (l2 | l3 | u4) == zero(UInt64)
        # at most two significant limbs: one or two 2-by-1 steps
        v = _recip2x1(d)
        if l1 < d
            q0, r = _div2x1(l1, l0, d, v)
            return (UInt256(q0), UInt256(r >>> lz))
        end
        qh, rh = _div2x1(zero(UInt64), l1, d, v)
        q0, r = _div2x1(rh, l0, d, v)
        return (_u256(q0, qh, zero(UInt64), zero(UInt64)), UInt256(r >>> lz))
    end
    v = _recip2x1(d)
    q3, r = _div2x1(u4, l3, d, v)
    q2, r = _div2x1(r, l2, d, v)
    q1, r = _div2x1(r, l1, d, v)
    q0, r = _div2x1(r, l0, d, v)
    return (_u256(q0, q1, q2, q3), UInt256(r >>> lz))
end

# Knuth Algorithm D: u (4 limbs + spill) ÷ d of m significant limbs, 2 <= m <= 4
function _divrem_knuth(u::UInt256, d::UInt256, m::Int)
    lz = leading_zeros(_limbs(d)[m])
    dnl = _limbs(d << lz)
    ul = _limbs(u << lz)
    spill = lz == 0 ? zero(UInt64) : (_limbs(u)[4] >>> (64 - lz))
    uu = (ul[1], ul[2], ul[3], ul[4], spill)
    dm1 = dnl[m]
    dm2 = dnl[m - 1]
    v = _recip2x1(dm1)
    q = zero(UInt256)
    for j in (4 - m):-1:0
        ujm = uu[j + m + 1]
        ujm1 = uu[j + m]
        if ujm >= dm1
            qhat = typemax(UInt64)
            rhat = UInt128(ujm1) + UInt128(dm1)
        else
            qh, rh = _div2x1(ujm, ujm1, dm1, v)
            qhat = qh
            rhat = UInt128(rh)
        end
        ujm2 = uu[j + m - 1]
        while rhat < (UInt128(1) << 64) &&
              widemul(qhat, dm2) > ((rhat << 64) | UInt128(ujm2))
            qhat -= one(UInt64)
            rhat += UInt128(dm1)
        end
        # multiply-subtract qhat*dn from uu[j+1 .. j+m+1]
        carry = zero(UInt64)
        borrow = zero(UInt64)
        for i in 0:(m - 1)
            p = widemul(qhat, dnl[i + 1]) + UInt128(carry)
            carry = _hi64(p)
            pl = _lo64(p)
            t = uu[i + j + 1]
            x1 = t - pl
            b1 = t < pl
            x2 = x1 - borrow
            b2 = x1 < borrow
            uu = Base.setindex(uu, x2, i + j + 1)
            borrow = UInt64(b1 | b2)
        end
        t = uu[j + m + 1]
        x1 = t - carry
        b1 = t < carry
        x2 = x1 - borrow
        b2 = x1 < borrow
        uu = Base.setindex(uu, x2, j + m + 1)
        if b1 | b2
            # qhat was one too large: add the divisor back
            qhat -= one(UInt64)
            c = zero(UInt64)
            for i in 0:(m - 1)
                s = UInt128(uu[i + j + 1]) + UInt128(dnl[i + 1]) + UInt128(c)
                uu = Base.setindex(uu, _lo64(s), i + j + 1)
                c = _hi64(s)
            end
            uu = Base.setindex(uu, uu[j + m + 1] + c, j + m + 1)
        end
        q |= UInt256(qhat) << (64 * j)
    end
    r = _u256(uu[1], uu[2], uu[3], uu[4])
    return (q, r >> lz)
end

_divrem_wide(u::UInt128, d::UInt128) = divrem(u, d)

function _divrem_wide(u::UInt256, d::UInt256)
    d == zero(UInt256) && throw(DivideError())
    u < d && return (zero(UInt256), u)
    dl = _limbs(d)
    ul = _limbs(u)
    if dl[4] == zero(UInt64) && dl[3] == zero(UInt64)
        if dl[2] == zero(UInt64)
            # single-limb divisor; single-limb dividend is one hardware divide
            if (ul[2] | ul[3] | ul[4]) == zero(UInt64)
                q, r = divrem(ul[1], dl[1])
                return (UInt256(q), UInt256(r))
            end
            return _divrem_by1(u, dl[1])
        end
        if ul[4] == zero(UInt64) && ul[3] == zero(UInt64)
            q, r = divrem(_u128(ul[2], ul[1]), _u128(dl[2], dl[1]))
            return (UInt256(q), UInt256(r))
        end
        return _divrem_knuth(u, d, 2)
    end
    m = dl[4] == zero(UInt64) ? 3 : 4
    return _divrem_knuth(u, d, m)
end
