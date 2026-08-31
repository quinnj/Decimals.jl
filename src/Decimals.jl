module Decimals

using BitIntegers: BitIntegers, Int256, UInt256

include("tables.jl")
include("limbs.jl")
include("magic.jl")
include("round.jl")
include("knuth.jl")

end # module
