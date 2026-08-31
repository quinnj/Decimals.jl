# Parsers.jl integration: fast byte-level decimal parsing built on the Parsers
# 3.0 SWAR kernels (_digitrunend/_digits19 gulps), with a single-pass scanner
# that recognizes the token and accumulates the wide coefficient together —
# up to 77 retained significant digits plus a sticky tail, so rounding into
# any Decimal target is correct for arbitrarily long inputs.
module DecimalsParsersExt

using Decimals
using Decimals: AbstractDecimal, StorageInt, _fitdecimal, _fitvalue,
                _storagetype, _ndigits10, _scaleup
using BitIntegers: UInt256
import Parsers
using Parsers: RC_OK, RC_INVALID, RC_OVERFLOW

# fill in defaulted type parameters for parse targets
_fullT(::Type{Decimal{P, S, T}}) where {P, S, T <: StorageInt} = Decimal{P, S, T}
_fullT(::Type{Decimal{P, S}}) where {P, S} = Decimal{P, S, _storagetype(P)}
_fullT(::Type{DecimalValue{T}}) where {T <: StorageInt} = DecimalValue{T}
_fullT(::Type{DecimalValue}) = DecimalValue{Int64}

# accumulate the digit run buf[k:kend] into mag (whose significant digit
# count is nd, 0 for zero), retaining at most 77 significant digits; further
# digits are dropped (counted, sticky on nonzero)
@inline function _accum(buf::AbstractVector{UInt8}, k::Int, kend::Int,
                        mag::UInt256, nd::Int, sticky::Bool)
    dropped = 0
    while k <= kend
        room = 77 - nd
        if room <= 0
            @inbounds while k <= kend
                sticky |= buf[k] != UInt8('0')
                k += 1
                dropped += 1
            end
            break
        end
        n = min(19, kend - k + 1, room)
        chunk, _ = Parsers._digits19(buf, k, n)
        mag, _ = _scaleup(mag, n)  # cannot overflow: nd + n <= 77
        mag += UInt256(chunk)
        nd = nd == 0 ? (mag == zero(UInt256) ? 0 : _ndigits10(mag)) : nd + n
        k += n
    end
    return (mag, nd, dropped, sticky)
end

# exponent tail at buf[i] (== e/E): returns (sc adjustment, nextpos); an
# exponent marker without digits ends the token before the marker
@inline function _scanexp(buf::AbstractVector{UInt8}, i::Int, j::Int)
    k = i + 1
    eneg = false
    @inbounds if k <= j && (buf[k] == UInt8('-') || buf[k] == UInt8('+'))
        eneg = buf[k] == UInt8('-')
        k += 1
    end
    e3 = Parsers._digitrunend(buf, k, j)
    e3 == k && return (0, i)
    ev = 0
    @inbounds for p in k:(e3 - 1)
        ev = min(ev * 10 + Int(buf[p] - UInt8('0')), 1_000_000)
    end
    return (eneg ? ev : -ev, e3)
end

# Per-byte whole-token parse for spans of 1..16 bytes: [+-]digits[.digits],
# two tight loops (integer run, then fraction run) so no per-digit scale
# bookkeeping. Anything else — exponents, weird bytes, leftovers — defers to
# the general scanner, which also owns rejecting genuinely invalid input.
# The branchy per-byte form beats wide SWAR here: short varied tokens keep
# these branches well-predicted, and there is no clamped-gather tail.
# Returns (m, sc, neg, handled).
@inline function _scantiny(buf::AbstractVector{UInt8}, i::Int, j::Int, dec::UInt8)
    @inbounds begin
        b = buf[i]
        neg = b == UInt8('-')
        i += Int(neg | (b == UInt8('+')))
        m = UInt64(0)
        ndig = 0
        while i <= j
            d = buf[i] - UInt8('0')
            d > 0x09 && break
            m = m * UInt64(10) + d
            ndig += 1
            i += 1
        end
        sc = 0
        if i <= j && buf[i] == dec
            i += 1
            fs = i
            while i <= j
                d = buf[i] - UInt8('0')
                d > 0x09 && break
                m = m * UInt64(10) + d
                i += 1
            end
            sc = i - fs
            ndig += sc
        end
        (i <= j || ndig == 0) && return (UInt64(0), 0, neg, false)
        return (m, sc, neg, true)
    end
