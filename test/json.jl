# JSON 1.x integration tests. JSON 1.x currently pins Parsers 1-2 while this
# suite needs Parsers 3 (parsers ext + trim workload), so the two cannot share
# the test environment until JSON gains Parsers 3 compat; runtests includes
# this file only when JSON is resolvable. The hook itself is one line and is
# also covered by a standalone-env check (see docs/ecosystem-compat.md).
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
