# Differential tests for the machine-arithmetic fast paths: each is checked
# against the exact (BigInt / general-scanner) route it shortcuts.
using Decimals: Int256, _cmpfloat, _cmpfloatbig, _fromfloat, _fromfloat_big,
                _parsecore, _fitdecimal, _fitvalue, _parsestring

@testset "decimal vs float comparison fast path" begin
    rng = Xoshiro(2024)
    types = (Decimal{9,2,Int32}, Decimal{18,4,Int64}, Decimal{38,9,Int128},
             Decimal{38,0,Int128}, Decimal{76,20,Int256}, Decimal{18,18,Int64})
    oracle(x, y) = sign(cmp(big(x), Rational{BigInt}(y)))
    ncases = 0
    for T in types, _ in 1:1500
        x = rand(rng, T) - rand(rng, T)  # signed, at scale
        # images: the exact float, its neighbours, and unrelated magnitudes
        fx = Float64(x)
        for y in (fx, nextfloat(fx), prevfloat(fx), -fx, fx * 1.5, fx / 3,
                  rand(rng) * 10.0^rand(rng, -12:12) * rand(rng, (-1, 1)),
                  0.0, -0.0, 1e-300, floatmax(Float64), 5e-324)
            @test _cmpfloat(x, y) == oracle(x, y)
            @test (x == y) == (oracle(x, y) == 0)
            @test (x < y) == (oracle(x, y) < 0)
            @test (y < x) == (oracle(x, y) > 0)
            ncases += 1
        end
        y32 = Float32(fx)
        @test _cmpfloat(x, y32) == sign(cmp(big(x), Rational{BigInt}(y32)))
        y16 = Float16(clamp(fx, -60000.0, 60000.0))
        @test _cmpfloat(x, y16) == sign(cmp(big(x), Rational{BigInt}(y16)))
    end
    @test ncases > 100_000
    # DecimalValue scales, including deep scales past the machine path
    for _ in 1:2000
        u = rand(rng, Int64)
        sc = rand(rng, (0, 1, 2, 9, 18, 30, 60, 100, 400, 16383))
        v = DecimalValue{Int64}(u, sc)
        fv = Float64(v)
        for y in (fv, nextfloat(fv), prevfloat(fv), 0.0, 1.0, -1.0)
            @test _cmpfloat(v, y) == sign(cmp(big(v), Rational{BigInt}(y)))
        end
    end
    # zero images: tiny decimals compare correctly against ±0.0
    tiny = DecimalValue{Int64}(1, 400)
    @test Float64(tiny) == 0.0
    @test tiny > 0.0 && tiny > -0.0 && !(tiny == 0.0)
    @test -tiny < 0.0
    @test zero(Decimal64{2}) == -0.0
    # NaN / Inf semantics unchanged
    x = Decimal64{2}("1.25")
    @test !(x == NaN) && !(x < NaN) && isless(x, NaN) && !isless(NaN, x)
    @test x < Inf && -Inf < x && !(x == Inf)
    # big-float route still exact
    @test x == big"1.25" && x < big"1.2500000000000000000001"
end

@testset "Float64 -> Decimal fast path" begin
    rng = Xoshiro(7)
    modes = (RoundNearest, RoundToZero, RoundUp, RoundDown, RoundFromZero,
             RoundNearestTiesAway, RoundNearestTiesUp)
    types = (Decimal{9,2,Int32}, Decimal{18,4,Int64}, Decimal{18,0,Int64},
             Decimal{38,9,Int128}, Decimal{38,22,Int128}, Decimal{38,38,Int128},
             Decimal{76,20,Int256})
    result(f, args...) = try
        (:ok, f(args...))
    catch e
        (:err, typeof(e))
    end
    floats = Float64[]
    for _ in 1:4000
        push!(floats, rand(rng) * 10.0^rand(rng, -30:30) * rand(rng, (-1, 1)))
    end
    append!(floats, [0.5, 1.5, 2.5, 0.125, 0.005, 1234.565, 1e-320, 5e-324, 2^53 - 1.0,
                     2.0^53, 2.0^60, 1e20, 1e30, -0.0, 0.0, 0.1, 0.7, 12.345, 1.0/3])
    for T in types, x in floats, mode in modes
        @test result(_fromfloat, T, x, mode) == result(_fromfloat_big, T, x, mode)
    end
    for x in (Float32(0.1), Float32(1234.5), Float16(3.14), Float32(-2.5)), T in types
        @test result(_fromfloat, T, x, RoundNearest) == result(_fromfloat_big, T, x, RoundNearest)
    end
    @test Decimal64{2}(0.125) === Decimal64{2}("0.12")
    @test Decimal64{2}(0.375) === Decimal64{2}("0.38")
    @test Decimal64{2}(1e-300) === zero(Decimal64{2})
    @test round(Decimal64{2}, 1e-300, RoundUp) === Decimal64{2}("0.01")
    @test_throws OverflowError Decimal64{2}(1e17)
end

