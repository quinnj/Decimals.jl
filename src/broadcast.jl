# Columnar broadcast kernels. Elementwise `a .+ b`, `a .- b` and `a .* b` over
# same-shaped Vectors get block-checked vectorizable loops: each lane computes
# unchecked and ORs into one overflow flag, which is thrown once at the end, so
# there are no per-element branches and the exception is the one the scalar path
# raises. Everything else (mixed lengths, views, fused expressions, wider
# products) falls back to the generic scalar machinery.

using Base.Broadcast: Broadcasted, DefaultArrayStyle

@noinline _throwbcoverflow(op) =
    throw(OverflowError(string("broadcast ", op, " overflows the result type")))

function _bcaddsub(a::Vector{Decimal{P, S, T}}, b::Vector{Decimal{P, S, T}},
                   ::Val{sub}) where {P, S, T <: StorageInt, sub}
    n = length(a)
    dest = Vector{Decimal{P, S, T}}(undef, n)
    mm = _maxmag(Decimal{P, S, T}) % T
    bad = false
    if _wrapfree(Decimal{P, S, T})
        # wrap-free tier: one unsigned range test per lane
        @inbounds @simd for i in 1:n
            r = sub ? a[i].unscaled - b[i].unscaled : a[i].unscaled + b[i].unscaled
            bad |= _outofrange(r, Decimal{P, S, T})
            dest[i] = reinterpret(Decimal{P, S, T}, r)
        end
    else
        @inbounds @simd for i in 1:n
            x = a[i].unscaled
            y = b[i].unscaled
            r = sub ? x - y : x + y
            ovf = sub ? ((x ⊻ y) & (x ⊻ r)) < zero(T) : ((x ⊻ r) & (y ⊻ r)) < zero(T)
            bad |= ovf | (r > mm) | (r < -mm)
            dest[i] = reinterpret(Decimal{P, S, T}, r)
        end
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

# Elementwise product: the exact result always fits the result type, since
# P1 + P2 <= 76 digits and Int256 holds that for every storage pairing up to
# Int128 x Int128. So the loop needs no checks: a widening SIMD multiply for the
# narrow tiers, a sign-magnitude 256-bit multiply for the Int128 tier.
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

# Float64 conversion over a column: an |unscaled| <= 2^53 converts exactly and
# the division by 10^S (S <= 22, also exact) is correctly rounded, so the loop is
# a convert-and-divide that vectorizes. Any wider elements are recomputed
# afterwards through the exact scalar path.
const _F64EXACT = 9007199254740992  # 2^53
function _tofloat64vec(v::AbstractVector{Decimal{P, S, T}}) where {P, S, T <: Union{Int32, Int64}}
    n = length(v)
    dest = Vector{Float64}(undef, n)
    p = @inbounds _FPOW10[S + 1]
    bad = false
    @inbounds @simd for i in eachindex(v)
        u = v[i].unscaled
        bad |= (u > _F64EXACT) | (u < -_F64EXACT)
        dest[i] = Float64(u) / p
    end
    if bad
        @inbounds for i in eachindex(v)
            u = v[i].unscaled
            (u > _F64EXACT || u < -_F64EXACT) && (dest[i] = _tofloat(Float64, u, S))
        end
    end
    return dest
end

for f in (:(Type{Float64}), :(typeof(float)))
    @eval function Base.copy(bc::Broadcasted{DefaultArrayStyle{1}, <:Any, $f,
                             Tuple{Vector{Decimal{P, S, T}}}}) where {P, S, T <: Union{Int32, Int64}}
        S <= 22 || return invoke(Base.copy, Tuple{Broadcasted}, bc)
        return _tofloat64vec(bc.args[1])
    end
end
function Base.map(::Type{Float64}, v::Vector{Decimal{P, S, T}}) where {P, S, T <: Union{Int32, Int64}}
    S <= 22 || return invoke(Base.map, Tuple{Any, AbstractArray}, Float64, v)
    return _tofloat64vec(v)
end
