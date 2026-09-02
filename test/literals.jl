# Literal macro, normalize, and scientific-notation display.
using Decimals
using Decimals: Decimals as D, unscaled, scale
using BitIntegers
using Test, Random

@testset "dec_str literal" begin
    @test dec"1.25" === reinterpret(Decimal{3,2,Int32}, Int32(125))
    @test dec"-0.05" === reinterpret(Decimal{2,2,Int32}, Int32(-5))
    @test dec"1_000_000.25" === reinterpret(Decimal{9,2,Int32}, Int32(100000025))
    @test dec"1e3" === reinterpret(Decimal{4,0,Int32}, Int32(1000))
    @test dec"1.5e-3" === reinterpret(Decimal{4,4,Int32}, Int32(15))
    @test dec"0.00" === reinterpret(Decimal{2,2,Int32}, Int32(0))
    @test dec"+12345678901234567890" === reinterpret(Decimal{20,0,Int128}, Int128(12345678901234567890))
    wide = dec"12345678901234567890123456789012345678901234567890123456789012345678901234567"
    @test wide isa DecimalValue{Int256}
    @test scale(wide) == 0
    @test dec"1.20" + dec"0.05" == 1.25
    @test dec"2" * Decimal{18,2}("2.50") == 5
    for bad in ("1_.5", "_1", "1_", "1._5", "abc", "1e_5", "1.2.3", "")
        @test_throws ArgumentError D._decliteral(bad)
    end
    # exact-or-error: no silent rounding of over-long literals
    @test_throws ArgumentError D._decliteral("1." * "1"^100)
    @test_throws ArgumentError D._decliteral("1e100")
end

@testset "normalize" begin
    rng = Xoshiro(10001)
    @test Decimals.normalize(dec"1.2000") === DecimalValue{Int32}(12, 1)
    @test Decimals.normalize(Decimal{18,4}("5.0000")) === DecimalValue{Int64}(5, 0)
    @test Decimals.normalize(DecimalValue{Int64}(12000, 0)) === DecimalValue{Int64}(12000, 0)
    @test Decimals.normalize(DecimalValue{Int128}(Int128(123) * Int128(10)^30, 33)) ===
          DecimalValue{Int128}(123, 3)
    @test Decimals.normalize(zero(DecimalValue{Int64})) === DecimalValue{Int64}(0, 0)
    @test Decimals.normalize(DecimalValue{Int64}(-100, 4)) === DecimalValue{Int64}(-1, 2)
    for _ in 1:20000
        u = rand(rng, -10^12:10^12)
        s = rand(rng, 0:20)
        v = DecimalValue{Int64}(u, s)
        n = Decimals.normalize(v)
        @test n == v
        @test scale(n) == 0 || !iszero(rem(unscaled(n), 10)) || iszero(unscaled(n))
    end
    for _ in 1:5000
        u = Int256(rand(rng, big(-10)^40:big(10)^40))
        s = rand(rng, 0:70)
        v = DecimalValue{Int256}(u, s)
        n = Decimals.normalize(v)
        @test n == v
        @test scale(n) == 0 || !iszero(rem(D._tobigsigned(unscaled(n)), 10)) ||
              iszero(unscaled(n))
    end
end

@testset "scientific display" begin
    @test repr("text/plain", DecimalValue{Int64}(5, 1000)) == "5E-1000"
    @test repr("text/plain", DecimalValue{Int64}(123456, 990)) == "1.23456E-985"
    @test repr("text/plain", DecimalValue{Int64}(-5, 100)) == "-5E-100"
    @test repr("text/plain", Decimal{18,2}("1234.56")) == "1234.56"
    # string/print stay positional (the wire contract)
    @test string(DecimalValue{Int64}(5, 100)) == "0." * "0"^99 * "5"
end

@testset "deep-scale division (512-bit dividend)" begin
    rng = Xoshiro(10002)
    a = Decimal{76,40,Int256}("100000000000000000000.0000000000000000000000000000000000000001")
    @test a / a == 1
    b = Decimal{76,60,Int256}("0." * "0"^40 * "1" * "0"^18 * "5")
    @test b / b == 1
    nover = 0
    for _ in 1:5000
        s1 = rand(rng, 30:76)
        s2 = rand(rng, 30:76)
        u1 = Int256(rand(rng, big(1):big(10)^60))
        u2 = Int256(rand(rng, big(1):big(10)^60))
        xv = DecimalValue{Int256}(u1, s1)
        yv = DecimalValue{Int256}(u2, s2)
        s = max(s1, s2)
        nb = D._tobigsigned(u1) * big(10)^(s - s1 + s2)
        db = D._tobigsigned(u2)
        qq, rr = divrem(nb, db)
        comp = db - rr
        want = qq + ((rr > comp || (rr == comp && isodd(qq))) ? 1 : 0)
        if want > D._tobig(D._mag(typemax(Int256)))
            @test_throws OverflowError divide(xv, yv)
            nover += 1
        else
            @test D._tobigsigned(unscaled(divide(xv, yv))) == want
        end
    end
    @test nover > 0  # the sweep must exercise both outcomes
    # raw 512-by-256 kernel differential
    tm = D._tobig(typemax(UInt256))
    for _ in 1:30000
        db = rand(rng, big(1):big(2)^rand(rng, 1:255))
        hib = rand(rng, big(0):(db - 1))
        lob = rand(rng, big(0):tm)
        q, r = D._divrem_512(D._fromfullbig(UInt256, hib), D._fromfullbig(UInt256, lob),
                             D._fromfullbig(UInt256, db))
        qb, rb = divrem((hib << 256) | lob, db)
        @test D._tobig(q) == qb
        @test D._tobig(r) == rb
    end
end
