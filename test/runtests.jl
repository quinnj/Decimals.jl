using Test

# Allocation-free gates hold on Julia 1.12+. Older compilers leave small
# boxes around wide-integer temporaries, so the gates are skipped there while
# every value assertion still runs.
const ALLOC_GATES = VERSION >= v"1.12"
macro test_allocfree(ex)
    return esc(:(ALLOC_GATES && @test @allocated($ex) == 0))
end

@testset "Decimals" begin
    include("kernels.jl")
    include("types.jl")
    include("arithmetic.jl")
    include("format.jl")
    include("broadcast.jl")
    include("floatconv.jl")
    include("literals.jl")
    include("ecosystem.jl")
    include("fastpaths.jl")
    if Base.find_package("JSON") !== nothing
        include("json.jl")
    else
        println("[suite] JSON not in test env (needs JSON with Parsers 3 compat); skipping json.jl")
    end
    include("parsers.jl")
    include("trim_compile_tests.jl")
end
