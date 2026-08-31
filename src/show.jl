# Printing and (M1-simple) parsing. print/string give the plain decimal form;
# show gives a round-trippable typed form. The fast SWAR parser and formatter
# land with the Parsers.jl integration (M3); these are the correct simple
# versions.

function _printdecimal(io::IO, u::Integer, s::Int)
    neg = u < zero(u)
    neg && print(io, '-')
    digits = string(_tomag256(u), base=10)
    n = ncodeunits(digits)
    if s == 0
        print(io, digits)
    elseif n <= s
        print(io, "0.")
        for _ in 1:(s - n)
            print(io, '0')
        end
        print(io, digits)
    else
        print(io, SubString(digits, 1, n - s), '.', SubString(digits, n - s + 1, n))
    end
    return nothing
end

Base.print(io::IO, x::AbstractDecimal) = _printdecimal(io, x.unscaled, scale(x))

function Base.show(io::IO, x::Decimal{P, S, T}) where {P, S, T <: StorageInt}
    if get(io, :compact, false)::Bool
        _printdecimal(io, x.unscaled, S)
        return nothing
    end
    print(io, "Decimal{", P, ",", S, ",", T, "}(\"")
    _printdecimal(io, x.unscaled, S)
    print(io, "\")")
    return nothing
end

function Base.show(io::IO, x::DecimalValue{T}) where {T <: StorageInt}
    if get(io, :compact, false)::Bool
        _printdecimal(io, x.unscaled, scale(x))
        return nothing
    end
    print(io, "DecimalValue{", T, "}(\"")
    _printdecimal(io, x.unscaled, scale(x))
    print(io, "\")")
    return nothing
end

# ---- simple parsing ----

# largest magnitude that can safely take one more digit
const _PARSEMAX = (typemax(UInt256) - UInt256(9)) ÷ UInt256(10)

# parse ±digits[.digits][eE±digits] into (mag, sc, neg): value == ±mag * 10^-sc
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
    i > j && return (zero(UInt256), 0, false, false)
    neg = false
    if b[i] == UInt8('-') || b[i] == UInt8('+')
        neg = b[i] == UInt8('-')
        i += 1
    end
    mag = zero(UInt256)
    ndig = 0
    frac = -1  # count of fractional digits once '.' seen
    while i <= j
        c = b[i]
        if UInt8('0') <= c <= UInt8('9')
            mag > _PARSEMAX &&
                throw(OverflowError("too many digits in decimal string"))
            mag = mag * UInt256(10) + UInt256(c - UInt8('0'))
            ndig += 1
            frac >= 0 && (frac += 1)
            i += 1
        elseif c == UInt8('.')
            frac >= 0 && return (mag, 0, neg, false)  # second point
            frac = 0
            i += 1
        elseif c == UInt8('e') || c == UInt8('E')
            break
        else
            return (mag, 0, neg, false)
        end
    end
    ndig == 0 && return (mag, 0, neg, false)
    sc = max(frac, 0)
    if i <= j  # exponent
        i += 1  # consume e/E
        eneg = false
        if i <= j && (b[i] == UInt8('-') || b[i] == UInt8('+'))
            eneg = b[i] == UInt8('-')
            i += 1
        end
        i > j && return (mag, sc, neg, false)
        ev = 0
        while i <= j
            c = b[i]
            UInt8('0') <= c <= UInt8('9') || return (mag, sc, neg, false)
            ev = min(ev * 10 + Int(c - UInt8('0')), 100_000)
            i += 1
        end
        sc = eneg ? sc + ev : sc - ev
    end
    return (mag, sc, neg, true)
end

function Base.parse(::Type{Decimal{P, S, T}}, s::AbstractString) where {P, S, T <: StorageInt}
    mag, sc, neg, ok = _parsecore(s)
    ok || throw(ArgumentError("invalid decimal string: $(repr(s))"))
    return _torescaled(Decimal{P, S, T}, mag, neg, sc, nothing, s)
end

Base.parse(::Type{Decimal{P, S}}, s::AbstractString) where {P, S} =
    parse(Decimal{P, S, _storagetype(P)}, s)

function Base.parse(::Type{DecimalValue{T}}, s::AbstractString) where {T <: StorageInt}
    mag, sc, neg, ok = _parsecore(s)
    ok || throw(ArgumentError("invalid decimal string: $(repr(s))"))
    if sc < 0
        mag, ovf = _scaleup(mag, -sc)
        ovf && _throwoverflow(DecimalValue{T}, s)
        sc = 0
    end
    sc > 16383 && _throwoverflow(DecimalValue{T}, s)
    !_fitsigned(mag, neg, T) && _throwoverflow(DecimalValue{T}, s)
    u = (mag % _utype(T)) % T
    return DecimalValue{T}(neg ? -u : u, sc)
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
