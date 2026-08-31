# Arithmetic differential tests against the Rational{BigInt} oracle.
using Decimals
using Decimals: unscaled, scale, _tobigsigned, _maxmag, _tobig
using BitIntegers
using Test, Random

oracle(x) = _tobigsigned(unscaled(x)) // big(10)^scale(x)

maxmagbig(DT) = _tobig(_maxmag(DT))

function checkexact(op, a, b, got)
    expected = op(oracle(a), oracle(b))
    @test oracle(got) == expected
    return nothing
end

# does the exact result fit the result type?
fits(expected::Rational{BigInt}, RT) =
    abs(numerator(expected * big(10)^scale(RT))) <= maxmagbig(RT)

const ARITHTYPES = (Decimal{9,2,Int32}, Decimal{18,4,Int64}, Decimal{18,0,Int64},
                    Decimal{38,9,Int128}, Decimal{38,30,Int128},
                    Decimal{76,15,Int256})

_randdec(rng, ::Type{Decimal{P, S, T}}, digs) where {P, S, T} =
    reinterpret(Decimal{P, S, T},
                rand(rng, (-10^min(P, digs) + 1):(10^min(P, digs) - 1)) % T)

@testset "add/sub differential" begin
    rng = Xoshiro(3001)
    for A in ARITHTYPES, B in ARITHTYPES
        RT = promote_type(A, B)
        for _ in 1:300
            a = _randdec(rng, A, 14)
            b = _randdec(rng, B, 14)
            for (op, f) in ((:+, +), (:-, -))
                expected = f(oracle(a), oracle(b))
                if fits(expected, RT)
                    got = f(a, b)
                    @test typeof(got) === RT
                    @test oracle(got) == expected
                else
                    @test_throws OverflowError f(a, b)
                end
            end
        end
    end
    # overflow boundary
    @test_throws OverflowError typemax(Decimal64{2}) + eps(Decimal64{2})
    @test typemax(Decimal64{2}) + (-eps(Decimal64{2})) ==
          typemax(Decimal64{2}) - eps(Decimal64{2})
    @test_throws OverflowError typemin(Decimal64{2}) - eps(Decimal64{2})
end

@testset "mul differential" begin
    rng = Xoshiro(3002)
    for A in ARITHTYPES, B in ARITHTYPES
        scale(A) + scale(B) > 76 && continue
        for _ in 1:300
            a = _randdec(rng, A, 9)
            b = _randdec(rng, B, 9)
            expected = oracle(a) * oracle(b)
            got = a * b
            @test oracle(got) == expected
            @test scale(typeof(got)) == scale(A) + scale(B)
        end
    end
    # product overflow at the 76-digit cap
    big76 = reinterpret(Decimal{76,0,Int256}, Int256(10)^75)
    @test_throws OverflowError big76 * big76
    # scale cap
    a = zero(Decimal{76,40,Int256})
    @test_throws ArgumentError a * a
end

@testset "div differential" begin
    rng = Xoshiro(3003)
    modes = (RoundNearest, RoundNearestTiesAway, RoundToZero, RoundFromZero,
             RoundDown, RoundUp)
    for A in ARITHTYPES, B in ARITHTYPES
        for _ in 1:200
            a = _randdec(rng, A, 10)
            b = _randdec(rng, B, 10)
            iszero(b) && continue
            mode = rand(rng, modes)
            got = divide(a, b, mode)
            S = scale(typeof(got))
            q = oracle(a) / oracle(b)
            want = div(numerator(q) * big(10)^S, denominator(q), mode)
            @test _tobigsigned(unscaled(got)) == want
        end
    end
    @test_throws DivideError Decimal{18,2}(1) / zero(Decimal64{2})
    # exactness of half-even at ties
    d(s) = Decimal{18,2}(s)
    @test divide(d("0.25"), d("2.00")) == parse(Decimal{20,2,Int128}, "0.12")
    @test divide(d("0.75"), d("2.00")) == parse(Decimal{20,2,Int128}, "0.38")
end

