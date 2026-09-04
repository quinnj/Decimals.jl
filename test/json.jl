# JSON 1.x integration tests. CI runs these in test/json, independently of
# the Parsers 3 suite, because JSON 1.x currently requires Parsers 1-2.
import JSON

@testset "JSON exact numbers" begin
    wide = Decimal{38,20,Int128}("12345678901234567.89012345678901234567")
    @test JSON.json(Dict("v" => wide)) ==
          "{\"v\":12345678901234567.89012345678901234567}"
    @test JSON.json([Decimal{18,2}("1.25"), DecimalValue{Int64}(5, 3)]) ==
          "[1.25,0.005]"
    # round-trips through JSON.parse as a number
    @test JSON.parse(JSON.json(Dict("v" => Decimal{18,2}("1.25"))))["v"] == 1.25
end
