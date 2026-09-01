# Ecosystem-surface tests: big/rationalize/rand and the LinearAlgebra/Printf
# extensions (factorizations route to Float64 — silent scale-rounding inside
# generic lu! is never acceptable; matmul/dot/+ stay exact decimal).
using Decimals, BitIntegers
using Test, Random, LinearAlgebra, Printf

@testset "ecosystem surface" begin
    @test big(Decimal{18,2}("1.25")) == 5//4
    @test big(Decimal{18,2}("1.25")) isa Rational{BigInt}
    @test big(Decimal64{2}) === Rational{BigInt}
    @test big(DecimalValue{Int128}(1, 40)) == 1//big(10)^40
    @test rationalize(Decimal{18,2}("1.25")) === 5//4
    @test rationalize(Int32, Decimal{18,2}("0.50")) === Int32(1)//Int32(2)
    @test rationalize(Decimal{18,6}("0.333333"); tol=1e-3) == 1//3
    rng = Xoshiro(42)
    xs = rand(rng, Decimal{9,4,Int32}, 10_000)
    @test all(x -> zero(x) <= x < one(Decimal{9,4,Int32}), xs)
    @test length(unique(xs)) > 5000
    @test rand(rng, Decimal{18,0,Int64}) === zero(Decimal{18,0,Int64})
    io = IOBuffer()
    @printf(io, "%d|%07.3f", Decimal{18,2}("5.00"), Decimal{18,2}("1.25"))
    @test String(take!(io)) == "5|001.250"
    @test_throws InexactError @printf(IOBuffer(), "%d", Decimal{18,2}("1.25"))
    d(s) = Decimal{18,2}(s)
    A = [d("1.00") d("2.00"); d("3.00") d("4.00")]
    @test det(A) == -2.0
    @test det(A) isa Float64
    @test lu(A) isa LU{Float64}
    @test inv(A) ≈ [-2.0 1.0; 1.5 -0.5]
    @test eigvals(A) ≈ [-0.3722813232690143, 5.372281323269014]
    @test cholesky([d("4.0") d("2.0"); d("2.0") d("3.0")]) isa Cholesky{Float64}
    @test (A \ [d("1.00"), d("2.00")]) ≈ [0.0, 0.5]
    # exact operations stay decimal
    @test A * A isa Matrix{Decimal{36,4,Int128}}
    @test dot([d("1.0"), d("2.0")], [d("3.0"), d("4.0")]) isa Decimal{36,4,Int128}
    @test tr(A) === d("5.00")
    @test A + A isa Matrix{Decimal64{2}}
    # ranges still function
    @test length(d("0.10"):d("0.10"):d("1.00")) == 10
    @test collect(d("0.10"):d("0.10"):d("0.30")) ==
          [d("0.10"), d("0.20"), d("0.30")]
end

@testset "exact printf and JSON" begin
    io = IOBuffer()
    wide = Decimal{38,20,Int128}("12345678901234567.89012345678901234567")
    @printf(io, "%.20f", wide)
    @test String(take!(io)) == "12345678901234567.89012345678901234567"
    @printf(io, "%.2f", Decimal{18,2}("1.25"))
    @test String(take!(io)) == "1.25"
    @test Base.Checked.checked_add(Decimal{18,2}("1.25"), Decimal{18,2}("1.00")) ==
          Decimal{18,2}("2.25")
    @test_throws OverflowError Base.Checked.checked_add(typemax(Decimal64{2}),
                                                        eps(Decimal64{2}))
end

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