@testset "round family" begin
    rng = Xoshiro(3004)
    d(s) = Decimal{18,2}(s)
    @test round(d("2.55"), digits=1) === d("2.60")
    @test round(d("2.45"), digits=1) === d("2.40")
    @test round(d("2.55"), RoundNearestTiesAway, digits=1) === d("2.60")
    @test trunc(d("2.99")) === d("2.00")
    @test floor(d("-2.01")) === d("-3.00")
    @test ceil(d("2.01")) === d("3.00")
    @test round(d("1.23"), digits=5) === d("1.23")
    for _ in 1:500
        a = _randdec(rng, Decimal{38,9,Int128}, 12)
        dg = rand(rng, 0:9)
        mode = rand(rng, (RoundNearest, RoundToZero, RoundDown, RoundUp))
        got = round(a, mode; digits=dg)
        want = div(_tobigsigned(unscaled(a)), big(10)^(scale(a) - dg), mode) //
               big(10)^dg
        @test oracle(got) == want
    end
end

@testset "sum" begin
    rng = Xoshiro(3005)
    v = [_randdec(rng, Decimal{18,4,Int64}, 12) for _ in 1:10_000]
    s = sum(v)
    @test typeof(s) === Decimal{38,4,Int128}
    @test oracle(s) == sum(oracle, v)
    v32 = [_randdec(rng, Decimal{9,2,Int32}, 7) for _ in 1:10_000]
    s32 = sum(v32)
    @test typeof(s32) === Decimal{38,2,Int128}
    @test oracle(s32) == sum(oracle, v32)
    v256 = [_randdec(rng, Decimal{76,15,Int256}, 20) for _ in 1:1_000]
    @test oracle(sum(v256)) == sum(oracle, v256)
end

@testset "mixed-type arithmetic" begin
    d = Decimal{18,2}("1.25")
    @test d + 1 == 2.25 && 1 + d == 2.25
    @test d * 2 == 2.5 && typeof(d * 2) === Decimal{37,2,Int128}
    @test 3 * d == 3.75
    @test scale(typeof(d * 2)) == 2  # integer multiply preserves scale
    @test d + 0.25 === 1.5
    @test 0.25 + d === 1.5
    @test d * (1//2) === 5//8
    @test d - (1//4) === 1//1
    a = DecimalValue(125, 2)
    @test a + Decimal{18,1}("0.5") == 1.75
    @test a * a == DecimalValue(15625, 4)
end

@testset "DecimalValue arithmetic" begin
    rng = Xoshiro(3006)
    for _ in 1:2000
        ua, sa = rand(rng, -10^12:10^12), rand(rng, 0:15)
        ub, sb = rand(rng, -10^12:10^12), rand(rng, 0:15)
        a = DecimalValue{Int128}(ua, sa)
        b = DecimalValue{Int128}(ub, sb)
        @test oracle(a + b) == oracle(a) + oracle(b)
        @test oracle(a - b) == oracle(a) - oracle(b)
        @test oracle(a * b) == oracle(a) * oracle(b)
        if !iszero(b)
            s = max(sa, sb)
            q = oracle(a) / oracle(b)
            want = div(numerator(q) * big(10)^s, denominator(q), RoundNearest)
            @test _tobigsigned(unscaled(a / b)) == want
        end
    end
    @test_throws OverflowError DecimalValue{Int64}(5 * 10^18, 0) + DecimalValue{Int64}(5 * 10^18, 0)
end

@testset "allocation-free ops" begin
    a = Decimal{18,4}("1234.5678")
    b = Decimal{18,4}("87.6543")
    c = Decimal{38,9,Int128}("123456.789")
    e = Decimal{76,15,Int256}("9999.5")
    addf(x, y) = x + y
    mulf(x, y) = x * y
    divf(x, y) = x / y
    cmpf(x, y) = x < y
    for f in (addf, mulf, divf, cmpf)
        f(a, b); f(c, c); f(e, e)
        @test @allocated(f(a, b)) == 0
        @test @allocated(f(c, c)) == 0
        @test @allocated(f(e, e)) == 0
    end
    rf(x) = round(x, digits=1)
    rf(a); rf(c)
    @test @allocated(rf(a)) == 0
    @test @allocated(rf(c)) == 0
end

@testset "type stability" begin
    a = Decimal{18,4}("12.5")
    b = Decimal{9,2,Int32}("1.5")
    @inferred a + b
    @inferred a * b
    @inferred a / b
    @inferred round(a, digits=2)
    @inferred Float64(a)
    @inferred sum([a, a])
    v = DecimalValue(125, 2)
    @inferred v + v
    @inferred v * v
end
