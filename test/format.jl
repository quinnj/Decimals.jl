# Fast-formatter tests: differential against digit-by-digit construction.
using Decimals
using Decimals: writedecimal!, decimallength, unscaled, scale, _tobigsigned
using BitIntegers
using Test, Random

# reference formatter built from BigInt string manipulation
function refstring(x)
    u = _tobigsigned(unscaled(x))
    s = scale(x)
    neg = u < 0
    ds = string(abs(u))
    if s == 0
        body = ds
    elseif length(ds) <= s
        body = "0." * "0"^(s - length(ds)) * ds
    else
        body = ds[1:end-s] * "." * ds[end-s+1:end]
    end
    return (neg ? "-" : "") * body
end

@testset "format" begin
    rng = Xoshiro(4001)
    for x in (zero(Decimal64{2}), zero(Decimal{18,0,Int64}), Decimal{18,2}("5"),
              Decimal{18,2}("-0.05"), Decimal{18,0}(-7), Decimal{9,9,Int32}("0.000000001"),
              typemax(Decimal{76,40,Int256}), typemin(Decimal{76,40,Int256}),
              typemax(Decimal{38,9,Int128}), DecimalValue(0, 3), DecimalValue(-12345, 7))
        @test string(x) == refstring(x)
        @test length(string(x)) == decimallength(x)
    end
    for (P, S, T) in ((9, 2, Int32), (18, 4, Int64), (18, 18, Int64), (38, 9, Int128),
                      (38, 38, Int128), (76, 20, Int256), (76, 76, Int256))
        DT = Decimal{P, S, T}
        lim = _tobigsigned(Decimals._maxmag(DT))
        for _ in 1:500
            u = rand(rng, -lim:lim)
            x = reinterpret(DT, Decimals._fromfullbig(UInt256, abs(u)) % Decimals._utype(T) % T)
            u < 0 && (x = -x)
            @test string(x) == refstring(x)
            @test length(string(x)) == decimallength(x)
            @test parse(DT, string(x)) === x
        end
    end
    # writedecimal! at an offset, exact byte count
    x = Decimal{18,3}("-12.345")
    buf = fill(UInt8('#'), 20)
    stop = writedecimal!(buf, 3, x)
    @test String(buf[3:stop-1]) == "-12.345"
    @test buf[1] == UInt8('#') && buf[stop] == UInt8('#')
    # huge-scale DecimalValue
    v = DecimalValue{Int64}(5, 100)
    @test string(v) == "0." * "0"^99 * "5"
    @test decimallength(v) == 102
    # writedecimal! allocation-free
    wf(b, x) = writedecimal!(b, 1, x)
    wf(buf, x)
    @test_allocfree wf(buf, x)
end
