# Arithmetic. Semantics:
# - `+`/`-` promote both operands (value-preserving promotion) and compute at
#   that type, CHECKED: a result that no longer fits throws OverflowError.
#   Arithmetic never invents a wider type than promotion of its inputs, so
#   folds are type-stable; `sum` widens to the Int128 tier via Base.add_sum.
# - `*` is exact: scale S1+S2, precision min(P1+P2, 76), checked.
# - `/` rounds half-even at scale max(S1,S2); `divide(x, y, mode)` chooses the
#   mode. No global rounding state anywhere.

@inline _add_ovf(x::T, y::T) where {T <: Union{Int32, Int64, Int128}} =
    Base.Checked.add_with_overflow(x, y)
@inline _sub_ovf(x::T, y::T) where {T <: Union{Int32, Int64, Int128}} =
    Base.Checked.sub_with_overflow(x, y)

@inline function _add_ovf(x::Int256, y::Int256)
    r = x + y
    return r, ((x >= 0) == (y >= 0)) & ((r >= 0) != (x >= 0))
end
@inline function _sub_ovf(x::Int256, y::Int256)
    r = x - y
    return r, ((x >= 0) != (y >= 0)) & ((r >= 0) != (x >= 0))
end

@noinline _throwop(op, x, y) =
    throw(OverflowError(string(op, "(", x, ", ", y, ") overflows result type")))

for (op, kernel) in ((:+, :_add_ovf), (:-, :_sub_ovf))
    @eval begin
        @inline function Base.$op(x::Decimal{P, S, T}, y::Decimal{P, S, T}) where {P, S, T <: StorageInt}
            u, ovf = $kernel(x.unscaled, y.unscaled)
            (ovf || _mag(u) > _maxmag(Decimal{P, S, T})) && _throwop($(QuoteNode(op)), x, y)
            return reinterpret(Decimal{P, S, T}, u)
        end
        @inline function Base.$op(x::Decimal, y::Decimal)
            RT = promote_type(typeof(x), typeof(y))
            return $op(convert(RT, x), convert(RT, y))
        end
    end
end

# multiply result type: exact product parameters, capped at the 256-bit tier;
# @generated so the computed type is a compile-time constant for inference
@generated function _multype(::Type{Decimal{P1, S1, T1}},
                             ::Type{Decimal{P2, S2, T2}}) where {P1, S1, T1 <: StorageInt, P2, S2, T2 <: StorageInt}
    S = S1 + S2
    S <= 76 || return :(throw(ArgumentError(string("product scale ", $S1, "+", $S2,
                                                   " exceeds the maximum of 76"))))
    P = min(max(P1 + P2, S), 76)
    return :(Decimal{$P, $S, $(_storagetype(P))})
end

@inline function Base.:*(x::Decimal{P1, S1, T1},
                         y::Decimal{P2, S2, T2}) where {P1, S1, T1 <: StorageInt, P2, S2, T2 <: StorageInt}
    RT = _multype(Decimal{P1, S1, T1}, Decimal{P2, S2, T2})
    neg = _isneg(x) ⊻ _isneg(y)
    if sizeof(T1) <= 8 && sizeof(T2) <= 8
        m = widemul(_mag(x.unscaled) % UInt64, _mag(y.unscaled) % UInt64)
        m > UInt128(_maxmag(RT)) && _throwop(:*, x, y)
        u = (m % _utype(_storage(RT))) % _storage(RT)
        return reinterpret(RT, neg ? -u : u)
    elseif sizeof(T1) <= 16 && sizeof(T2) <= 16
        m = _widemul256(UInt128(_mag(x.unscaled)), UInt128(_mag(y.unscaled)))
        m > UInt256(_maxmag(RT)) && _throwop(:*, x, y)
        u = (m % _utype(_storage(RT))) % _storage(RT)
        return reinterpret(RT, neg ? -u : u)
    else
        hi, lo = _mul256full(_tomag256(x.unscaled), _tomag256(y.unscaled))
        (hi != zero(UInt256) || lo > UInt256(_maxmag(RT))) && _throwop(:*, x, y)
        u = (lo % _utype(_storage(RT))) % _storage(RT)
        return reinterpret(RT, neg ? -u : u)
    end
