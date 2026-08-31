# Columnar broadcast kernels. Elementwise `a .+ b`, `a .- b`, `a .* b` over
# same-shaped Vectors get block-checked vectorizable loops: compute unchecked
# per lane, OR an overflow flag across the array, throw once at the end (the
# CedarDB pattern — same user-visible exception as the scalar path, no
# per-element branches). Anything else (mixed lengths, views, fused
# expressions, wider products) falls back to the generic scalar machinery,
# which is correct just not SIMD.

using Base.Broadcast: Broadcasted, DefaultArrayStyle

@noinline _throwbcoverflow(op) =
    throw(OverflowError(string("broadcast ", op, " overflows the result type")))

function _bcaddsub(a::Vector{Decimal{P, S, T}}, b::Vector{Decimal{P, S, T}},
                   ::Val{sub}) where {P, S, T <: StorageInt, sub}
    n = length(a)
    dest = Vector{Decimal{P, S, T}}(undef, n)
    mm = _maxmag(Decimal{P, S, T}) % T
    bad = false
    @inbounds @simd for i in 1:n
        x = a[i].unscaled
        y = b[i].unscaled
        r = sub ? x - y : x + y
        ovf = sub ? ((x ⊻ y) & (x ⊻ r)) < zero(T) : ((x ⊻ r) & (y ⊻ r)) < zero(T)
        bad |= ovf | (r > mm) | (r < -mm)
        dest[i] = reinterpret(Decimal{P, S, T}, r)
    end
    bad && _throwbcoverflow(sub ? :- : :+)
    return dest
end

for (op, subval) in ((:+, false), (:-, true))
    @eval function Base.copy(bc::Broadcasted{DefaultArrayStyle{1}, <:Any, typeof($op),
                             Tuple{Vector{Decimal{P, S, T}}, Vector{Decimal{P, S, T}}}}) where {P, S, T <: StorageInt}
        a, b = bc.args
        length(a) == length(b) ||
            return invoke(Base.copy, Tuple{Broadcasted}, bc)
        return _bcaddsub(a, b, Val($subval))
    end
end

# elementwise product: the exact result always fits the promoted type
# (P1 + P2 <= 76 digits, which every storage pairing up to Int128 x Int128
# holds in Int256), so no checks at all — widening SIMD for narrow tiers, a
# sign-magnitude 256-bit widening loop for the Int128 tier
function _bcmul(a::Vector{Decimal{P1, S1, T1}},
                b::Vector{Decimal{P2, S2, T2}}) where {P1, S1, T1 <: Union{Int32, Int64, Int128},
                                                       P2, S2, T2 <: Union{Int32, Int64, Int128}}
    RT = _multype(Decimal{P1, S1, T1}, Decimal{P2, S2, T2})
    T = _storage(RT)
    n = length(a)
    dest = Vector{RT}(undef, n)
    if sizeof(T1) <= 8 && sizeof(T2) <= 8
        @inbounds @simd for i in 1:n
            dest[i] = reinterpret(RT, widemul(a[i].unscaled, b[i].unscaled) % T)
        end
    else
        @inbounds for i in 1:n
            x = a[i].unscaled
            y = b[i].unscaled
            m = _widemul256(UInt128(_mag(x)), UInt128(_mag(y)))
            u = (m % _utype(T)) % T
            dest[i] = reinterpret(RT, ((x < zero(x)) ⊻ (y < zero(y))) ? -u : u)
        end
    end
    return dest
end

function Base.copy(bc::Broadcasted{DefaultArrayStyle{1}, <:Any, typeof(*),
                   Tuple{Vector{Decimal{P1, S1, T1}}, Vector{Decimal{P2, S2, T2}}}}) where {P1, S1, T1 <: Union{Int32, Int64, Int128},
                                                                                            P2, S2, T2 <: Union{Int32, Int64, Int128}}
    a, b = bc.args
    length(a) == length(b) ||
        return invoke(Base.copy, Tuple{Broadcasted}, bc)
    return _bcmul(a, b)
end

# mixed-scale, same-storage add/sub: align by a compile-time constant power
# of ten with a vectorizable bound mask, then the checked-add pattern
function _bcaddsubmix(a::Vector{Decimal{P1, S1, T}}, b::Vector{Decimal{P2, S2, T}},
                      ::Val{sub}) where {P1, S1, P2, S2, T <: StorageInt, sub}
    RT = promote_type(Decimal{P1, S1, T}, Decimal{P2, S2, T})
    TR = _storage(RT)
    S = scale(RT)
    da = S - S1
    db = S - S2
    pa = _upow10(_utype(TR), da) % TR
    pb = _upow10(_utype(TR), db) % TR
    la = da == 0 ? typemax(TR) : typemax(TR) ÷ pa
    lb = db == 0 ? typemax(TR) : typemax(TR) ÷ pb
    mm = _maxmag(RT) % TR
    n = length(a)
    dest = Vector{RT}(undef, n)
    bad = false
    @inbounds @simd for i in 1:n
        xa = TR(a[i].unscaled)
        xb = TR(b[i].unscaled)
        bad |= (xa > la) | (xa < -la) | (xb > lb) | (xb < -lb)
        x = xa * pa
        y = xb * pb
        r = sub ? x - y : x + y
        ovf = sub ? ((x ⊻ y) & (x ⊻ r)) < zero(TR) : ((x ⊻ r) & (y ⊻ r)) < zero(TR)
        bad |= ovf | (r > mm) | (r < -mm)
        dest[i] = reinterpret(RT, r)
    end
    bad && _throwbcoverflow(sub ? :- : :+)
    return dest
end

for (op, subval) in ((:+, false), (:-, true))
    @eval function Base.copy(bc::Broadcasted{DefaultArrayStyle{1}, <:Any, typeof($op),
                             Tuple{Vector{Decimal{P1, S1, T}}, Vector{Decimal{P2, S2, T}}}}) where {P1, S1, P2, S2, T <: StorageInt}
        a, b = bc.args
        length(a) == length(b) ||
            return invoke(Base.copy, Tuple{Broadcasted}, bc)
        return _bcaddsubmix(a, b, Val($subval))
    end
end
