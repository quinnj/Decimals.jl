# Float conversion differential: the libcall-free divide path must agree with
# the exact BigInt slow path everywhere, including constructed half-ulp ties.
using Decimals
using Decimals: Decimals as D
using BitIntegers
using Test, Random

@testset "float conversion differential" begin
    rng = Xoshiro(8003)
    for F in (Float64, Float32, Float16)
        for _ in 1:30000
            w = rand(rng, 1:4)
            T = (Int32, Int64, Int128, Int256)[w]
            cap = (9, 18, 38, 76)[w]
            s = rand(rng, 0:cap)
            u = T(rand(rng, big(1):big(10)^rand(rng, 1:cap) - 1) % big(2)^(8 * sizeof(T) - 1))
            rand(rng, Bool) && (u = -u)
            @test D._tofloat(F, u, s) === D._tofloat_slow(F, u, s)
        end
        p = precision(F)
        for _ in 1:5000
            k = rand(rng, 0:big(2)^(p - 1) - 1)
            s = rand(rng, 0:40)
            ub = (big(2)^p + 2k + 1) * big(10)^s
            ub > big(10)^76 && continue
            u = D._fromfullbig(UInt256, ub) % Int256
            @test D._tofloat(F, u, s) === D._tofloat_slow(F, u, s)
        end
        # deep scales reach the exact fallback (subnormal territory)
        for _ in 1:2000
            s = rand(rng, 100:400)
            u = rand(rng, Int64(1):typemax(Int64))
            @test D._tofloat(F, u, s) === D._tofloat_slow(F, u, s)
        end
    end
    # single-conversion allocation-free on the divide path
    x = reinterpret(Decimal{38,9,Int128}, Int128(10)^30 + 7)
    g(a) = Float64(a)
    g(x)
    @test @allocated(g(x)) == 0
    # batched 5-stripping is an exact valuation extractor
    for _ in 1:50000
        w = rand(rng, 1:4)
        T = (Int32, Int64, Int128, Int256)[w]
        cap = (9, 18, 38, 76)[w]
        s = rand(rng, 0:cap)
        u = T(rand(rng, big(0):big(10)^rand(rng, 1:cap) - 1) % big(2)^(8 * sizeof(T) - 1))
        rand(rng, Bool) && (u = -u)
        us, ss = D._strip5s(u, s)
        @test D._tobigsigned(us) * big(5)^(s - ss) == D._tobigsigned(u)
        @test ss == 0 || D._tobigsigned(us) % 5 != 0
    end
end
