using Test

@testset "Decimals" begin
    include("kernels.jl")
    include("types.jl")
    include("arithmetic.jl")
    include("format.jl")
    include("parsers.jl")
end
