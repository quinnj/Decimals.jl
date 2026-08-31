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

# narrow-tier product: the exact result always fits the promoted type
# (P1 + P2 <= 36 digits in Int128), so no checks at all — pure widening SIMD
function _bcmul(a::Vector{Decimal{P1, S1, T1}},
                b::Vector{Decimal{P2, S2, T2}}) where {P1, S1, T1 <: Union{Int32, Int64},
                                                       P2, S2, T2 <: Union{Int32, Int64}}
    RT = _multype(Decimal{P1, S1, T1}, Decimal{P2, S2, T2})
    T = _storage(RT)
    n = length(a)
    dest = Vector{RT}(undef, n)
    @inbounds @simd for i in 1:n
        dest[i] = reinterpret(RT, widemul(a[i].unscaled, b[i].unscaled) % T)
    end
    return dest
end

function Base.copy(bc::Broadcasted{DefaultArrayStyle{1}, <:Any, typeof(*),
                   Tuple{Vector{Decimal{P1, S1, T1}}, Vector{Decimal{P2, S2, T2}}}}) where {P1, S1, T1 <: Union{Int32, Int64},
                                                                                            P2, S2, T2 <: Union{Int32, Int64}}
    a, b = bc.args
    length(a) == length(b) ||
        return invoke(Base.copy, Tuple{Broadcasted}, bc)
    return _bcmul(a, b)
end
