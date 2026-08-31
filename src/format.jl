# Fast decimal formatting: two-digit lookup pairs, backwards fill, wide
# magnitudes split into 19-digit chunks with one magic divide each. The
# byte-level writedecimal! is the wire-writer API (MySQL params, CSV output);
# string/print build on it.

const _DIGITPAIRS = codeunits("00010203040506070809" *
                              "10111213141516171819" *
                              "20212223242526272829" *
                              "30313233343536373839" *
                              "40414243444546474849" *
                              "50515253545556575859" *
                              "60616263646566676869" *
                              "70717273747576777879" *
                              "80818283848586878889" *
                              "90919293949596979899")

# write the decimal digits of m into buf[lo:hi] exactly (zero-padded on the
# left); requires m < 10^(hi-lo+1)
@inline function _writeu64!(buf::AbstractVector{UInt8}, lo::Int, hi::Int, m::UInt64)
    i = hi
    @inbounds while m >= UInt64(100)
        q = m ÷ UInt64(100)
        r = Int(m - q * UInt64(100))
        buf[i - 1] = _DIGITPAIRS[2r + 1]
        buf[i] = _DIGITPAIRS[2r + 2]
        m = q
        i -= 2
    end
    @inbounds if m >= UInt64(10)
        r = Int(m)
        buf[i - 1] = _DIGITPAIRS[2r + 1]
        buf[i] = _DIGITPAIRS[2r + 2]
        i -= 2
    elseif i >= lo
        buf[i] = UInt8('0') + (m % UInt8)
        i -= 1
    end
    @inbounds while i >= lo
        buf[i] = UInt8('0')
        i -= 1
    end
    return nothing
end

# split a wide magnitude into (rest, low 19 digits)
@inline function _chop19(m::U) where {U <: Union{UInt128, UInt256}}
    q = _divpow10(m, 19)
    r = m - q * _upow10(U, 19)
    return (q, r % UInt64)
end

@inline function _writemag!(buf::AbstractVector{UInt8}, lo::Int, hi::Int, m::UInt64)
    return _writeu64!(buf, lo, hi, m)
end
@inline _writemag!(buf::AbstractVector{UInt8}, lo::Int, hi::Int, m::UInt32) =
    _writeu64!(buf, lo, hi, UInt64(m))

function _writemag!(buf::AbstractVector{UInt8}, lo::Int, hi::Int,
                    m::U) where {U <: Union{UInt128, UInt256}}
    while hi - lo >= 19 && m > U(typemax(UInt64))
        m, low = _chop19(m)
        _writeu64!(buf, hi - 18, hi, low)
        hi -= 19
    end
    return _writeu64!(buf, lo, hi, m % UInt64)
end

"""
    Decimals.decimallength(x) -> Int

Number of bytes `writedecimal!` produces for `x` (sign, digits, and decimal
point included).
"""
function decimallength(x::AbstractDecimal)
    m = _mag(x)
    s = scale(x)
    nd = _ndigits10(m)
    n = s == 0 ? nd : nd <= s ? s + 2 : nd + 1
    return n + Int(_isneg(x))
end

"""
    Decimals.writedecimal!(buf, pos, x) -> Int

Write the plain decimal form of `x` into `buf` starting at `pos`; returns the
first position after the written bytes. The caller must ensure
`decimallength(x)` bytes of room.
"""
function writedecimal!(buf::AbstractVector{UInt8}, pos::Int, x::AbstractDecimal)
    m = _mag(x)
    s = scale(x)
    nd = _ndigits10(m)
    @inbounds if _isneg(x)
        buf[pos] = UInt8('-')
        pos += 1
    end
    if s == 0
        _writemag!(buf, pos, pos + nd - 1, m)
        return pos + nd
    end
    @inbounds if nd <= s
        # 0.000ddd
        buf[pos] = UInt8('0')
        buf[pos + 1] = UInt8('.')
        _writemag!(buf, pos + 2, pos + s + 1, m)
        return pos + s + 2
    end
    # dddd.dddd: write the two runs separately, no splicing
    ip = nd - s
    q, r = _splitfrac(m, s)
    _writemag!(buf, pos, pos + ip - 1, q)
    @inbounds buf[pos + ip] = UInt8('.')
    _writemag!(buf, pos + ip + 1, pos + nd, r)
    return pos + nd + 1
end

# split magnitude into (integer part, fraction part) at scale s
@inline function _splitfrac(m::U, s::Int) where {U <: Unsigned}
    q = _divpow10(m, s)
    return (q, m - q * _upow10(U, s))
end

function Base.string(x::AbstractDecimal)
    n = decimallength(x)
    out = Base.StringVector(n)
    writedecimal!(out, 1, x)
    return String(out)
end

_printdecimal(io::IO, x::AbstractDecimal) = print(io, string(x))
