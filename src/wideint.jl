# The 256-bit storage integers: two primitive types over LLVM's native i256
# arithmetic, covering what the decimal kernels need (arithmetic, bit ops,
# shifts, comparisons, conversions to and from the machine integers, BigInt and
# floats). Division is absent: i256 division is not available across all
# supported Julia versions, so `div`/`rem` build on the kernels in knuth.jl.

using Base: add_int, sub_int, mul_int, neg_int, and_int, or_int, xor_int, not_int,
            shl_int, lshr_int, ashr_int, slt_int, ult_int, sle_int, ule_int,
            ctlz_int, cttz_int, ctpop_int, flipsign_int, checked_sadd_int,
            checked_ssub_int, checked_uadd_int, checked_usub_int
using Core: bitcast, sext_int, zext_int, trunc_int, checked_trunc_sint

primitive type Int256 <: Signed 256 end
primitive type UInt256 <: Unsigned 256 end

const _Wide = Union{Int256, UInt256}
const _MachineInt = Base.BitInteger  # Int8..Int128, UInt8..UInt128

Base.Signed(x::UInt256) = Int256(x)
Base.Unsigned(x::Int256) = UInt256(x)
Base.uinttype(::Type{Int256}) = UInt256
Base.uinttype(::Type{UInt256}) = UInt256
Base.signed(::Type{UInt256}) = Int256
Base.signed(::Type{Int256}) = Int256
Base.unsigned(::Type{Int256}) = UInt256
Base.unsigned(::Type{UInt256}) = UInt256
Base.signed(x::_Wide) = bitcast(Int256, x)
Base.unsigned(x::_Wide) = bitcast(UInt256, x)
Base.widen(::Type{<:_Wide}) = BigInt

Base.typemin(::Type{UInt256}) = zext_int(UInt256, false)
Base.typemax(::Type{UInt256}) = not_int(typemin(UInt256))
Base.typemin(::Type{Int256}) = bitcast(Int256, shl_int(zext_int(UInt256, true), 255 % UInt))
Base.typemax(::Type{Int256}) = bitcast(Int256, lshr_int(typemax(UInt256), 1 % UInt))

# ---- conversions with the machine integers and Bool ----

@inline function (::Type{UInt256})(x::_MachineInt)
    x isa Signed && x < zero(x) && throw(InexactError(:UInt256, UInt256, x))
    return x isa Signed ? bitcast(UInt256, sext_int(Int256, x)) : zext_int(UInt256, x)
end
@inline (::Type{Int256})(x::_MachineInt) = x isa Signed ? sext_int(Int256, x) : bitcast(Int256, zext_int(UInt256, x))
@inline (::Type{T})(x::Bool) where {T <: _Wide} = x ? one(T) : zero(T)
@inline (::Type{UInt256})(x::UInt256) = x
@inline (::Type{Int256})(x::Int256) = x
@inline function (::Type{UInt256})(x::Int256)
    x < zero(Int256) && throw(InexactError(:UInt256, UInt256, x))
    return bitcast(UInt256, x)
end
@inline function (::Type{Int256})(x::UInt256)
    x > bitcast(UInt256, typemax(Int256)) && throw(InexactError(:Int256, Int256, x))
    return bitcast(Int256, x)
end

for T in Base.BitInteger_types
    @eval begin
        @inline function (::Type{$T})(x::Int256)
            $(T <: Signed) && return checked_trunc_sint($T, x)
            (x < zero(Int256) || x > bitcast(Int256, zext_int(UInt256, typemax($T)))) &&
                throw(InexactError($(QuoteNode(Symbol(T))), $T, x))
            return trunc_int($T, x)
        end
        @inline function (::Type{$T})(x::UInt256)
            x > zext_int(UInt256, typemax($T)) && throw(InexactError($(QuoteNode(Symbol(T))), $T, x))
            return trunc_int($T, x) % $T
        end
        @inline Base.rem(x::_Wide, ::Type{$T}) = trunc_int($T, x)
        @inline Base.rem(x::$T, ::Type{UInt256}) = $(T <: Signed) ? bitcast(UInt256, sext_int(Int256, x)) : zext_int(UInt256, x)
        @inline Base.rem(x::$T, ::Type{Int256}) = $(T <: Signed) ? sext_int(Int256, x) : bitcast(Int256, zext_int(UInt256, x))
    end