end

# skip a run of ASCII zeros, SWAR-wide then per byte
@inline function _skipzeros(buf::AbstractVector{UInt8}, k::Int, j::Int)
    @inbounds while k <= j && j - k >= 7
        Parsers._load8(buf, k) == 0x3030303030303030 || break
        k += 8
    end
    @inbounds while k <= j && buf[k] == UInt8('0')
        k += 1
    end
    return k
end

# fused digit-run consumer: recognize and accumulate in one pass (the float
# parser's load8/_alldigits8/_rundigits idiom). Stops at the first non-digit;
# cnt > 19 signals the caller to fall back to a wider scanner.
@inline function _scanrun64(buf::AbstractVector{UInt8}, k::Int, j::Int,
                            m::UInt64, cnt::Int)
    @inbounds while k <= j && j - k >= 7
        w = Parsers._load8(buf, k)
        if Parsers._alldigits8(w)
            cnt += 8
            cnt > 19 && return (m, k, cnt)
            m = m * UInt64(100_000_000) + Parsers._digits8(w)
            k += 8
        else
            nd = Parsers._firstnondigit8(w)
            if nd > 0
                cnt += nd
                cnt > 19 && return (m, k, cnt)
                d, _ = Parsers._rundigits(w, nd)
                m = m * @inbounds(Parsers._POW10U64[nd + 1]) + d
                k += nd
            end
            return (m, k, cnt)
        end
    end
    @inbounds if k <= j
        w = Parsers._gather8(buf, k, j)
        nd = min(Parsers._firstnondigit8(w), j - k + 1)
        if nd > 0
            cnt += nd
            cnt > 19 && return (m, k, cnt)
            d, _ = Parsers._rundigits(w, nd)
            m = m * @inbounds(Parsers._POW10U64[nd + 1]) + d
            k += nd
        end
    end
    return (m, k, cnt)
end

# fast scan for tokens whose significant digits fit one UInt64 mantissa
# (<= 19, the overwhelmingly common case; leading zeros don't count).
# Returns (m, sc, neg, nextpos, ok, needwide); needwide=true means fall back
# to a wider scanner.
@inline function _scandec64(buf::AbstractVector{UInt8}, i::Int, j::Int, dec::UInt8)
    start = i
    i > j && return (UInt64(0), 0, false, start, false, false)
    @inbounds b = buf[i]
    neg = b == UInt8('-')
    (neg | (b == UInt8('+'))) && (i += 1)
    iz = _skipzeros(buf, i, j)
    sawint = iz > i
    m, i2, cnt = _scanrun64(buf, iz, j, UInt64(0), 0)
    cnt > 19 && return (UInt64(0), 0, false, start, false, true)
    sawint |= i2 > iz
    i = i2
    fracn = 0
    sawfrac = false
    @inbounds if i <= j && buf[i] == dec
        k = i + 1
        if m == zero(UInt64)
            kz = _skipzeros(buf, k, j)
            fracn += kz - k
            sawfrac |= kz > k
            k = kz
        end
        m, i2, cnt = _scanrun64(buf, k, j, m, cnt)
        cnt > 19 && return (UInt64(0), 0, false, start, false, true)
        fracn += i2 - k
        sawfrac |= i2 > k
        (sawint | sawfrac) || return (UInt64(0), 0, neg, start, false, false)
        i = i2  # equals k when the point had no digits after it ("1.")
    end
    (sawint | sawfrac) || return (UInt64(0), 0, neg, start, false, false)
    sc = fracn
    @inbounds if i <= j && (buf[i] == UInt8('e') || buf[i] == UInt8('E'))
        adj, i = _scanexp(buf, i, j)
        sc += adj
    end
    return (m, sc, neg, i, true, false)
end

# value of a 1..38-digit run as UInt128 (one or two 19-digit blocks)
@inline function _digits38(buf::AbstractVector{UInt8}, k::Int, n::Int)
    n <= 19 && return UInt128(Parsers._digits19(buf, k, n)[1])
    hi = Parsers._digits19(buf, k, 19)[1]
    lo = Parsers._digits19(buf, k + 19, n - 19)[1]
    return UInt128(hi) * Decimals._upow10(UInt128, n - 19) + UInt128(lo)
