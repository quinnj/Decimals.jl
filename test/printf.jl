using Test, Decimals, Printf

@testset "decimal Printf rounding" begin
    D = Decimals.Decimal64{3}
    @test @sprintf("%.2f", D("2.675")) == "2.68"
    @test @sprintf("%.1f", D("0.35")) == "0.4"
    @test @sprintf("%.1f", D("1.15")) == "1.2"
    @test @sprintf("%.2f", D("-2.675")) == "-2.68"
    @test @sprintf("%+08.2f", D("2.675")) == "+0002.68"
    @test @sprintf("%-8.2f", D("2.675")) == "2.68    "
    @test @sprintf("%.2e", D("2.675")) == "2.68e+00"
    @test @sprintf("%.3g", D("2.675")) == "2.68"
    @test @sprintf("%.2E", D("2.675")) == "2.68E+00"
    @test @sprintf("%#.3G", D("2.675")) == "2.68"
    @test @sprintf("%.2f", D("-0.001")) == "-0.00"
    @test @sprintf("%.3g", D("999.5")) == "1e+03"
    @test @sprintf("%.2f", Decimals.Decimal{3,3}("0.995")) == "1.00"
    @test @sprintf("%.400f", D("0.1")) == "0.1" * "0"^399
    @test @sprintf("%.3e", Decimals.DecimalValue(12345, 1000)) == "1.234e-996"
    # Exhaust every tie at one fractional place, with both signs and parities.
    for n in -995:10:995
        x = Decimals.DecimalValue(n, 3)
        q = round(BigInt, n//10, RoundNearest)
        expected = (n < 0 ? "-" : "") * string(abs(q) ÷ 100) * "." * lpad(string(abs(q) % 100), 2, '0')
        @test @sprintf("%.2f", x) == expected
    end
end