end

# division result type: worst-case integer digits of the true quotient
@generated function _divtype(::Type{Decimal{P1, S1, T1}},
                             ::Type{Decimal{P2, S2, T2}}) where {P1, S1, T1 <: StorageInt, P2, S2, T2 <: StorageInt}
    S = max(S1, S2)
    P = max(min(P1 - S1 + S2 + S, 76), S)
    return :(Decimal{$P, $S, $(_storagetype(P))})
end

"""
    divide(x, y, mode=RoundNearest)

Divide two decimals, rounding the true quotient at scale `max(scale(x),
scale(y))` with `mode`. `x / y` is `divide(x, y, RoundNearest)`.
"""
@inline function divide(x::Decimal{P1, S1, T1}, y::Decimal{P2, S2, T2},
                        mode::RoundingMode=RoundNearest) where {P1, S1, T1 <: StorageInt, P2, S2, T2 <: StorageInt}
    RT = _divtype(Decimal{P1, S1, T1}, Decimal{P2, S2, T2})
    iszero(y) && throw(DivideError())
    S = scale(RT)
    neg = _isneg(x) ⊻ _isneg(y)
    # quotient*10^S = u1*10^(S - S1 + S2) / u2
    n, ovf = _scaleup(_tomag256(x.unscaled), S - S1 + S2)
    ovf && _throwop(:/, x, y)
    q, _ = _divround(n, _tomag256(y.unscaled), neg, mode)
    q > UInt256(_maxmag(RT)) && _throwop(:/, x, y)
    u = (q % _utype(_storage(RT))) % _storage(RT)
    return reinterpret(RT, neg ? -u : u)
end

Base.:/(x::Decimal, y::Decimal) = divide(x, y, RoundNearest)

# scale-preserving multiply by a machine integer (multiplying by an integer
# should not widen the scale the way promotion-based multiply would)
const _MulInt = Union{Base.BitInteger, Int256, UInt256}

@generated function _mulinttype(::Type{Decimal{P, S, T}}, ::Type{I}) where {P, S, T <: StorageInt, I}
    P2 = min(P + _intdigits(I), 76)
    return :(Decimal{$P2, $S, $(_storagetype(P2))})
end

@inline function Base.:*(x::Decimal{P, S, T}, y::_MulInt) where {P, S, T <: StorageInt}
    RT = _mulinttype(Decimal{P, S, T}, typeof(y))
    neg = _isneg(x) ⊻ (y < zero(y))
    if sizeof(T) <= 8 && sizeof(y) <= 8
        m = widemul(_mag(x.unscaled) % UInt64, (_tomag256(y) % UInt64))
        m > UInt128(_maxmag(RT)) && _throwop(:*, x, y)
        u = (m % _utype(_storage(RT))) % _storage(RT)
        return reinterpret(RT, neg ? -u : u)
    end
    hi, lo = _mul256full(_tomag256(x.unscaled), _tomag256(y))
    (hi != zero(UInt256) || lo > UInt256(_maxmag(RT))) && _throwop(:*, x, y)
    u = (lo % _utype(_storage(RT))) % _storage(RT)
    return reinterpret(RT, neg ? -u : u)
end
Base.:*(y::_MulInt, x::Decimal) = x * y

function Base.:*(x::DecimalValue{T}, y::_MulInt) where {T <: StorageInt}
    hi, lo = _mul256full(_tomag256(x.unscaled), _tomag256(y))
    (hi != zero(UInt256) || lo > _tomag256(typemax(T))) && _throwvalop(:*)
    u = (lo % _utype(T)) % T
    return DecimalValue{T}((_isneg(x) ⊻ (y < zero(y))) ? -u : u, x.scale)
end
Base.:*(y::_MulInt, x::DecimalValue) = x * y

# ---- rounding to integer values within the type ----

function Base.round(x::Decimal{P, S, T}, mode::RoundingMode=RoundNearest;
                    digits::Integer=0) where {P, S, T <: StorageInt}
    digits >= S && return x
    k = S - Int(digits)
    neg = _isneg(x)
    q, _ = _scaledown(_mag(x), k, neg, mode)
    mag, ovf = _scaleup(q, k)
    (ovf || mag > _maxmag(Decimal{P, S, T})) && _throwop(:round, x, mode)
    u = (mag % _utype(T)) % T
    return reinterpret(Decimal{P, S, T}, neg ? -u : u)
