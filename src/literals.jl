# Decimal string literals and normalization.

# strip digit-group underscores, rejecting them at the ends or adjacent to
# the decimal point / exponent marker (matching the registered package's rule)
function _stripseparators(s::AbstractString)
    occursin('_', s) || return s
    occursin(r"^_|_$|_\.|\._|_[eE]|[eE]_|^[+-]_", s) &&
        throw(ArgumentError("invalid decimal literal: $(repr(s))"))
    return replace(s, "_" => "")
end

function _decliteral(str::AbstractString)
    s = _stripseparators(str)
    mag, sc, neg, sticky, ok = _parsecore(s)
    ok || throw(ArgumentError("invalid decimal literal: $(repr(str))"))
    sticky &&
        throw(ArgumentError("decimal literal $(repr(str)) exceeds 77 significant digits"))
    if sc < 0
        mag, ovf = _scaleup(mag, -sc)
        ovf && throw(ArgumentError("decimal literal $(repr(str)) is too large"))
        sc = 0
    end
    nd = mag == zero(UInt256) ? 1 : _ndigits10(mag)
    P = max(nd, sc)
    if P <= 76
        T = _storagetype(P)
        u = (mag % _utype(T)) % T
        return reinterpret(Decimal{P, sc, T}, neg ? -u : u)
    end
    # beyond the fixed family: a runtime-scale value when Int256 can hold it
    if sc <= 16383 && _fitsigned(mag, neg, Int256)
        u = mag % Int256
        return DecimalValue{Int256}(neg ? -u : u, sc)
    end
    throw(ArgumentError("cannot represent decimal literal $(repr(str))"))
end

"""
    dec"1.25"

An exact decimal literal. Produces the minimal-fitting `Decimal{P,S}` (so
`dec"1.25" isa Decimal{3,2,Int32}`), constant-folded at parse time; literals
beyond 76 digits of precision fall back to a `DecimalValue{Int256}`. Digit
groups may be separated with underscores (`dec"1_000_000.25"`). The literal
must be exactly representable — no silent rounding.
"""
macro dec_str(s)
    return _decliteral(s)
end

"""
    normalize(x) -> DecimalValue

The value of `x` with all trailing zeros removed from the coefficient and the
scale reduced to match (scales never go below zero, so integer values keep
scale 0): `normalize(dec"1.2000") == DecimalValue(12, 1)`.
"""
function normalize(x::AbstractDecimal)
    T = _storage(typeof(x))
    u, s = _strip10s(x.unscaled, scale(x))
    return DecimalValue{T}(u, s)
end

# greedy chunked removal of trailing decimal zeros, mirroring _strip5s
@inline function _strip10u64(m::UInt64, left::Int)
    for k in (16, 8, 4, 2, 1)
        while left >= k
            d = UInt64(10)^k
            q, r = divrem(m, d)
            r == zero(UInt64) || break
            m = q
            left -= k
        end
    end
    return (m, left)
end

function _strip10s(u::T, s::Int) where {T <: StorageInt}
    u == zero(T) && return (zero(T), 0)
    s == 0 && return (u, 0)
    mw = _tomag256(u)
    left = s
    if mw > UInt256(typemax(UInt64))
        for k in (19, 9, 4, 2, 1)
            while left >= k
                q, r = _divrem_by1(mw, UInt64(10)^k)
                r == zero(UInt256) || break
                mw = q
                left -= k
            end
            mw <= UInt256(typemax(UInt64)) && break
        end
    end
    if mw <= UInt256(typemax(UInt64)) && left > 0
        m64, left = _strip10u64(mw % UInt64, left)
        mw = UInt256(m64)
    end
    v = (mw % _utype(T)) % T
    return (u < zero(T) ? -v : v, left)
end
