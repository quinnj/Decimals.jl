# Arithmetic differential tests against the Rational{BigInt} oracle.
using Decimals
using Decimals: unscaled, scale, _tobigsigned, _maxmag, _tobig
using Decimals: Int256, UInt256
using Test, Random

arithmetic_oracle(x) = _tobigsigned(unscaled(x)) // big(10)^scale(x)

maxmagbig(DT) = _tobig(_maxmag(DT))

function checkexact(op, a, b, got)
    expected = op(arithmetic_oracle(a), arithmetic_oracle(b))
    @test arithmetic_oracle(got) == expected
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
                expected = f(arithmetic_oracle(a), arithmetic_oracle(b))
                if fits(expected, RT)
                    got = f(a, b)
                    @test typeof(got) === RT
                    @test arithmetic_oracle(got) == expected
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
            expected = arithmetic_oracle(a) * arithmetic_oracle(b)
            got = a * b
            @test arithmetic_oracle(got) == expected
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
            q = arithmetic_oracle(a) / arithmetic_oracle(b)
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

@testset "integer quotient and remainder" begin
    D = Decimal{18,2,Int64}
    modes = (RoundNearest, RoundNearestTiesAway, RoundNearestTiesUp,
             RoundToZero, RoundFromZero, RoundDown, RoundUp)
    for (a, b) in ((D("5.50"), D("2.00")),
                   (D("-5.00"), D("2.00")),
                   (D("5.00"), D("-2.00")),
                   (D("-5.00"), D("-2.00")))
        ratio = arithmetic_oracle(a) / arithmetic_oracle(b)
        for mode in modes
            wantq = div(numerator(ratio), denominator(ratio), mode)
            gotq = div(a, b, mode)
            gotr = rem(a, b, mode)
            @test typeof(gotq) === D
            @test typeof(gotr) === D
            @test arithmetic_oracle(gotq) == wantq
            @test arithmetic_oracle(gotr) ==
                  arithmetic_oracle(a) - arithmetic_oracle(b) * wantq
            @test arithmetic_oracle(a) ==
                  arithmetic_oracle(b) * arithmetic_oracle(gotq) +
                  arithmetic_oracle(gotr)
            @test divrem(a, b, mode) === (gotq, gotr)
        end
    end

    a = Decimal{18,1,Int64}("5.5")
    b = Decimal{9,2,Int32}("0.20")
    RT = promote_type(typeof(a), typeof(b))
    @test div(a, b) === RT("27.00")
    @test rem(a, b) === RT("0.10")
    @test mod(-a, b) === RT("0.10")
    @test fld(-a, b) === RT("-28.00")
    @test cld(a, b) === RT("28.00")
    @test fldmod(-a, b) === (RT("-28.00"), RT("0.10"))
    @test fld1(a, b) === RT("28.00")
    @test mod1(a, b) === RT("0.10")
    @test fldmod1(a, b) === (RT("28.00"), RT("0.10"))
    @test collect(D("1.20"):D("0.10"):D("1.50")) ==
          D[D("1.20"), D("1.30"), D("1.40"), D("1.50")]
    @test_throws DivideError div(a, zero(b))
    @test_throws DivideError rem(a, zero(b))
    @test_throws OverflowError div(typemax(Decimal64{2}), eps(Decimal64{2}))
    @test rem(typemax(Decimal64{2}), eps(Decimal64{2})) === zero(Decimal64{2})

    x = DecimalValue{Int256}(1, 0)
    tiny = DecimalValue{Int256}(1, 100)
    @test rem(x, tiny) === DecimalValue{Int256}(0, 100)
    @test_throws OverflowError div(x, tiny)
    vx = DecimalValue{Int64}(-550, 2)
    vy = DecimalValue{Int64}(200, 2)
    @test div(vx, vy, RoundNearest) === DecimalValue{Int64}(-300, 2)
    @test rem(vx, vy, RoundNearest) === DecimalValue{Int64}(50, 2)
    @test fld(vx, vy) === DecimalValue{Int64}(-300, 2)
    @test cld(-vx, vy) === DecimalValue{Int64}(300, 2)
    small = DecimalValue{Int64}(1, 1)
    large = DecimalValue{Int64}(typemax(Int64), 0)
    @test div(small, large, RoundFromZero) === DecimalValue{Int64}(10, 1)
    @test_throws OverflowError rem(small, large, RoundFromZero)
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
    v = DecimalValue{Int64}(255, 2)
    @test round(v; digits=1) === DecimalValue{Int64}(260, 2)
    @test trunc(DecimalValue{Int64}(-299, 2)) === DecimalValue{Int64}(-200, 2)
    @test floor(DecimalValue{Int64}(-201, 2)) === DecimalValue{Int64}(-300, 2)
    @test ceil(DecimalValue{Int64}(201, 2)) === DecimalValue{Int64}(300, 2)
    @test round(DecimalValue{Int64}(1499, 2); digits=-1) === DecimalValue{Int64}(1000, 2)
    @test_throws OverflowError round(DecimalValue{Int32}(typemax(Int32), 1))
    @test round(d("1.25"); digits=typemin(Int)) === zero(Decimal64{2})
    @test round(v; digits=typemin(Int)) === DecimalValue{Int64}(0, 2)
    @test_throws OverflowError round(d("1.25"), RoundUp; digits=typemin(Int))
    @test_throws OverflowError round(v, RoundFromZero; digits=big(typemin(Int)) - 1)
    for _ in 1:500
        a = _randdec(rng, Decimal{38,9,Int128}, 12)
        dg = rand(rng, 0:9)
        mode = rand(rng, (RoundNearest, RoundToZero, RoundDown, RoundUp))
        got = round(a, mode; digits=dg)
        want = div(_tobigsigned(unscaled(a)), big(10)^(scale(a) - dg), mode) //
               big(10)^dg
        @test arithmetic_oracle(got) == want
    end