end

# middle tier: tokens whose digits fit UInt128 (<= 38 digits — every common
# database decimal). Returns (m::UInt128, sc, neg, nextpos, ok, needwide).
@inline function _scandec128(buf::AbstractVector{UInt8}, i::Int, j::Int, dec::UInt8)
    start = i
    Z = zero(UInt128)
    i > j && return (Z, 0, false, start, false, false)
    @inbounds b = buf[i]
    neg = b == UInt8('-')
    (neg | (b == UInt8('+'))) && (i += 1)
    e1 = Parsers._digitrunend(buf, i, j)
    intn = e1 - i
    intn > 38 && return (Z, 0, false, start, false, true)
    m = intn > 0 ? _digits38(buf, i, intn) : Z
    i = e1
    fracn = 0
    @inbounds if i <= j && buf[i] == dec
        k = i + 1
        e2 = Parsers._digitrunend(buf, k, j)
        fracn = e2 - k
        if fracn > 0
            intn + fracn > 38 && return (Z, 0, false, start, false, true)
            m = m * Decimals._upow10(UInt128, fracn) + _digits38(buf, k, fracn)
            i = e2
        elseif intn > 0
            i = k
        else
            return (Z, 0, neg, start, false, false)
        end
    end
    intn + fracn > 0 || return (Z, 0, neg, start, false, false)
    sc = fracn
    @inbounds if i <= j && (buf[i] == UInt8('e') || buf[i] == UInt8('E'))
        adj, i = _scanexp(buf, i, j)
        sc += adj
    end
    return (m, sc, neg, i, true, false)
end

# scan one decimal token at buf[i..j]: [+-] digits [dec digits] [eE [+-] digits]
# (at least one digit overall). Returns (mag, sc, neg, sticky, nextpos, ok)
# where the token value is ±(mag + sticky·ε) * 10^-sc; on !ok nextpos == i.
function _scandec(buf::AbstractVector{UInt8}, i::Int, j::Int, dec::UInt8)
    Z = zero(UInt256)
    start = i
    i > j && return (Z, 0, false, false, start, false)
    @inbounds b = buf[i]
    neg = b == UInt8('-')
    (neg | (b == UInt8('+'))) && (i += 1)
    mag = Z
    nd = 0
    sticky = false
    dropint = 0
    fracacc = 0
    e1 = Parsers._digitrunend(buf, i, j)
    intdigits = e1 - i
    if intdigits > 0
        mag, nd, dropped, sticky = _accum(buf, i, e1 - 1, mag, nd, sticky)
        dropint += dropped
        i = e1
    end
    fracdigits = 0
    @inbounds if i <= j && buf[i] == dec
        k = i + 1
        e2 = Parsers._digitrunend(buf, k, j)
        fracdigits = e2 - k
        if fracdigits > 0
            mag, nd, dropped, sticky = _accum(buf, k, e2 - 1, mag, nd, sticky)
            fracacc = fracdigits - dropped
            i = e2
        elseif intdigits > 0
            i = k  # trailing point after digits is consumed ("1.")
        else
            return (Z, 0, neg, false, start, false)
        end
    end
    intdigits + fracdigits > 0 || return (Z, 0, neg, false, start, false)
    sc = fracacc - dropint
    @inbounds if i <= j && (buf[i] == UInt8('e') || buf[i] == UInt8('E'))
        adj, i = _scanexp(buf, i, j)
        sc += adj
    end
    return (mag, sc, neg, sticky, i, true)
end

@inline _fit(::Type{DT}, mag, sc, neg, sticky,
             mode) where {DT <: Decimal} = _fitdecimal(DT, mag, sc, neg, sticky, mode)
@inline _fit(::Type{DT}, mag, sc, neg, sticky,
             mode) where {DT <: DecimalValue} =
    _fitvalue(DT, UInt256(mag), sc, neg, sticky)

@noinline _throwinvalid(::Type{DT}, buf, i, j) where {DT} =
    throw(ArgumentError(string("cannot parse ", Parsers._q(Parsers._spanstring(buf, i, j)),
                               " as ", DT)))
