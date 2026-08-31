using Test

@testset "Decimals" begin
    include("kernels.jl")
    include("types.jl")
    include("arithmetic.jl")
    include("format.jl")
    include("broadcast.jl")
    include("floatconv.jl")
    include("parsers.jl")
end
