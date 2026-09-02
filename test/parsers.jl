# Parsers.jl extension tests: fast path agreement with the core parser, wide
# and sticky inputs against a BigInt oracle, tokenizer semantics.
using Decimals, Parsers
using Decimals: unscaled, scale, _tobigsigned
using BitIntegers
using Test, Random

@testset "parsers ext" begin
    @testset "whole-value basics" begin
        @test Parsers.parse(Decimal{18,2}, "1.25") === Decimal{18,2}("1.25")
        @test Parsers.parse(Decimal64{2}, " -42.055 ") === Decimal{18,2}("-42.06")
        @test Parsers.parse(Decimal64{2}, "1e3") === Decimal{18,2}(1000)
        @test Parsers.parse(Decimal64{4}, "125e-2") === Decimal{18,4}("1.25")
        @test Parsers.parse(Decimal64{2}, "1.") === Decimal{18,2}(1)
        @test Parsers.parse(Decimal64{2}, ".5") === Decimal{18,2}("0.5")
        @test Parsers.parse(Decimal64{2}, "1,25", decimal=',') === Decimal{18,2}("1.25")
        @test Parsers.parse(Decimal64{1}, "1.25", rounding=RoundUp) === Decimal{18,1}("1.3")
        @test Parsers.parse(Decimal64{1}, "1.25", rounding=RoundToZero) === Decimal{18,1}("1.2")
        @test Parsers.tryparse(Decimal64{2}, "abc") === nothing
        @test Parsers.tryparse(Decimal64{2}, "1e") === nothing
        @test Parsers.tryparse(Decimal64{2}, "1.2.3") === nothing
        @test Parsers.tryparse(Decimal64{2}, "") === nothing
        @test Parsers.tryparse(Decimal64{2}, ".") === nothing
        @test Parsers.tryparse(Decimal64{2}, "-") === nothing
        @test Parsers.tryparse(Decimal64{2}, "99999999999999999") === nothing
        @test_throws ArgumentError Parsers.parse(Decimal64{2}, "abc")
        @test_throws OverflowError Parsers.parse(Decimal64{2}, "99999999999999999")
        # span form
        b = codeunits("xx1.25yy")
        @test Parsers.parse(Decimal64{2}, b, 3, 6) === Decimal{18,2}("1.25")
        @test Parsers.tryparse(Decimal64{2}, b, 3, 7) === nothing
        # DecimalValue
        @test Parsers.parse(DecimalValue{Int64}, "12.345") === DecimalValue(12345, 3)
        @test Parsers.parse(DecimalValue{Int64}, "1e5") === DecimalValue(100000, 0)
        @test Parsers.tryparse(DecimalValue{Int64}, "0." * "1"^100) === nothing
        @test Parsers.parse(DecimalValue, "2.5") === DecimalValue{Int64}(25, 1)
    end

    @testset "agreement with core parser" begin
        rng = Xoshiro(5001)
        for _ in 1:20000
            ip = rand(rng, 0:1) == 1 ? string(rand(rng, 0:99999999)) : ""
            fp = rand(rng, 0:1) == 1 ? "." * string(rand(rng, 0:999999)) : ""
            ex = rand(rng, 0:3) == 0 ? "e" * string(rand(rng, -8:8)) : ""
            sgn = rand(rng, ("", "-", "+"))
            str = sgn * ip * fp * ex
            for DT in (Decimal{38,6,Int128}, Decimal{18,4,Int64}, DecimalValue{Int128})
                a = Parsers.tryparse(DT, str)
                b = Base.tryparse(DT, str)
                @test a === b
            end
        end
        # long inputs (wide accumulation + sticky) agree too
        for _ in 1:2000
            nint = rand(rng, 0:90)
            nfrac = rand(rng, 0:90)
            nint + nfrac == 0 && continue
            str = String(rand(rng, UInt8('0'):UInt8('9'), nint)) *
                  (nfrac > 0 ? "." * String(rand(rng, UInt8('0'):UInt8('9'), nfrac)) : "")
            for DT in (Decimal{38,6,Int128}, Decimal{76,40,Int256})
                @test Parsers.tryparse(DT, str) === Base.tryparse(DT, str)
            end
        end
    end

    @testset "wide + sticky oracle" begin
        rng = Xoshiro(5002)
        # rounding a long fraction to scale S must match the BigInt oracle
        for _ in 1:2000
            nfrac = rand(rng, 1:120)
            intpart = string(rand(rng, 0:999))
            fracpart = String(rand(rng, UInt8('0'):UInt8('9'), nfrac))
            str = intpart * "." * fracpart
            v = Parsers.parse(Decimal{38,9,Int128}, str)
            num = Base.parse(BigInt, intpart * fracpart)
            want = div(num * big(10)^9, big(10)^nfrac, RoundNearest)
            # RoundNearest on exact ties differs from half-even only at true
            # ties; construct the oracle with explicit half-even semantics
            q, r = divrem(num * big(10)^9, big(10)^nfrac)
            half2 = 2r - big(10)^nfrac
            want = q + (half2 > 0 || (half2 == 0 && isodd(q)) ? 1 : 0)
            @test _tobigsigned(unscaled(v)) == want
        end
        # exact tie at the 77-digit retention boundary
        s = "1." * "0"^75 * "5"
        v = Parsers.parse(Decimal{76,75,Int256}, s)
        @test unscaled(v) == Int256(10)^75  # true tie, q even -> stays
        s2 = "1." * "0"^75 * "5" * "0"^40 * "1"  # sticky breaks the tie up
        v2 = Parsers.parse(Decimal{76,75,Int256}, s2)
        @test unscaled(v2) == Int256(10)^75 + 1
        # huge exponents
        @test Parsers.parse(Decimal64{2}, "1e-100") === zero(Decimal64{2})
        @test Parsers.tryparse(Decimal64{2}, "1e100") === nothing
        @test Parsers.parse(Decimal64{2}, "0e999999") === zero(Decimal64{2})
    end

    @testset "parsenext" begin
        buf = codeunits("12.5,abc,3.75")
        v, pos, rc = Parsers.parsenext(Decimal64{2}, buf, 1, length(buf))
        @test v === Decimal{18,2}("12.50") && pos == 5 && rc == Parsers.RC_OK
        v, pos, rc = Parsers.parsenext(Decimal64{2}, buf, 5, length(buf))
        @test rc == Parsers.RC_INVALID && pos == 5
        v, pos, rc = Parsers.parsenext(Decimal64{2}, buf, 10, length(buf))
        @test v === Decimal{18,2}("3.75") && pos == 14 && rc == Parsers.RC_OK
        # incomplete exponent: token stops before the marker
        b2 = codeunits("1.2e+,x")
        v, pos, rc = Parsers.parsenext(Decimal64{2}, b2, 1, length(b2))
        @test v === Decimal{18,2}("1.20") && pos == 4 && rc == Parsers.RC_OK
        b3 = codeunits("1.2E7;")
        v, pos, rc = Parsers.parsenext(Decimal{18,0,Int64}, b3, 1, length(b3))
        @test v === Decimal{18,0}(12000000) && pos == 6 && rc == Parsers.RC_OK
        # overflow token is consumed with RC_OVERFLOW
        b4 = codeunits("99999999999999999999,")
        v, pos, rc = Parsers.parsenext(Decimal64{2}, b4, 1, length(b4))
        @test rc == Parsers.RC_OVERFLOW && pos == 21
        # no whitespace skipping
        b5 = codeunits(" 1")
        v, pos, rc = Parsers.parsenext(Decimal64{2}, b5, 1, 2)
        @test rc == Parsers.RC_INVALID && pos == 1
    end

    @testset "allocation-free" begin
        pf(s) = Parsers.parse(Decimal64{2}, s)
        pt(s) = Parsers.tryparse(Decimal{38,9,Int128}, s)
        buf = codeunits("12.5,abc")
        pn(b) = Parsers.parsenext(Decimal64{2}, b, 1, length(b))
        pf("123.45"); pt("123.456789"); pn(buf)
        @test_allocfree pf("123.45")
        @test_allocfree pt("123.456789")
        @test_allocfree pn(buf)
    end
end