end

Base.trunc(x::Decimal; digits::Integer=0) = round(x, RoundToZero; digits)
Base.floor(x::Decimal; digits::Integer=0) = round(x, RoundDown; digits)
Base.ceil(x::Decimal; digits::Integer=0) = round(x, RoundUp; digits)

# ---- sum: accumulate in (at least) the Int128 tier ----

_sumtype(::Type{Decimal{P, S, T}}) where {P, S, T <: Union{Int32, Int64}} =
    Decimal{38, S, Int128}
_sumtype(::Type{Decimal{P, S, T}}) where {P, S, T <: Union{Int128, Int256}} =
    Decimal{P, S, T}

@inline _sumwiden(x::Decimal) = convert(_sumtype(typeof(x)), x)

Base.add_sum(x::Decimal, y::Decimal) = _sumwiden(x) + _sumwiden(y)
Base.reduce_first(::typeof(Base.add_sum), x::Decimal) = _sumwiden(x)
Base.reduce_empty(::typeof(Base.add_sum), ::Type{D}) where {D <: Decimal} =
    zero(_sumtype(D))

# ---- DecimalValue arithmetic (runtime scales) ----

@noinline _throwvalop(op) =
    throw(OverflowError(string(op, " overflows the DecimalValue storage type")))

function _valaligned(x::DecimalValue{T}, y::DecimalValue{T}) where {T <: StorageInt}
    sx, sy = scale(x), scale(y)
    s = max(sx, sy)
    ux, uy = x.unscaled, y.unscaled
    if sx < s
        ux, ovf = _scaleup(ux, s - sx)
        ovf && _throwvalop(:align)
    elseif sy < s
        uy, ovf = _scaleup(uy, s - sy)
        ovf && _throwvalop(:align)
    end
    return ux, uy, s
end

for (op, kernel) in ((:+, :_add_ovf), (:-, :_sub_ovf))
    @eval begin
        function Base.$op(x::DecimalValue{T}, y::DecimalValue{T}) where {T <: StorageInt}
            ux, uy, s = _valaligned(x, y)
            u, ovf = $kernel(ux, uy)
            ovf && _throwvalop($(QuoteNode(op)))
            return DecimalValue{T}(u, s)
        end
        Base.$op(x::DecimalValue, y::DecimalValue) = $op(promote(x, y)...)
    end
end

function Base.:*(x::DecimalValue{T}, y::DecimalValue{T}) where {T <: StorageInt}
    s = scale(x) + scale(y)
    s <= 16383 || _throwvalop(:*)
    hi, lo = _mul256full(_tomag256(x.unscaled), _tomag256(y.unscaled))
    (hi != zero(UInt256) || lo > _tomag256(typemax(T))) && _throwvalop(:*)
    u = (lo % _utype(T)) % T
    return DecimalValue{T}((_isneg(x) ⊻ _isneg(y)) ? -u : u, s)
end
Base.:*(x::DecimalValue, y::DecimalValue) = *(promote(x, y)...)

function divide(x::DecimalValue{T}, y::DecimalValue{T},
                mode::RoundingMode=RoundNearest) where {T <: StorageInt}
    iszero(y) && throw(DivideError())
    s = max(scale(x), scale(y))
    neg = _isneg(x) ⊻ _isneg(y)
    n, ovf = _scaleup(_tomag256(x.unscaled), s - scale(x) + scale(y))
    ovf && _throwvalop(:/)
    q, _ = _divround(n, _tomag256(y.unscaled), neg, mode)
    q > _tomag256(typemax(T)) && _throwvalop(:/)
    u = (q % _utype(T)) % T
    return DecimalValue{T}(neg ? -u : u, s)
end
divide(x::DecimalValue, y::DecimalValue, mode::RoundingMode=RoundNearest) =
    divide(promote(x, y)..., mode)

Base.:/(x::DecimalValue, y::DecimalValue) = divide(x, y, RoundNearest)