@noinline _throwrange(::Type{DT}, buf, i, j) where {DT} =
    throw(OverflowError(string("value ", Parsers._q(Parsers._spanstring(buf, i, j)),
                               " does not fit in ", DT)))

@inline function _parsewhole(::Type{DT}, buf::AbstractVector{UInt8}, i::Int, j::Int,
                             dec::UInt8, mode::RoundingMode,
                             ::Val{Throw}) where {DT, Throw}
    # hot path: unpadded short tokens skip even the whitespace strip — a
    # padded or exotic input simply fails over to the general scanner, which
    # strips and re-derives everything
    if 0 <= j - i <= 15
        m, sct, negt, handled = _scantiny(buf, i, j, dec)
        if handled
            v, fit = _fit(DT, m, sct, negt, false, mode)
            if !fit
                Throw && _throwrange(DT, buf, i, j)
                return nothing
            end
            return v
        end
    elseif j - i <= 41
        # mid-size tokens have > 19 digits almost surely: skip the doomed
        # UInt64 scan and go straight to the 38-digit block scanner (which
        # itself defers to the wide scanner when needed)
        i2, j2 = Parsers._stripws(buf, i, j)
        return _parsewholewide(DT, buf, i, j, i2, j2, dec, mode, Val(Throw))
    end
    return _parsegeneral(DT, buf, i, j, dec, mode, Val(Throw))
end

@noinline function _parsegeneral(::Type{DT}, buf::AbstractVector{UInt8},
                                 orig_i::Int, orig_j::Int,
                                 dec::UInt8, mode::RoundingMode,
                                 ::Val{Throw}) where {DT, Throw}
    i, j = Parsers._stripws(buf, orig_i, orig_j)
    m64, sc, neg, nextpos, ok, needwide = _scandec64(buf, i, j, dec)
    if !needwide
        if !(ok && nextpos > j)
            Throw && _throwinvalid(DT, buf, orig_i, orig_j)
            return nothing
        end
        v, fit = _fit(DT, m64, sc, neg, false, mode)
        if !fit
            Throw && _throwrange(DT, buf, orig_i, orig_j)
            return nothing
        end
        return v
    end
    return _parsewholewide(DT, buf, orig_i, orig_j, i, j, dec, mode, Val(Throw))
end

@noinline function _parsewholewide(::Type{DT}, buf::AbstractVector{UInt8},
                                   orig_i::Int, orig_j::Int, i::Int, j::Int,
                                   dec::UInt8, mode::RoundingMode,
                                   ::Val{Throw}) where {DT, Throw}
    m128, sc, neg, nextpos, ok, needwide = _scandec128(buf, i, j, dec)
    if !needwide
        if !(ok && nextpos > j)
            Throw && _throwinvalid(DT, buf, orig_i, orig_j)
            return nothing
        end
        v, fit = _fit(DT, m128, sc, neg, false, mode)
        if !fit
            Throw && _throwrange(DT, buf, orig_i, orig_j)
            return nothing
        end
        return v
    end
    mag, sc, neg, sticky, nextpos, ok = _scandec(buf, i, j, dec)
    if !(ok && nextpos > j)
        Throw && _throwinvalid(DT, buf, orig_i, orig_j)
        return nothing
    end
    v, fit = _fit(DT, mag, sc, neg, sticky, mode)
    if !fit
        Throw && _throwrange(DT, buf, orig_i, orig_j)
        return nothing
    end
    return v
end

const _DECTARGETS = Union{Decimal, DecimalValue}

@inline function Parsers.parse(::Type{T}, s::Union{AbstractString, AbstractVector{UInt8}};
                               decimal::Char='.',
                               rounding::RoundingMode=RoundNearest) where {T <: _DECTARGETS}
    DT = _fullT(T)
    GC.@preserve s begin
        buf = Parsers._bytes(s)
        return _parsewhole(DT, buf, 1, length(buf), Parsers._decimalbyte(decimal),
                           rounding, Val(true))::DT
    end
end