@testset "parse (via the Parsers extension) agrees with the core scanner" begin
    rng = Xoshiro(99)
    # the general route the fast path shortcuts
    function general(::Type{DT}, s) where {DT <: Decimal}
        mag, sc, neg, sticky, ok = _parsecore(s)
        ok || return nothing
        v, fit = _fitdecimal(DT, mag, sc, neg, sticky, RoundNearest)
        return fit ? v : nothing
    end
    function general(::Type{DT}, s) where {DT <: DecimalValue}
        mag, sc, neg, sticky, ok = _parsecore(s)
        ok || return nothing
        v, fit = _fitvalue(DT, mag, sc, neg, sticky)
        return fit ? v : nothing
    end
    alphabet = ['0':'9'; '0':'9'; '.'; '-'; '+'; ' '; 'e'; 'x']
    targets = (Decimal{9,2,Int32}, Decimal{18,4,Int64}, Decimal{38,9,Int128},
               Decimal{76,30,Int256}, DecimalValue{Int64}, DecimalValue{Int32})
    for _ in 1:40000
        s = String(rand(rng, alphabet, rand(rng, 1:17)))
        for DT in targets
            @test tryparse(DT, s) === general(DT, s)
        end
        digits = ['0':'9';]
        s = String(vcat(rand(rng, ('-', '+', '1', '9')), rand(rng, digits, rand(rng, 14:39)),
                        ['.'], rand(rng, digits, rand(rng, 0:8))))
        s = length(s) > 41 ? s[1:41] : s
        for DT in targets
            @test tryparse(DT, s) === general(DT, s)
        end
    end
    fixed = ["1", "1.", ".5", "-.5", "+1.25", "0000.10", "-0", "12345678901234.5",
             "1234567890123456", "99999999999999999", "1e2", " 1.5 ", "1.5 ", "1..5",
             "", "-", ".", "+", "1.2.3", "0.000000000000001", "-99999999.99",
             "123456789.123456789", "-123456789012345678.90123456789012345678",
             "99999999999999999999999999999999999999", "100000000000000000000000000000000000000",
             "0000000000000000000000000000000000000001.5", "1234567890123456789012345678901234567890.5",
             "12345678901234567890.123456789012345678e3", "                                       1"]
    for s in fixed, DT in targets
        @test tryparse(DT, s) === general(DT, s)
        g = general(DT, s)
        if g === nothing
            @test_throws Union{ArgumentError, OverflowError} parse(DT, s)
        else
            @test parse(DT, s) === g
        end
    end
    @test parse(Decimal{9,2}, "1.25") === Decimal{9,2,Int32}("1.25")
    @test tryparse(Decimal{9,2}, "1.25") === Decimal{9,2,Int32}("1.25")
    @test tryparse(DecimalValue, "1.25") === DecimalValue{Int64}(125, 2)
    @test tryparse(Decimal64{2}, SubString("x1.25y", 2, 5)) === Decimal64{2}("1.25")
    # the string constructors and literals use the core scanner and agree
    @test Decimal64{2}("1.25") === parse(Decimal64{2}, "1.25") === _parsestring(Decimal64{2}, "1.25")
    @test DecimalValue("1.25") === parse(DecimalValue, "1.25")
    @test_throws ArgumentError Decimal64{2}("nope")
end

@testset "radix sort and min/max over coefficients" begin
    rng = Xoshiro(5)
    for T in (Decimal{9,2,Int32}, Decimal{18,4,Int64}, Decimal{38,9,Int128}, Decimal{76,20,Int256})
        v = [rand(rng, T) - rand(rng, T) for _ in 1:20000]
        s = sort(v)
        @test issorted(s) && s == sort(v; alg=MergeSort)  # comparison-sort oracle
        @test sort(v; rev=true) == reverse(s)
        @test sortperm(v) == sortperm(Decimals.unscaled.(v))
        @test sort(v; by=abs) == sort(v; by=x -> abs(Decimals.unscaled(x)))
        @test maximum(v) === s[end] && minimum(v) === s[1]
        @test maximum(v) === reduce(max, v) && minimum(v) === reduce(min, v)
        m = reshape(v[1:20000], 100, 200)
        @test maximum(m; dims=1) == mapreduce(identity, max, m; dims=1)
        @test minimum(m; dims=2) == mapreduce(identity, min, m; dims=2)
        @test maximum(v; init=typemax(T)) === typemax(T)
        @test_throws Union{ArgumentError, MethodError} maximum(T[])  # 1.10 throws MethodError
    end
    @test sort(Decimal64{2}[]) == Decimal64{2}[]
    @test Base.Sort.UIntMappable(Decimal64{2}, Base.Order.Forward) === UInt64
    @test Base.Sort.UIntMappable(Decimal{76,2,Int256}, Base.Order.Forward) === nothing
end

@testset "sum widens the Int128 tier to Int256" begin
    T = Decimal{38,4,Int128}
    v = fill(typemax(T), 1000)
    s = sum(v)
    @test s isa Decimal{76,4,Int256}
    @test big(s) == 1000 * big(typemax(T))
    @test sum(T[]) === zero(Decimal{76,4,Int256})
    @test sum(fill(Decimal64{2}("1.25"), 4)) isa Decimal{38,2,Int128}
    @test_throws OverflowError sum(fill(typemax(Decimal{76,2,Int256}), 2))
end