end
@inline Base.rem(x::_Wide, ::Type{UInt256}) = bitcast(UInt256, x)
@inline Base.rem(x::_Wide, ::Type{Int256}) = bitcast(Int256, x)
@inline Base.rem(x::Bool, ::Type{T}) where {T <: _Wide} = T(x)
@inline Base.rem(x::T, ::Type{T}) where {T <: _Wide} = x

Base.promote_rule(::Type{T}, ::Type{<:_MachineInt}) where {T <: _Wide} = T
Base.promote_rule(::Type{UInt256}, ::Type{Int256}) = UInt256
Base.promote_rule(::Type{Float64}, ::Type{<:_Wide}) = Float64
Base.promote_rule(::Type{Float32}, ::Type{<:_Wide}) = Float32
Base.promote_rule(::Type{Float16}, ::Type{<:_Wide}) = Float16
Base.promote_rule(::Type{BigInt}, ::Type{<:_Wide}) = BigInt
Base.promote_rule(::Type{BigFloat}, ::Type{<:_Wide}) = BigFloat

# ---- comparisons ----
Base.:(<)(x::UInt256, y::UInt256) = ult_int(x, y)
Base.:(<)(x::Int256, y::Int256) = slt_int(x, y)
Base.:(<=)(x::UInt256, y::UInt256) = ule_int(x, y)
Base.:(<=)(x::Int256, y::Int256) = sle_int(x, y)

# ---- bit operations and shifts ----
Base.:(~)(x::T) where {T <: _Wide} = not_int(x)
Base.:(&)(x::T, y::T) where {T <: _Wide} = and_int(x, y)
Base.:(|)(x::T, y::T) where {T <: _Wide} = or_int(x, y)
Base.xor(x::T, y::T) where {T <: _Wide} = xor_int(x, y)

# LLVM's variable-count shift on i256 expands poorly; split the count into a
# whole number of 64-bit steps (each a constant shift) plus a 0..63 remainder
@inline function _wideshift(f::F, x::T, y::UInt) where {F, T <: _Wide}
    hi = y >> 6
    lo = y & 0x3f
    hi == 0 && return f(x, lo)
    hi == 1 && return f(f(x, 64 % UInt), lo)
    hi == 2 && return f(f(x, 128 % UInt), lo)
    hi == 3 && return f(f(x, 192 % UInt), lo)
    return (f === ashr_int && x < zero(T)) ? -one(T) : zero(T)
end
Base.:(>>)(x::Int256, y::UInt) = _wideshift(ashr_int, x, y)
Base.:(>>)(x::UInt256, y::UInt) = _wideshift(lshr_int, x, y)
Base.:(>>>)(x::_Wide, y::UInt) = _wideshift(lshr_int, x, y)
Base.:(<<)(x::_Wide, y::UInt) = _wideshift(shl_int, x, y)
@inline Base.:(>>)(x::_Wide, y::Int) = 0 <= y ? x >> (y % UInt) : x << ((-y) % UInt)
@inline Base.:(<<)(x::_Wide, y::Int) = 0 <= y ? x << (y % UInt) : x >> ((-y) % UInt)
@inline Base.:(>>>)(x::_Wide, y::Int) = 0 <= y ? x >>> (y % UInt) : x << ((-y) % UInt)
# machine integers shifted by a wide count: narrow the count to Int first
Base.:(<<)(x::_MachineInt, y::_Wide) = x << Int(y)
Base.:(>>)(x::_MachineInt, y::_Wide) = x >> Int(y)
Base.:(>>>)(x::_MachineInt, y::_Wide) = x >>> Int(y)

Base.count_ones(x::_Wide) = Int(ctpop_int(x))
Base.leading_zeros(x::_Wide) = Int(ctlz_int(x))
Base.trailing_zeros(x::_Wide) = Int(cttz_int(x))
Base.top_set_bit(x::_Wide) = 256 - leading_zeros(x)
Base.isodd(x::_Wide) = isodd(x % Int)
Base.iseven(x::_Wide) = iseven(x % Int)
Base.flipsign(x::Int256, y::Int256) = flipsign_int(x, y)
Base.flipsign(x::Int256, y::Signed) = flipsign_int(x, Int256(y))

