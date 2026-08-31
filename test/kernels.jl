# Kernel-layer differential tests against a BigInt oracle.
using Decimals: Decimals as D
using BitIntegers
using Test, Random

const UWIDTHS = (UInt32, UInt64, UInt128, UInt256)
const ALLMODES = (RoundNearest, RoundNearestTiesAway, RoundNearestTiesUp,
                  RoundToZero, RoundFromZero, RoundDown, RoundUp)

_randu(rng, ::Type{U}) where {U} = D._fromfullbig(U, rand(rng, big(0):D._tobig(typemax(U))))

@testset "tables" begin
    for U in UWIDTHS
        tm = D._tobig(typemax(U))
        @test big(10)^D._tablemax(U) <= tm
        @test big(10)^(D._tablemax(U) + 1) > tm
        @test D._maxdigits(U) == length(string(tm))
        for k in 0:D._tablemax(U)
            @test D._tobig(D._upow10(U, k)) == big(10)^k
        end
        for k in 1:D._tablemax(U)
            @test D._tobig(D._maxdiv(U, k)) == div(tm, big(10)^k)
        end
        @test 5 * big(10)^D._halfmax(U) <= tm
        @test 5 * big(10)^(D._halfmax(U) + 1) > tm
    end
end

@testset "ndigits10" begin
    rng = Xoshiro(1001)
    for U in UWIDTHS
        tm = D._tobig(typemax(U))
        @test D._ndigits10(zero(U)) == 1
        @test D._ndigits10(typemax(U)) == length(string(tm))
        for k in 0:D._tablemax(U), off in (-1, 0, 1)
            xb = big(10)^k + off
            (0 < xb <= tm) || continue
            @test D._ndigits10(D._fromfullbig(U, xb)) == length(string(xb))
        end
        for _ in 1:5000
            xb = rand(rng, big(1):tm)
            @test D._ndigits10(D._fromfullbig(U, xb)) == length(string(xb))
        end
    end
end

@testset "divpow10 magic" begin
    rng = Xoshiro(1002)
    for U in UWIDTHS
        tm = D._tobig(typemax(U))
        for k in 1:D._tablemax(U)
            d = big(10)^k
            top = div(tm, d) * d
            for xb in (big(0), big(1), d - 1, d, d + 1, top - 1, top, tm - 1, tm)
                (0 <= xb <= tm) || continue
                x = D._fromfullbig(U, xb)
                @test D._tobig(D._divpow10(x, k)) == div(xb, d)
            end
        end
        for _ in 1:20000
            k = rand(rng, 1:D._tablemax(U))
            xb = rand(rng, big(0):tm)
            @test D._tobig(D._divpow10(D._fromfullbig(U, xb), k)) == div(xb, big(10)^k)
        end
    end
end

@testset "scaledown rounding" begin
    rng = Xoshiro(1003)
    for U in UWIDTHS
        tm = D._tobig(typemax(U))
        for _ in 1:20000
            k = rand(rng, 0:(D._tablemax(U) + 4))
            xb = rand(rng, big(0):tm)
            x = D._fromfullbig(U, xb)
            mode = rand(rng, ALLMODES)
            for neg in (false, true)
                q, inexact = D._scaledown(x, k, neg, mode)
                sxb = neg ? -xb : xb
                wantq = div(sxb, big(10)^k, mode)
                got = neg ? -D._tobig(q) : D._tobig(q)
                @test got == wantq
                @test inexact == (sxb != wantq * big(10)^k)
            end
        end
        # directed boundary sweep: all modes on all values near ties
        for k in 1:min(4, D._tablemax(U)), base in 0:3, off in -2:2, mode in ALLMODES
            xb = base * big(10)^k + 5 * big(10)^(k - 1) + off
            (0 <= xb <= tm) || continue
            x = D._fromfullbig(U, xb)
            for neg in (false, true)
                q, inexact = D._scaledown(x, k, neg, mode)
                sxb = neg ? -xb : xb
                @test (neg ? -D._tobig(q) : D._tobig(q)) == div(sxb, big(10)^k, mode)
            end
        end
    end
end

