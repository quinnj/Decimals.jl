# Printing and simple parsing. print/string give the plain decimal form; show
# gives a round-trippable typed form. The fast byte-level parser lives in the
# Parsers.jl extension; the core parser here is the correct simple version
# with identical semantics.

Base.print(io::IO, x::AbstractDecimal) = print(io, string(x))

# Human-facing display: plain positional form normally, scientific notation
# once the plain form gets unwieldy (deep-scale DecimalValues). string/print
# always stay positional — they are the wire format.
function Base.show(io::IO, ::MIME"text/plain", x::AbstractDecimal)
    if decimallength(x) > 44
        _showsci(io, x)
    else
        print(io, string(x))
    end
    return nothing
end

function _showsci(io::IO, x::AbstractDecimal)
    m = _mag(x)
    nd = _ndigits10(m)
    e = (nd - 1) - scale(x)
    buf = Base.StringVector(nd)
    _writemag!(buf, 1, nd, m)
    _isneg(x) && print(io, '-')
    print(io, Char(buf[1]))
    if nd > 1
        print(io, '.')
        unsafe_write(io, pointer(buf) + 1, nd - 1)
    end
    print(io, 'E', e < 0 ? '-' : '+', abs(e))
    return nothing
end

# wide storage types print qualified so typed show round-trips from a clean
# `using Decimals` namespace
function _printstoragetype(io::IO, ::Type{T}) where {T <: StorageInt}
    print(io, T === Int256 ? "Decimals.Int256" : string(T))
    return nothing
end

function Base.show(io::IO, x::Decimal{P, S, T}) where {P, S, T <: StorageInt}
    if get(io, :compact, false)::Bool
        print(io, string(x))
        return nothing
    end
    print(io, "Decimal{", P, ",", S, ",")
    _printstoragetype(io, T)
    print(io, "}(\"", string(x), "\")")
    return nothing
end

function Base.show(io::IO, x::DecimalValue{T}) where {T <: StorageInt}
    if get(io, :compact, false)::Bool
        print(io, string(x))
        return nothing
    end
    print(io, "DecimalValue{")
    _printstoragetype(io, T)
    print(io, "}(\"", string(x), "\")")
    return nothing
end

# ---- simple parsing ----

# largest magnitude that can take one more digit while staying < 10^77:
# 10^76 - 1 (77 retained significant digits; more become the sticky tail)
const _ACCMAX = _upow10(UInt256, 76) - one(UInt256)

# Base's ASCII numeric whitespace at input boundaries
@inline function _isparsespace(c)
    return c == UInt8(' ') || UInt8('\t') <= c <= UInt8('\r')
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

# Same per-byte scan for spans of 17..40 bytes with a UInt128 accumulator:
# up to 38 significant digits (every database decimal). Longer or unusual
# input defers to the general scanner. Returns (m, sc, neg, handled).
@inline function _scanmid(buf::AbstractVector{UInt8}, i::Int, j::Int, dec::UInt8)
    @inbounds begin
        b = buf[i]
        neg = b == UInt8('-')
        i += Int(neg | (b == UInt8('+')))
        m = UInt128(0)
        ndig = 0
        while i <= j
            d = buf[i] - UInt8('0')
            d > 0x09 && break
            m = m * UInt128(10) + d
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
                m = m * UInt128(10) + d
                i += 1
            end
            sc = i - fs
            ndig += sc
        end
        (i <= j || ndig == 0 || ndig > 38) && return (UInt128(0), 0, neg, false)
        return (m, sc, neg, true)
    end
end

# parse ±digits[.digits][eE±digits] into (mag, sc, neg, sticky, ok):
# value == ±(mag + sticky·ε) * 10^-sc, mag retaining 77 significant digits
function _parsecore(s::AbstractString)
    b = codeunits(s)
    n = length(b)
    i = 1
    while i <= n && _isparsespace(b[i])
        i += 1
    end
    j = n
    while j >= i && _isparsespace(b[j])
        j -= 1
    end
    i > j && return (zero(UInt256), 0, false, false, false)
    neg = false
    if b[i] == UInt8('-') || b[i] == UInt8('+')
        neg = b[i] == UInt8('-')
        i += 1
    end
    mag = zero(UInt256)
    sticky = false
    dropint = 0
    fracacc = 0
    ndig = 0
    frac = -1  # count of fractional digits once '.' seen
    while i <= j
        c = b[i]
        if UInt8('0') <= c <= UInt8('9')
            d = c - UInt8('0')
            if mag <= _ACCMAX
                mag = mag * UInt256(10) + UInt256(d)
                frac >= 0 && (fracacc += 1)
            else
                sticky |= d != 0x00
                frac < 0 && (dropint += 1)
            end
            ndig += 1
            i += 1
        elseif c == UInt8('.')
            frac >= 0 && return (mag, 0, neg, false, false)  # second point
            frac = 0
            i += 1
        elseif c == UInt8('e') || c == UInt8('E')
            break
        else
            return (mag, 0, neg, false, false)
        end
    end
    ndig == 0 && return (mag, 0, neg, false, false)
    sc = fracacc - dropint
    if i <= j  # exponent
        i += 1  # consume e/E
        eneg = false
        if i <= j && (b[i] == UInt8('-') || b[i] == UInt8('+'))
            eneg = b[i] == UInt8('-')
            i += 1
        end
        i > j && return (mag, sc, neg, sticky, false)
        ev = 0
        while i <= j
            c = b[i]
            UInt8('0') <= c <= UInt8('9') || return (mag, sc, neg, sticky, false)
            ev = min(ev * 10 + Int(c - UInt8('0')), 1_000_000)
            i += 1
        end
        sc = eneg ? sc + ev : sc - ev
    end
    return (mag, sc, neg, sticky, true)
