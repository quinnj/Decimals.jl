# 64-bit limb helpers: wide multiplies and limb split/join for UInt128/UInt256.
# Everything here is allocation-free and libcall-free.

const _M64 = 0xffffffffffffffff

@inline _mulhi(a::UInt32, b::UInt32) = (widemul(a, b) >>> 32) % UInt32
@inline _mulhi(a::UInt64, b::UInt64) = (widemul(a, b) >>> 64) % UInt64

@inline _lo64(x::UInt128) = x % UInt64
@inline _hi64(x::UInt128) = (x >>> 64) % UInt64

@inline _limbs(x::UInt128) = (_lo64(x), _hi64(x))
@inline _limbs(x::UInt256) =
    (x % UInt64, (x >> 64) % UInt64, (x >> 128) % UInt64, (x >> 192) % UInt64)

@inline _u128(hi::UInt64, lo::UInt64) = (UInt128(hi) << 64) | UInt128(lo)

@inline _u256(l0::UInt64, l1::UInt64, l2::UInt64, l3::UInt64) =
    (UInt256(l3) << 192) | (UInt256(l2) << 128) | (UInt256(l1) << 64) | UInt256(l0)

# full 128x128 -> 256 product as (hi::UInt128, lo::UInt128)
@inline function _mul128full(a::UInt128, b::UInt128)
    al, ah = _lo64(a), _hi64(a)
    bl, bh = _lo64(b), _hi64(b)
    ll = widemul(al, bl)
    lh = widemul(al, bh)
    hl = widemul(ah, bl)
    hh = widemul(ah, bh)
    # mid sums three 64-bit quantities: fits UInt128 with no overflow
    mid = UInt128(_hi64(ll)) + UInt128(_lo64(lh)) + UInt128(_lo64(hl))
    lo = _u128(_lo64(mid), _lo64(ll))
    hi = hh + UInt128(_hi64(lh)) + UInt128(_hi64(hl)) + UInt128(_hi64(mid))
    return (hi, lo)
end

@inline function _mulhi(a::UInt128, b::UInt128)
    hi, _ = _mul128full(a, b)
    return hi
end

@inline function _widemul256(a::UInt128, b::UInt128)
    hi, lo = _mul128full(a, b)
    return (UInt256(hi) << 128) | UInt256(lo)
end

# one column of a schoolbook multiply: add partial products into (acc, hic)
# acc accumulates low halves + incoming carry; hic accumulates high halves
@inline function _mulcol(acc::UInt128, hic::UInt128, a::UInt64, b::UInt64)
    p = widemul(a, b)
    return (acc + UInt128(_lo64(p)), hic + UInt128(_hi64(p)))
end

# full 256x256 -> 512 product as (hi::UInt256, lo::UInt256), schoolbook comba
@inline function _mul256full(a::UInt256, b::UInt256)
    a0, a1, a2, a3 = _limbs(a)
    b0, b1, b2, b3 = _limbs(b)
    # column 0
    p = widemul(a0, b0)
    r0 = _lo64(p)
    carry = UInt128(_hi64(p))
    # column 1
    acc, hic = _mulcol(carry, UInt128(0), a0, b1)
    acc, hic = _mulcol(acc, hic, a1, b0)
    r1 = _lo64(acc)
    carry = UInt128(_hi64(acc)) + hic
    # column 2
    acc, hic = _mulcol(carry, UInt128(0), a0, b2)
    acc, hic = _mulcol(acc, hic, a1, b1)
    acc, hic = _mulcol(acc, hic, a2, b0)
    r2 = _lo64(acc)
    carry = UInt128(_hi64(acc)) + hic
    # column 3
    acc, hic = _mulcol(carry, UInt128(0), a0, b3)
    acc, hic = _mulcol(acc, hic, a1, b2)
    acc, hic = _mulcol(acc, hic, a2, b1)
    acc, hic = _mulcol(acc, hic, a3, b0)
    r3 = _lo64(acc)
    carry = UInt128(_hi64(acc)) + hic
    # column 4
    acc, hic = _mulcol(carry, UInt128(0), a1, b3)
    acc, hic = _mulcol(acc, hic, a2, b2)
    acc, hic = _mulcol(acc, hic, a3, b1)
    r4 = _lo64(acc)
    carry = UInt128(_hi64(acc)) + hic
    # column 5
    acc, hic = _mulcol(carry, UInt128(0), a2, b3)
    acc, hic = _mulcol(acc, hic, a3, b2)
    r5 = _lo64(acc)
    carry = UInt128(_hi64(acc)) + hic
    # column 6
    acc, hic = _mulcol(carry, UInt128(0), a3, b3)
    r6 = _lo64(acc)
    carry = UInt128(_hi64(acc)) + hic
    r7 = _lo64(carry)
    return (_u256(r4, r5, r6, r7), _u256(r0, r1, r2, r3))
end

@inline function _mulhi(a::UInt256, b::UInt256)
    hi, _ = _mul256full(a, b)
    return hi
end

# x * m for a limb-sized multiplier whose product is known to fit 256 bits:
# four 64x64 products with a carry chain instead of a full 256x256 multiply
@inline function _mul256x64(x::UInt256, m::UInt64)
    p0 = widemul(x % UInt64, m)
    p1 = widemul((x >> 64) % UInt64, m) + (p0 >> 64)
    p2 = widemul((x >> 128) % UInt64, m) + (p1 >> 64)
    p3 = widemul((x >> 192) % UInt64, m) + (p2 >> 64)
    return UInt256(p0 % UInt64) | (UInt256(p1 % UInt64) << 64) |
           (UInt256(p2 % UInt64) << 128) | (UInt256(p3 % UInt64) << 192)
end