end

@testset "sum" begin
    rng = Xoshiro(3005)
    v = [_randdec(rng, Decimal{18,4,Int64}, 12) for _ in 1:10_000]
    s = sum(v)
    @test typeof(s) === Decimal{38,4,Int128}
    @test arithmetic_oracle(s) == sum(arithmetic_oracle, v)
    v32 = [_randdec(rng, Decimal{9,2,Int32}, 7) for _ in 1:10_000]
    s32 = sum(v32)
    @test typeof(s32) === Decimal{38,2,Int128}
    @test arithmetic_oracle(s32) == sum(arithmetic_oracle, v32)
    v256 = [_randdec(rng, Decimal{76,15,Int256}, 20) for _ in 1:1_000]
    @test arithmetic_oracle(sum(v256)) == sum(arithmetic_oracle, v256)
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
    @test d + big(2) === Decimal{76,2,Int256}("3.25")
    @test big(2) + d === Decimal{76,2,Int256}("3.25")
    @test d * big(2) === Decimal{76,2,Int256}("2.50")
    @test big(3) * d === Decimal{76,2,Int256}("3.75")
    @test_throws OverflowError d * big(10)^100
    a = DecimalValue(125, 2)
    @test a + Decimal{18,1}("0.5") == 1.75
    @test a * a == DecimalValue(15625, 4)
    @test a + big(2) === DecimalValue{Int256}(325, 2)
    @test a * big(2) === DecimalValue{Int64}(250, 2)
    @test_throws OverflowError a * big(10)^100
    @test divide(d, DecimalValue{Int64}(50, 1)) === DecimalValue{Int64}(25, 2)
    @test divide(DecimalValue{Int64}(50, 1), d) === DecimalValue{Int64}(400, 2)
end

@testset "DecimalValue arithmetic" begin
    rng = Xoshiro(3006)
    for _ in 1:2000
        ua, sa = rand(rng, -10^12:10^12), rand(rng, 0:15)
        ub, sb = rand(rng, -10^12:10^12), rand(rng, 0:15)
        a = DecimalValue{Int128}(ua, sa)
        b = DecimalValue{Int128}(ub, sb)
        @test arithmetic_oracle(a + b) ==
              arithmetic_oracle(a) + arithmetic_oracle(b)
        @test arithmetic_oracle(a - b) ==
              arithmetic_oracle(a) - arithmetic_oracle(b)
        @test arithmetic_oracle(a * b) ==
              arithmetic_oracle(a) * arithmetic_oracle(b)
        if !iszero(b)
            s = max(sa, sb)
            q = arithmetic_oracle(a) / arithmetic_oracle(b)
            want = div(numerator(q) * big(10)^s, denominator(q), RoundNearest)
            @test _tobigsigned(unscaled(a / b)) == want
        end
    end
    @test_throws OverflowError DecimalValue{Int64}(5 * 10^18, 0) + DecimalValue{Int64}(5 * 10^18, 0)
    vmin = DecimalValue{Int64}(typemin(Int64), 0)
    oneval = one(DecimalValue{Int64})
    @test vmin * Int8(1) === vmin
    @test vmin * oneval === vmin
    @test divide(vmin, oneval) === vmin
end

@testset "allocation-free ops" begin
    a = Decimal{18,4}("1234.5678")
    b = Decimal{18,4}("87.6543")
    c = Decimal{38,9,Int128}("123456.789")
    e = Decimal{76,15,Int256}("9999.5")
    addf(x, y) = x + y
    mulf(x, y) = x * y
    divf(x, y) = x / y
    qrf(x, y) = divrem(x, y, RoundNearest)
    cmpf(x, y) = x < y
    for f in (addf, mulf, divf, qrf, cmpf)
        f(a, b); f(c, c); f(e, e)
        @test_allocfree f(a, b)
        @test_allocfree f(c, c)
        @test_allocfree f(e, e)
    end
    rf(x) = round(x, digits=1)
    rf(a); rf(c)
    @test_allocfree rf(a)
    @test_allocfree rf(c)
    v = DecimalValue{Int64}(12345, 3)
    rf(v)
    @test_allocfree rf(v)
    vmin = DecimalValue{Int64}(typemin(Int64), 0)
    oneval = one(DecimalValue{Int64})
    mulf(vmin, oneval); divf(vmin, oneval)
    @test_allocfree mulf(vmin, oneval)
    @test_allocfree divf(vmin, oneval)
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
