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

# fast scan for tokens whose digits fit one UInt64 mantissa (<= 19 digits, the
# overwhelmingly common case). Returns (m, sc, neg, nextpos, ok, needwide);
# needwide=true means fall back to the wide scanner.
@inline function _scandec64(buf::AbstractVector{UInt8}, i::Int, j::Int, dec::UInt8)
    start = i
    i > j && return (UInt64(0), 0, false, start, false, false)
    @inbounds b = buf[i]
    neg = b == UInt8('-')
    (neg | (b == UInt8('+'))) && (i += 1)
    e1 = Parsers._digitrunend(buf, i, j)
    intn = e1 - i
    intn > 19 && return (UInt64(0), 0, false, start, false, true)
    m = intn > 0 ? Parsers._digits19(buf, i, intn)[1] : UInt64(0)
    i = e1
    fracn = 0
    @inbounds if i <= j && buf[i] == dec
        k = i + 1
        e2 = Parsers._digitrunend(buf, k, j)
        fracn = e2 - k
        if fracn > 0
            intn + fracn > 19 && return (UInt64(0), 0, false, start, false, true)
            m = m * Parsers._POW10U64[fracn + 1] + Parsers._digits19(buf, k, fracn)[1]
            i = e2
        elseif intn > 0
            i = k  # trailing point after digits is consumed ("1.")
        else
            return (UInt64(0), 0, neg, start, false, false)
        end
    end
    intn + fracn > 0 || return (UInt64(0), 0, neg, start, false, false)
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
    orig_i, orig_j = i, j
    i, j = Parsers._stripws(buf, i, j)
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