@testset "scaledown signed" begin
    rng = Xoshiro(1004)
    for (U, T) in ((UInt32, Int32), (UInt64, Int64), (UInt128, Int128), (UInt256, Int256))
        lim = D._tobig(typemax(U)) >> 1
        for _ in 1:5000
            k = rand(rng, 0:D._tablemax(U))
            xb = rand(rng, (-lim):lim)
            sx = xb < 0 ? -reinterpret(T, D._fromfullbig(U, -xb)) : reinterpret(T, D._fromfullbig(U, xb))
            mode = rand(rng, ALLMODES)
            q, inexact = D._scaledown(sx, k, mode)
            qb = (q < zero(T) ? -1 : 1) * D._tobig(D._mag(q))
            @test qb == div(xb, big(10)^k, mode)
        end
    end
end

@testset "scaleup" begin
    rng = Xoshiro(1005)
    for U in UWIDTHS
        tm = D._tobig(typemax(U))
        for _ in 1:20000
            k = rand(rng, 0:(D._tablemax(U) + 2))
            xb = rand(rng, big(0):tm)
            r, ovf = D._scaleup(D._fromfullbig(U, xb), k)
            want = xb * big(10)^k
            if want <= tm
                @test !ovf
                @test D._tobig(r) == want
            else
                @test ovf
            end
        end
    end
    # signed scaleup incl. the signed-range overflow gap
    for (U, T) in ((UInt64, Int64), (UInt128, Int128))
        for (xb, k, wantovf) in ((big(typemax(T)), 1, true),
                                 (div(big(typemax(T)), 10), 1, false),
                                 (div(big(typemax(T)), 10) + 1, 1, true),
                                 (-(div(big(typemax(T)), 10)), 1, false))
            sx = T(xb)
            r, ovf = D._scaleup(sx, k)
            @test ovf == wantovf
            wantovf || @test big(r) == xb * big(10)^k
        end
    end
end

@testset "wide mul" begin
    rng = Xoshiro(1006)
    for _ in 1:10000
        a = rand(rng, UInt128)
        b = rand(rng, UInt128)
        hi, lo = D._mul128full(a, b)
        @test (big(hi) << 128) | big(lo) == big(a) * big(b)
    end
    for _ in 1:10000
        a = _randu(rng, UInt256)
        b = _randu(rng, UInt256)
        hi, lo = D._mul256full(a, b)
        @test (D._tobig(hi) << 256) | D._tobig(lo) == D._tobig(a) * D._tobig(b)
    end
    @test D._widemul256(typemax(UInt128), typemax(UInt128)) ==
          D._fromfullbig(UInt256, big(typemax(UInt128))^2)
end

@testset "divrem_wide" begin
    rng = Xoshiro(1007)
    tm = D._tobig(typemax(UInt256))
    @test_throws DivideError D._divrem_wide(UInt256(1), UInt256(0))
    for _ in 1:20000
        ub = rand(rng, big(0):tm)
        db = rand(rng, big(1):big(2)^rand(rng, 1:255))
        q, r = D._divrem_wide(D._fromfullbig(UInt256, ub), D._fromfullbig(UInt256, db))
        qb, rb = divrem(ub, db)
        @test D._tobig(q) == qb
        @test D._tobig(r) == rb
    end
    # adversarial: divisors just below/above limb boundaries, dividends forcing
    # the qhat = β-1 estimate and add-back paths
    for db in (big(2)^64 - 1, big(2)^64, big(2)^64 + 1, big(2)^128 - 1, big(2)^128,
               big(2)^128 + 1, big(2)^192 - 1, big(2)^192, big(2)^192 + 1,
               (big(2)^64 - 1) * big(10)^15, big(2)^255)
        for ub in (db - 1, db, db + 1, db * db <= tm ? db * db : tm, tm, tm - 1,
                   div(tm, db) * db, div(tm, db) * db - 1)
            (0 <= ub <= tm && db <= tm) || continue
            q, r = D._divrem_wide(D._fromfullbig(UInt256, ub), D._fromfullbig(UInt256, db))
            qb, rb = divrem(ub, db)
            @test D._tobig(q) == qb
            @test D._tobig(r) == rb
        end
    end
end

@testset "allocation-free kernels" begin
    x256 = D._fromfullbig(UInt256, big(10)^70 + 12345)
    wide(u, d) = D._divrem_wide(u, d)
    sd(x, k, m) = D._scaledown(x, k, false, m)
    wide(x256, UInt256(999983))
    wide(x256, (UInt256(1) << 130) | UInt256(7))
    sd(x256, 33, RoundNearest)
    @test @allocated(wide(x256, UInt256(999983))) == 0
    @test @allocated(wide(x256, (UInt256(1) << 130) | UInt256(7))) == 0
    @test @allocated(sd(x256, 33, RoundNearest)) == 0
end