# ---- arithmetic (division lives in knuth.jl) ----
Base.:(-)(x::_Wide) = neg_int(x)
Base.:(-)(x::T, y::T) where {T <: _Wide} = sub_int(x, y)
Base.:(+)(x::T, y::T) where {T <: _Wide} = add_int(x, y)
Base.:(*)(x::T, y::T) where {T <: _Wide} = mul_int(x, y)
Base.add_with_overflow(x::Int256, y::Int256) = checked_sadd_int(x, y)
Base.sub_with_overflow(x::Int256, y::Int256) = checked_ssub_int(x, y)
Base.add_with_overflow(x::UInt256, y::UInt256) = checked_uadd_int(x, y)
Base.sub_with_overflow(x::UInt256, y::UInt256) = checked_usub_int(x, y)
# Base's gcd and Rational construction call into the checked family
Base.Checked.checked_abs(x::UInt256) = x
function Base.Checked.checked_abs(x::Int256)
    x == typemin(Int256) && throw(OverflowError("checked arithmetic: cannot compute |x| for x = typemin(Int256)"))
    return abs(x)
end
# the i256 checked-multiply intrinsics are only reliable from Julia 1.11;
# earlier versions go through BigInt
function Base.mul_with_overflow(x::T, y::T) where {T <: _Wide}
    @static if VERSION >= v"1.11"
        return T <: Signed ? Base.checked_smul_int(x, y) : Base.checked_umul_int(x, y)
    else
        r = BigInt(x) * BigInt(y)
        t = r % T
        return (t, BigInt(t) != r)
    end
end
# two's-complement truncation: GMP's & on a negative BigInt yields the low bits
Base.rem(x::BigInt, ::Type{T}) where {T <: _Wide} = UInt256(x & BigInt(typemax(UInt256))) % T

# ---- BigInt and floats (cold paths) ----
function Base.BigInt(x::UInt256)
    r = big(0)
    for i in 3:-1:0
        r = (r << 64) | big((x >> (64 * i)) % UInt64)
    end
    return r
end
Base.BigInt(x::Int256) = (m = BigInt(unsigned(x < zero(x) ? -x : x)); x < zero(x) ? -m : m)
function (::Type{UInt256})(x::BigInt)
    (x < 0 || x > BigInt(typemax(UInt256))) && throw(InexactError(:UInt256, UInt256, x))
    r = zero(UInt256)
    s = 0
    while x > 0
        r |= UInt256(UInt64(x & 0xffffffffffffffff)) << s
        x >>= 64
        s += 64
    end
    return r
end
function (::Type{Int256})(x::BigInt)
    (x < BigInt(typemin(Int256)) || x > BigInt(typemax(Int256))) && throw(InexactError(:Int256, Int256, x))
    return x < 0 ? -bitcast(Int256, UInt256(-x)) : bitcast(Int256, UInt256(x))
end
Base.AbstractFloat(x::_Wide) = Float64(x)
for F in (Float64, Float32, Float16)
    @eval (::Type{$F})(x::_Wide) = $F(BigInt(x))
end
(::Type{T})(x::AbstractFloat) where {T <: _Wide} = T(BigInt(x))
Base.BigFloat(x::_Wide) = BigFloat(BigInt(x))

# ---- IO: raw little-endian bytes, as for the machine integers ----
Base.write(io::IO, x::_Wide) = write(io, Ref(x))
Base.read(io::IO, ::Type{T}) where {T <: _Wide} = read!(io, Ref{T}(zero(T)))[]
Base.bswap(x::_Wide) = Base.bswap_int(x)

# ---- random ----
Random.rand(rng::Random.AbstractRNG, ::Random.SamplerType{UInt256}) =
    (UInt256(rand(rng, UInt128)) << 128) | UInt256(rand(rng, UInt128))
Random.rand(rng::Random.AbstractRNG, ::Random.SamplerType{Int256}) =
    bitcast(Int256, rand(rng, UInt256))

# uniform draw from a unit range by masked rejection on the span
struct _WideRangeSampler{T} <: Random.Sampler{T}
    a::T
    m::UInt256      # span (last - first) as unsigned
    mask::UInt256
end
function Random.Sampler(::Type{<:Random.AbstractRNG}, r::AbstractUnitRange{T},
                        ::Random.Repetition) where {T <: _Wide}
    isempty(r) && throw(ArgumentError("range must be non-empty"))
    m = (last(r) - first(r)) % UInt256
    bw = 256 - leading_zeros(m)
    mask = bw == 0 ? zero(UInt256) : (typemax(UInt256) >> (256 - bw))
    return _WideRangeSampler{T}(first(r), m, mask)
end
function Random.rand(rng::Random.AbstractRNG, sp::_WideRangeSampler{T}) where {T}
    while true
        u = rand(rng, UInt256) & sp.mask
        u <= sp.m && return sp.a + (u % T)
    end
end
