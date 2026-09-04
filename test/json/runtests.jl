using Test, Decimals, Parsers
using Decimals: DecimalValue, Decimal64

include("../json.jl")

@testset "Parsers 2 coexistence" begin
    @test pkgversion(Parsers) < v"3"
    @test Base.get_extension(Decimals, :DecimalsJSONExt) !== nothing
    @test Base.get_extension(Decimals, :DecimalsParsersExt) !== nothing
    @test Decimal64{2}("1.235") == Decimal64{2}("1.24")
    @test dec"1.25" == 5//4
    @test_throws MethodError parse(Decimal64{2}, "1.25")
end