@inline function Parsers.tryparse(::Type{T}, s::Union{AbstractString, AbstractVector{UInt8}};
                                  decimal::Char='.',
                                  rounding::RoundingMode=RoundNearest) where {T <: _DECTARGETS}
    DT = _fullT(T)
    GC.@preserve s begin
        buf = Parsers._bytes(s)
        return _parsewhole(DT, buf, 1, length(buf), Parsers._decimalbyte(decimal),
                           rounding, Val(false))
    end
end

@inline function Parsers.parse(::Type{T}, buf::AbstractVector{UInt8},
                               first::Integer, last::Integer;
                               decimal::Char='.',
                               rounding::RoundingMode=RoundNearest) where {T <: _DECTARGETS}
    DT = _fullT(T)
    checkbounds(buf, first:last)
    bytes = Parsers._bytes(buf)
    i, j = Int(first), Int(last)
    if Parsers._needsindexwindow(j)
        window, i, j = Parsers._indexwindow(bytes, i, j)
        return _parsewhole(DT, window, i, j, Parsers._decimalbyte(decimal),
                           rounding, Val(true))::DT
    end
    return _parsewhole(DT, bytes, i, j, Parsers._decimalbyte(decimal),
                       rounding, Val(true))::DT
end

@inline function Parsers.tryparse(::Type{T}, buf::AbstractVector{UInt8},
                                  first::Integer, last::Integer;
                                  decimal::Char='.',
                                  rounding::RoundingMode=RoundNearest) where {T <: _DECTARGETS}
    DT = _fullT(T)
    checkbounds(buf, first:last)
    bytes = Parsers._bytes(buf)
    i, j = Int(first), Int(last)
    if Parsers._needsindexwindow(j)
        window, i, j = Parsers._indexwindow(bytes, i, j)
        return _parsewhole(DT, window, i, j, Parsers._decimalbyte(decimal),
                           rounding, Val(false))
    end
    return _parsewhole(DT, bytes, i, j, Parsers._decimalbyte(decimal),
                       rounding, Val(false))
end

@inline function _parsenextdec(::Type{DT}, b::AbstractVector{UInt8}, i::Int, j::Int,
                               dec::UInt8, mode::RoundingMode) where {DT}
    m64, sc, neg, nextpos, ok, needwide = _scandec64(b, i, j, dec)
    needwide && return _parsenextwide(DT, b, i, j, dec, mode)
    ok || return (zero(DT), i, RC_INVALID)
    (nextpos > j && j == typemax(Int)) && Parsers._prefixendoverflow()
    v, fit = _fit(DT, m64, sc, neg, false, mode)
    fit || return (zero(DT), nextpos, RC_OVERFLOW)
    return (v, nextpos, RC_OK)
end

@noinline function _parsenextwide(::Type{DT}, b::AbstractVector{UInt8}, i::Int, j::Int,
                                  dec::UInt8, mode::RoundingMode) where {DT}
    m128, sc, neg, nextpos, ok, needwide = _scandec128(b, i, j, dec)
    if !needwide
        ok || return (zero(DT), i, RC_INVALID)
        (nextpos > j && j == typemax(Int)) && Parsers._prefixendoverflow()
        v, fit = _fit(DT, m128, sc, neg, false, mode)
        fit || return (zero(DT), nextpos, RC_OVERFLOW)
        return (v, nextpos, RC_OK)
    end
    mag, sc, neg, sticky, nextpos, ok = _scandec(b, i, j, dec)
    ok || return (zero(DT), i, RC_INVALID)
    (nextpos > j && j == typemax(Int)) && Parsers._prefixendoverflow()
    v, fit = _fit(DT, mag, sc, neg, sticky, mode)
    fit || return (zero(DT), nextpos, RC_OVERFLOW)
    return (v, nextpos, RC_OK)
end

function Parsers.parsenext(::Type{T}, buf::AbstractVector{UInt8}, pos::Integer,
                           last::Integer; decimal::Char='.',
                           rounding::RoundingMode=RoundNearest) where {T <: _DECTARGETS}
    DT = _fullT(T)
    b, i, j = Parsers._prefixbounds(buf, pos, last)
    i > j && return (zero(DT), i, RC_INVALID)
    dec = Parsers._decimalbyte(decimal)
    return Parsers._runprefix((w, wi, wj) -> _parsenextdec(DT, w, wi, wj, dec, rounding),
                              b, i, j)
end

end # module
