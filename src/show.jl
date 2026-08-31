# Printing and (M1-simple) parsing. print/string give the plain decimal form;
# show gives a round-trippable typed form. The fast SWAR parser and formatter
# land with the Parsers.jl integration (M3); these are the correct simple
# versions.

Base.print(io::IO, x::AbstractDecimal) = print(io, string(x))

function Base.show(io::IO, x::Decimal{P, S, T}) where {P, S, T <: StorageInt}
    if get(io, :compact, false)::Bool
        print(io, string(x))
        return nothing
    end
    print(io, "Decimal{", P, ",", S, ",", T, "}(\"", string(x), "\")")
    return nothing
end

function Base.show(io::IO, x::DecimalValue{T}) where {T <: StorageInt}
    if get(io, :compact, false)::Bool
        print(io, string(x))
        return nothing
    end
    print(io, "DecimalValue{", T, "}(\"", string(x), "\")")
    return nothing
end

# ---- simple parsing ----

# largest magnitude that can take one more digit while staying < 10^77:
# 10^76 - 1 (77 retained significant digits; more become the sticky tail)
const _ACCMAX = _upow10(UInt256, 76) - one(UInt256)

# parse ±digits[.digits][eE±digits] into (mag, sc, neg, sticky, ok):
# value == ±(mag + sticky·ε) * 10^-sc, mag retaining 77 significant digits
function _parsecore(s::AbstractString)
    b = codeunits(s)
    n = length(b)
    i = 1
    while i <= n && (b[i] == UInt8(' ') || b[i] == UInt8('\t'))
        i += 1
    end
    j = n
    while j >= i && (b[j] == UInt8(' ') || b[j] == UInt8('\t'))
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

function Base.parse(::Type{Decimal{P, S, T}}, s::AbstractString) where {P, S, T <: StorageInt}
    mag, sc, neg, sticky, ok = _parsecore(s)
    ok || throw(ArgumentError("invalid decimal string: $(repr(s))"))
    v, fit = _fitdecimal(Decimal{P, S, T}, mag, sc, neg, sticky, RoundNearest)
    fit || _throwoverflow(Decimal{P, S, T}, s)
    return v
end

function Base.parse(::Type{DecimalValue{T}}, s::AbstractString) where {T <: StorageInt}
    mag, sc, neg, sticky, ok = _parsecore(s)
    ok || throw(ArgumentError("invalid decimal string: $(repr(s))"))
    v, fit = _fitvalue(DecimalValue{T}, mag, sc, neg, sticky)
    fit || _throwoverflow(DecimalValue{T}, s)
    return v
end

function Base.tryparse(::Type{DT}, s::AbstractString) where {DT <: Union{Decimal, DecimalValue}}
    try
        return parse(DT, s)
    catch e
        e isa InterruptException && rethrow()
        return nothing
    end
end

Decimal{P, S, T}(s::AbstractString) where {P, S, T <: StorageInt} = parse(Decimal{P, S, T}, s)
Decimal{P, S}(s::AbstractString) where {P, S} = parse(Decimal{P, S, _storagetype(P)}, s)
DecimalValue{T}(s::AbstractString) where {T <: StorageInt} = parse(DecimalValue{T}, s)
DecimalValue(s::AbstractString) = parse(DecimalValue{Int64}, s)
