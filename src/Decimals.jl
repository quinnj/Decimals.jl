module Decimals

using BitIntegers: BitIntegers, Int256, UInt256

export Decimal, DecimalValue, Decimal32, Decimal64, Decimal128, Decimal256,
       rescale

include("tables.jl")
include("limbs.jl")
include("magic.jl")
include("round.jl")
include("knuth.jl")
include("types.jl")
include("conversions.jl")
include("compare.jl")
include("show.jl")

@static if VERSION >= v"1.11"
    eval(Expr(:public, :unscaled, :scale, :AbstractDecimal))
end

end # module
