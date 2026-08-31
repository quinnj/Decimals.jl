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

# accumulate the digit run buf[k:kend] into mag, retaining at most 77
# significant digits; further digits are dropped (counted, sticky on nonzero)
@inline function _accum(buf::AbstractVector{UInt8}, k::Int, kend::Int,
                        mag::UInt256, sticky::Bool)
    dropped = 0
    while k <= kend
        nd = mag == zero(UInt256) ? 0 : _ndigits10(mag)
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
        k += n
    end
    return (mag, dropped, sticky)
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
    sticky = false
    dropint = 0
    fracacc = 0
    e1 = Parsers._digitrunend(buf, i, j)
    intdigits = e1 - i
    if intdigits > 0
        mag, dropped, sticky = _accum(buf, i, e1 - 1, mag, sticky)
        dropint += dropped
        i = e1
    end
    fracdigits = 0
    @inbounds if i <= j && buf[i] == dec
        k = i + 1
        e2 = Parsers._digitrunend(buf, k, j)
        fracdigits = e2 - k
        if fracdigits > 0
            mag, dropped, sticky = _accum(buf, k, e2 - 1, mag, sticky)
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
        k = i + 1
        eneg = false
        if k <= j && (buf[k] == UInt8('-') || buf[k] == UInt8('+'))
            eneg = buf[k] == UInt8('-')
            k += 1
        end
        e3 = Parsers._digitrunend(buf, k, j)
        if e3 > k
            ev = 0
            for p in k:(e3 - 1)
                ev = min(ev * 10 + Int(buf[p] - UInt8('0')), 1_000_000)
            end
            sc = eneg ? sc + ev : sc - ev
            i = e3
        end
        # exponent marker without digits: token ends before the marker
    end
    return (mag, sc, neg, sticky, i, true)
end

@inline _fit(::Type{DT}, mag, sc, neg, sticky,
             mode) where {DT <: Decimal} = _fitdecimal(DT, mag, sc, neg, sticky, mode)
@inline _fit(::Type{DT}, mag, sc, neg, sticky,
             mode) where {DT <: DecimalValue} = _fitvalue(DT, mag, sc, neg, sticky)

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
