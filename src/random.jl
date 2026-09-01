# Uniform random decimals in [0, 1) at the type's scale — the natural analogue
# of rand(Float64). A scale-0 type has only one value in [0, 1).
import Random

function Random.rand(rng::Random.AbstractRNG,
                     ::Random.SamplerType{Decimal{P, S, T}}) where {P, S, T <: StorageInt}
    S == 0 && return zero(Decimal{P, S, T})
    hi = (_upow10(_utype(T), S) - one(_utype(T))) % T
    return reinterpret(Decimal{P, S, T}, rand(rng, zero(T):hi))
end
