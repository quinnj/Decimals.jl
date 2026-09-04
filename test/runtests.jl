using Test
using Parsers  # Base.parse/tryparse on decimal types come from the Parsers extension

# Allocation-free gates hold on Julia 1.12+. Older compilers leave small
# boxes around wide-integer temporaries, so the gates are skipped there while
# every value assertion still runs.
const ALLOC_GATES = VERSION >= v"1.12"
macro test_allocfree(ex)
    return esc(:(ALLOC_GATES && @test @allocated($ex) == 0))
end

@testset "Decimals" begin
    include("wideint.jl")
    include("kernels.jl")
    include("types.jl")
    include("arithmetic.jl")
    include("format.jl")
    include("broadcast.jl")
    include("floatconv.jl")
    include("literals.jl")
    include("ecosystem.jl")
    include("printf.jl")
    include("release.jl")
    include("fastpaths.jl")
    # JSON 1 + Parsers 2 has its own CI environment in test/json.
    include("parsers.jl")
    include("trim_compile_tests.jl")
end
