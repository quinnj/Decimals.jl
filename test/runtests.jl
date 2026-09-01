using Test

@testset "Decimals" begin
    include("kernels.jl")
    include("types.jl")
    include("arithmetic.jl")
    include("format.jl")
    include("broadcast.jl")
    include("floatconv.jl")
    include("literals.jl")
    include("ecosystem.jl")
    include("parsers.jl")
    include("trim_compile_tests.jl")
end