end

# Parsing rounds (half-even) at the target scale, like parse(Float64, s) and
# every other cross-representation parse in the ecosystem; exact-scale wire
# values are unaffected. convert/constructors from other number types remain
# exact-or-throw, and the Parsers.jl extension exposes rounding= for control.
# parse targets with the storage type defaulted from the precision
_parsetarget(::Type{Decimal{P, S, T}}) where {P, S, T <: StorageInt} = Decimal{P, S, T}
_parsetarget(::Type{Decimal{P, S}}) where {P, S} = Decimal{P, S, _storagetype(P)}
_parsetarget(::Type{DecimalValue{T}}) where {T <: StorageInt} = DecimalValue{T}
_parsetarget(::Type{DecimalValue}) = DecimalValue{Int64}

_fittiny(::Type{DT}, m::Union{UInt64, UInt128}, sc::Int, neg::Bool) where {DT <: Decimal} =
    _fitdecimal(DT, m, sc, neg, false, RoundNearest)
_fittiny(::Type{DT}, m::Union{UInt64, UInt128}, sc::Int, neg::Bool) where {DT <: DecimalValue} =
    _fitvalue(DT, UInt256(m), sc, neg, false)

# whole-string fast path for plain tokens ([+-]digits[.digits]): a UInt64
# scan up to 16 bytes, a UInt128 scan up to 40; returns (value, handled, fit)
# — anything else falls to the general scanner, which owns whitespace,
# exponents, and rejection
@inline function _parsetiny(::Type{DT}, s::AbstractString) where {DT}
    b = codeunits(s)
    n = length(b)
    if 1 <= n <= 16
        m, sc, neg, handled = _scantiny(b, 1, n, UInt8('.'))
        handled || return (zero(DT), false, false)
        v, fit = _fittiny(DT, m, sc, neg)
        return (v, true, fit)
    elseif 17 <= n <= 40
        m, sc, neg, handled = _scanmid(b, 1, n, UInt8('.'))
        handled || return (zero(DT), false, false)
        v, fit = _fittiny(DT, m, sc, neg)
        return (v, true, fit)
    end
    return (zero(DT), false, false)
end

function Base.parse(::Type{Decimal{P, S, T}}, s::AbstractString) where {P, S, T <: StorageInt}
    v, handled, fit = _parsetiny(Decimal{P, S, T}, s)
    if handled
        fit || _throwoverflow(Decimal{P, S, T}, s)
        return v
    end
    mag, sc, neg, sticky, ok = _parsecore(s)
    ok || throw(ArgumentError("invalid decimal string: $(repr(s))"))
    v, fit = _fitdecimal(Decimal{P, S, T}, mag, sc, neg, sticky, RoundNearest)
    fit || _throwoverflow(Decimal{P, S, T}, s)
    return v
end

Base.parse(::Type{Decimal{P, S}}, s::AbstractString) where {P, S} =
    parse(Decimal{P, S, _storagetype(P)}, s)

function Base.parse(::Type{DecimalValue{T}}, s::AbstractString) where {T <: StorageInt}
    v, handled, fit = _parsetiny(DecimalValue{T}, s)
    if handled
        fit || _throwoverflow(DecimalValue{T}, s)
        return v
    end
    mag, sc, neg, sticky, ok = _parsecore(s)
    ok || throw(ArgumentError("invalid decimal string: $(repr(s))"))
    v, fit = _fitvalue(DecimalValue{T}, mag, sc, neg, sticky)
    fit || _throwoverflow(DecimalValue{T}, s)
    return v
end

function Base.tryparse(::Type{DT0}, s::AbstractString) where {DT0 <: Union{Decimal, DecimalValue}}
    DT = _parsetarget(DT0)
    v, handled, fit = _parsetiny(DT, s)
    handled && return fit ? v : nothing
    try
        return parse(DT, s)
    catch e
        e isa Union{ArgumentError, InexactError, OverflowError} && return nothing
        rethrow()
    end
end

Decimal{P, S, T}(s::AbstractString) where {P, S, T <: StorageInt} = parse(Decimal{P, S, T}, s)
Decimal{P, S}(s::AbstractString) where {P, S} = parse(Decimal{P, S, _storagetype(P)}, s)
DecimalValue{T}(s::AbstractString) where {T <: StorageInt} = parse(DecimalValue{T}, s)
DecimalValue(s::AbstractString) = parse(DecimalValue{Int64}, s)
