# Type-layer tests: construction, conversion, comparison, hashing, parse/print.
using Decimals
using Decimals: unscaled, scale, _tobigsigned
using BitIntegers
using Test, Random

# exact value of any decimal as Rational{BigInt}
oracle(x) = _tobigsigned(unscaled(x)) // big(10)^scale(x)
oracle(x::Integer) = big(x) // 1
oracle(x::Rational) = big(x.num) // big(x.den)

const COMBOS = ((9, 0, Int32), (9, 2, Int32), (18, 0, Int64), (18, 2, Int64),
                (18, 9, Int64), (38, 2, Int128), (38, 20, Int128),
                (76, 2, Int256), (76, 40, Int256))

_randdec(rng, ::Type{Decimal{P, S, T}}) where {P, S, T} =
    reinterpret(Decimal{P, S, T},
                rand(rng, (-10^min(P, 15) + 1):(10^min(P, 15) - 1)) % T)

@testset "construction and accessors" begin
    @test Decimal{18,2}(5) === reinterpret(Decimal64{2}, Int64(500))
    @test unscaled(Decimal{18,2}(5)) === Int64(500)
    @test scale(Decimal{18,2}(5)) == 2
    @test precision(typeof(Decimal{18,2}(5))) == 18
    @test Decimal32{2} === Decimal{9,2,Int32}
    @test Decimal256{2} === Decimal{76,2,Int256}
    @test_throws ArgumentError reinterpret(Decimal{0,0,Int32}, Int32(1))
    @test_throws ArgumentError reinterpret(Decimal{10,0,Int32}, Int32(1))
    @test_throws ArgumentError reinterpret(Decimal{9,10,Int32}, Int32(1))
    @test DecimalValue(125, 2) == DecimalValue{Int64}(125, 2)
    @test_throws ArgumentError DecimalValue(1, -1)
    @test_throws ArgumentError DecimalValue(1, 20000)
    @test iszero(zero(Decimal64{3})) && isone(one(Decimal64{3}))
    @test_throws OverflowError one(Decimal{9,9,Int32})
    @test string(typemax(Decimal{9,2,Int32})) == "9999999.99"
    @test typemin(Decimal64{2}) == -typemax(Decimal64{2})
    @test eps(Decimal64{2}) == Decimal{18,2}("0.01")
    @test widen(Decimal64{2}) === Decimal{38,2,Int128}
    @test widen(Decimal{38,2,Int128}) === Decimal{76,2,Int256}
    @test widen(Decimal256{2}) === Decimal256{2}
    @test widen(DecimalValue{Int256}) === DecimalValue{Int256}
    @test eps(DecimalValue{Int64}(120, 2)) === DecimalValue{Int64}(1, 2)
    vmin = DecimalValue{Int64}(typemin(Int64), 0)
    @test parse(DecimalValue{Int64}, string(vmin)) === vmin
    @test DecimalValue{Int64}(typemin(Int64) // 1) === vmin
    @test DecimalValue{Int64}(Float64(typemin(Int64))) === vmin
    @test hash(vmin) == hash(big(typemin(Int64)))
    @test_throws OverflowError -vmin
    @test_throws OverflowError abs(vmin)
end

@testset "integer conversion" begin
    rng = Xoshiro(2001)
    for (P, S, T) in COMBOS
        DT = Decimal{P, S, T}
        lim = 10^min(P - S, 15) - 1
        for _ in 1:200
            x = rand(rng, -lim:lim)
            d = DT(x)
            @test oracle(d) == x
            @test Int(d) === x
            @test isinteger(d)
        end
        @test_throws OverflowError DT(big(10)^(P - S))
    end
    @test Int8(Decimal{18,2}(42)) === Int8(42)
    @test_throws InexactError Int8(Decimal{18,2}(1000))
    @test BigInt(Decimal{18,2}(7)) == 7
    @test Bool(Decimal{18,2}(1)) === true
end

@testset "rational conversion" begin
    @test Decimal{9,2}(1//4) === Decimal{9,2}("0.25")
    @test Decimal{18,6}(1//8) === Decimal{18,6}("0.125000")
    @test_throws InexactError Decimal{9,2}(1//3)
    @test round(Decimal{9,2}, 1//3) === Decimal{9,2}("0.33")
    @test round(Decimal{9,2}, 2//3, RoundUp) === Decimal{9,2}("0.67")
    @test Rational(Decimal{18,2}("1.25")) === 5//4
    @test Rational{Int32}(Decimal{18,2}("1.25")) === Int32(5)//Int32(4)
    @test Decimal{38,10}(big(1)//big(3) * 0) == 0
    @test round(Decimal{18,2}, big(1)//big(3)) === Decimal{18,2}("0.33")
    large = (big(2)^300 + 1) // (big(2)^301 + 3)
    @test round(Decimal{18,4}, large) === Decimal{18,4}("0.5000")
    @test round(Decimal{18,4}, -large, RoundDown) === Decimal{18,4}("-0.5000")
    wide_den = (UInt256(1) << 255) + UInt256(1)
    near_one = Rational{UInt256}(wide_den - UInt256(1), wide_den)
    @test round(Decimal{1,0}, near_one) === Decimal{1,0}(1)
    rng = Xoshiro(2002)
    for _ in 1:500
        n = rand(rng, -10^6:10^6)
        d = rand(rng, 1:10^4)
        r = n // d
        got = round(Decimal{38,10,Int128}, r)
        want = div(big(n) * big(10)^10, big(d), RoundNearest) * sign(big(d))
        @test _tobigsigned(unscaled(got)) == want
    end
end

@testset "float conversion" begin
    @test Decimal{9,2}(0.1) === Decimal{9,2}("0.10")
    @test Decimal{18,4}(2.5) === Decimal{18,4}("2.5000")
    @test Decimal{38,20}(0.1) == Decimal{38,20}("0.10000000000000000555")
    @test Decimal{18,2}(-1.005) == Decimal{18,2}("-1.00")  # 1.005 is below the tie in binary
    @test_throws InexactError Decimal{18,2}(Inf)
    @test_throws InexactError Decimal{18,2}(NaN)
    @test Decimal{18,2}(-0.0) === zero(Decimal64{2})
    @test round(Decimal{18,2}, 1.005, RoundUp) === Decimal{18,2}("1.01")
    setprecision(BigFloat, 512) do
        @test Decimal{18,2}(BigFloat("0.1")) === Decimal{18,2}("0.10")
        @test round(Decimal{18,2}, -BigFloat("0.101"), RoundDown) ===
              Decimal{18,2}("-0.11")
        @test Decimal{18,2}(BigFloat("1e-1000")) === zero(Decimal64{2})
        @test_throws OverflowError Decimal{18,2}(BigFloat("1e1000"))
    end
    # exotic magnitudes round to zero / throw appropriately
    @test Decimal{18,2}(1.0e-300) === zero(Decimal64{2})
    @test_throws OverflowError Decimal{18,2}(1.0e300)
    # exact float -> DecimalValue
    v = DecimalValue(0.1)
    @test scale(v) == 55 && v == 0.1
    @test DecimalValue(2.5) == 2.5 && scale(DecimalValue(2.5)) == 1
    @test DecimalValue(Float32(0.5)) == 0.5
    # Decimal -> Float roundtrips through the correctly-rounded converter
    rng = Xoshiro(2003)
    for (P, S, T) in COMBOS
        DT = Decimal{P, S, T}
        for _ in 1:200
            d = _randdec(rng, DT)
            f = Float64(d)
            @test f === parse(Float64, string(d))  # Base float parse is the oracle
        end
    end
    @test Float64(Decimal{76,40}("0.1")) === 0.1
    @test Float32(Decimal{18,2}("1.25")) === 1.25f0
    @test reinterpret(UInt16, Float16(DecimalValue{Int64}(1760597127, 14))) == 0x0127
    @test reinterpret(UInt32, Float32(DecimalValue{Int64}(943052102, 47))) == 0x0066b075
    @test reinterpret(UInt64, Float64(DecimalValue{Int64}(4362848394127855029, 327))) ==
          0x000323212e2e46fb
end

@testset "decimal<->decimal and rescale" begin
    @test convert(Decimal{18,4}, Decimal{9,2}("1.25")) === Decimal{18,4}("1.2500")
    @test convert(Decimal{9,2}, Decimal{18,4}("1.2500")) === Decimal{9,2}("1.25")
    @test_throws InexactError convert(Decimal{9,1}, Decimal{18,2}("1.25"))
    @test_throws OverflowError convert(Decimal{9,2}, Decimal{18,2}("99999999.00"))
    @test rescale(Decimal{9,1}, Decimal{18,2}("1.25")) === Decimal{9,1}("1.2")
    @test rescale(Decimal{9,1}, Decimal{18,2}("1.35"), RoundUp) === Decimal{9,1}("1.4")
    @test rescale(DecimalValue(12345, 3), 1) === DecimalValue(123, 1)
    @test rescale(DecimalValue(12345, 3), 5) === DecimalValue(1234500, 5)
    @test rescale(DecimalValue(125, 2), 1, RoundUp) === DecimalValue(13, 1)
    v = DecimalValue(Decimal{18,3}("1.25"))
    @test v === DecimalValue{Int64}(1250, 3)
    @test Decimal{18,3}(v) === Decimal{18,3}("1.250")
end

@testset "comparison" begin
    rng = Xoshiro(2004)
    types = (Decimal{9,2,Int32}, Decimal{18,4,Int64}, Decimal{38,9,Int128},
             Decimal{76,15,Int256})
    for A in types, B in types
        for _ in 1:200
            a = _randdec(rng, A)
            b = _randdec(rng, B)
            @test (a == b) == (oracle(a) == oracle(b))
            @test (a < b) == (oracle(a) < oracle(b))
            @test (a <= b) == (oracle(a) <= oracle(b))
            @test isless(a, b) == (oracle(a) < oracle(b))
        end
    end
    # vs other Reals
    for _ in 1:500
        a = _randdec(rng, Decimal{18,4,Int64})
        y = rand(rng, -1000:1000)
        @test (a == y) == (oracle(a) == y)
        @test (a < y) == (oracle(a) < y)
        @test (y < a) == (y < oracle(a))
        f = rand(rng) * 200 - 100
        @test (a < f) == (oracle(a) < oracle(Rational{BigInt}(f)))
        @test (a == f) == (oracle(a) == oracle(Rational{BigInt}(f)))
        r = rand(rng, -100:100) // rand(rng, 1:100)
        @test (a == r) == (oracle(a) == oracle(r))
        @test (a < r) == (oracle(a) < oracle(r))
    end
    @test Decimal{18,2}("1.20") == Decimal{9,1}("1.2") == DecimalValue(12, 1)
    @test Decimal{18,2}("0.10") != 0.1
    @test DecimalValue(0.1) == 0.1
    @test !(Decimal{18,2}(1) < NaN) && isless(Decimal{18,2}(1), NaN)
    @test Decimal{18,2}(1) < Inf && -Inf < Decimal{18,2}(1)
    @test isequal(Decimal{18,2}(1), Decimal{18,2}(1))
end

@testset "hashing" begin
    rng = Xoshiro(2005)
    @test hash(Decimal{18,2}(5)) == hash(5) == hash(Decimal{76,30}(5))
    @test hash(Decimal{18,2}("1.25")) == hash(1.25) == hash(5//4)
    @test hash(Decimal{18,2}("1.20")) == hash(Decimal{9,1}("1.2"))
    @test hash(Decimal{18,2}("0.10")) == hash(1//10)
    @test hash(zero(Decimal64{5})) == hash(0)
    @test hash(typemin(Decimal{9,2,Int32})) == hash(oracle(typemin(Decimal{9,2,Int32})))
    for (P, S, T) in COMBOS
        DT = Decimal{P, S, T}
        for _ in 1:100
            d = _randdec(rng, DT)
            @test hash(d) == hash(oracle(d))
        end
    end
    for _ in 1:100
        u = rand(rng, -10^12:10^12)
        s = rand(rng, 0:20)
        v = DecimalValue{Int64}(u, s)
        @test hash(v) == hash(oracle(v))
    end
end

@testset "parse and print" begin
    rng = Xoshiro(2006)
    @test string(Decimal{18,2}(5)) == "5.00"
    @test string(Decimal{18,2}("-0.05")) == "-0.05"
    @test string(Decimal{18,0}(-7)) == "-7"
    @test string(DecimalValue(0, 3)) == "0.000"
    @test parse(Decimal64{2}, " 1.25 ") === Decimal{18,2}("1.25")
    @test parse(Decimal{9,2}, "1.25") === Decimal{9,2}("1.25")
    @test tryparse(Decimal{9,2}, "1.25") === Decimal{9,2}("1.25")
    @test parse(Decimal64{2}, "+1.25") === Decimal{18,2}("1.25")
    @test parse(Decimal64{4}, "1.25e2") === Decimal{18,4}("125.0000")
    @test parse(Decimal64{4}, "125e-2") === Decimal{18,4}("1.2500")
    @test_throws InexactError parse(Decimal64{2}, "1.234")
    @test tryparse(Decimal64{2}, "1.234") === nothing
    @test parse(DecimalValue{Int64}, "1e5") === DecimalValue(100000, 0)
    @test tryparse(Decimal64{2}, "abc") === nothing
    @test tryparse(Decimal64{2}, "1.2.3") === nothing
    @test tryparse(Decimal64{2}, "") === nothing
    @test tryparse(Decimal64{2}, "1e") === nothing
    huge = string(big(2)^256 - 100)
    @test_throws OverflowError parse(Decimal{9,0,Int32}, huge)
    @test_throws OverflowError parse(Decimal{9,0,Int32}, "-" * huge)
    @test parse(Decimal{1,0}, string(big(10)^77) * "e-77") === Decimal{1,0}(1)
    for (P, S, T) in COMBOS
        DT = Decimal{P, S, T}
        for _ in 1:200
            d = _randdec(rng, DT)
            @test parse(DT, string(d)) === d
        end
    end
    # show round-trips
    x = Decimal{18,2}("-42.07")
    @test eval(Meta.parse(repr(x))) === x
    v = DecimalValue(125, 2)
    @test eval(Meta.parse(repr(v))) == v
end

@testset "promotion" begin
    @test promote_type(Decimal{9,2,Int32}, Decimal{18,4,Int64}) === Decimal{18,4,Int64}
    @test promote_type(Decimal{9,0,Int32}, Decimal{9,5,Int32}) === Decimal{14,5,Int64}
    @test promote_type(Decimal64{2}, Int64) === Decimal{21,2,Int128}
    @test promote_type(Decimal64{2}, Int8) === Decimal{18,2,Int64}
    @test promote_type(Decimal64{2}, Float64) === Float64
    @test promote_type(Decimal64{2}, Rational{Int}) === Rational{Int64}
    @test promote_type(DecimalValue{Int64}, DecimalValue{Int128}) === DecimalValue{Int128}
    @test promote_type(DecimalValue{Int64}, Decimal{38,2,Int128}) === DecimalValue{Int128}
    @test promote_type(DecimalValue{Int64}, Int32) === DecimalValue{Int64}
    @test promote_type(DecimalValue{Int32}, UInt32) === DecimalValue{Int64}
    @test promote_type(DecimalValue{Int128}, UInt128) === DecimalValue{Int256}
    @test promote_type(DecimalValue{Int256}, UInt256) === DecimalValue{Int256}
    @test DecimalValue{Int128}(1, 2) + UInt128(1) === DecimalValue{Int256}(101, 2)
    @test UInt128(1) + DecimalValue{Int128}(1, 2) === DecimalValue{Int256}(101, 2)
end
