module Decimals

using BitIntegers: BitIntegers, Int256, UInt256

export Decimal, DecimalValue, Decimal32, Decimal64, Decimal128, Decimal256,
       rescale, divide, @dec_str

include("tables.jl")
include("limbs.jl")
include("magic.jl")
include("round.jl")
include("knuth.jl")
include("types.jl")
include("conversions.jl")
include("compare.jl")
include("sort.jl")
include("arithmetic.jl")
include("broadcast.jl")
include("format.jl")
include("show.jl")
include("literals.jl")
include("random.jl")

@static if VERSION >= v"1.11"
    eval(Expr(:public, :normalize, :unscaled, :scale, :AbstractDecimal,
              :writedecimal!, :decimallength))
end

end # module
