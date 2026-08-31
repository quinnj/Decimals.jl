using Test

@testset "Decimals" begin
    include("kernels.jl")
    include("types.jl")
    include("arithmetic.jl")
end
