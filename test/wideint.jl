# The package's own 256-bit integers, checked against BigInt.
using Random
using Decimals: Int256, UInt256

@testset "256-bit storage integers" begin
    rng = Xoshiro(256)
    B(x::UInt256) = BigInt(x)
    B(x::Int256) = BigInt(x)
    @test B(typemax(UInt256)) == big(2)^256 - 1
    @test B(typemax(Int256)) == big(2)^255 - 1 && B(typemin(Int256)) == -big(2)^255
    @test typemax(Int256) + one(Int256) == typemin(Int256)   # wraps like Base ints
    for _ in 1:2000
        x = rand(rng, UInt256); y = rand(rng, UInt256); k = rand(rng, 0:300)
        bx, by = B(x), B(y)
        @test B(x + y) == (bx + by) % big(2)^256
        @test B(x * y) == (bx * by) % big(2)^256
        @test B(x - y) == mod(bx - by, big(2)^256)
        @test B(x & y) == bx & by && B(x | y) == bx | by && B(xor(x, y)) == xor(bx, by)
        @test B(x >> k) == bx >> k
        @test B(x << k) == (bx << k) % big(2)^256
        @test (x < y) == (bx < by) && (x == y) == (bx == by)
        @test leading_zeros(x) == 256 - ndigits(bx, base=2)
        @test trailing_zeros(x | one(UInt256)) == trailing_zeros(bx | 1)
        @test count_ones(x) == count_ones(bx)
        y == zero(UInt256) && continue
        q, r = divrem(x, y)
        @test B(q) == div(bx, by) && B(r) == rem(bx, by)
        @test UInt256(bx) === x && (bx % UInt256) === x
    end
    for _ in 1:2000
        x = rand(rng, Int256); y = rand(rng, Int256); k = rand(rng, 0:300)
        bx, by = B(x), B(y)
        @test B(x >> k) == bx >> k
        @test B(-x) == (x == typemin(Int256) ? bx : -bx)
        @test (x < y) == (bx < by) && abs(x) == (x == typemin(Int256) ? x : Int256(abs(bx)))
        @test Int256(bx) === x && (bx % Int256) === x
        y == zero(Int256) && continue
        (x == typemin(Int256) && y == -one(Int256)) && continue
        q, r = divrem(x, y)
        @test B(q) == div(bx, by) && B(r) == rem(bx, by)
        @test x == q * y + r
    end
    # conversions with machine integers
    @test Int256(typemin(Int64)) == big(typemin(Int64)) && UInt256(typemax(UInt128)) == big(typemax(UInt128))
    @test_throws InexactError UInt256(-1)
    @test_throws InexactError Int64(Int256(2)^70)
    @test_throws InexactError UInt8(UInt256(256))
    # signed wide -> unsigned machine: the full unsigned range, not the signed one
    @test UInt8(Int256(157)) === 0x9d && UInt8(Int256(255)) === 0xff
    @test UInt64(Int256(typemax(UInt64))) === typemax(UInt64) && UInt128(Int256(2)^127) === UInt128(2)^127
    @test_throws InexactError UInt8(Int256(256))
    @test_throws InexactError UInt8(Int256(-1))
    @test_throws InexactError UInt128(Int256(2)^128)
    @test Int8(Int256(-128)) === Int8(-128) && Int8(UInt256(127)) === Int8(127)
    @test_throws InexactError Int8(Int256(128))
    @test_throws InexactError Int8(UInt256(128))
    @test (UInt256(2)^70 + UInt256(5)) % UInt64 === UInt64(5)
    @test (-Int256(1)) % UInt64 === typemax(UInt64) && (Int256(-1)) % UInt256 === typemax(UInt256)
    @test Int8(-3) % UInt256 === typemax(UInt256) - UInt256(2)
    @test UInt256(true) === one(UInt256) && Int256(false) === zero(Int256)
    @test Int(Int256(42)) === 42 && Bool(UInt256(1)) === true
    # promotion, floats, strings, hashing
    @test UInt256(7) + 3 === UInt256(10) && Int256(7) * 3 === Int256(21)
    @test Int256(2)^200 == big(2)^200 && string(Int256(2)^100) == string(big(2)^100)
    @test string(-Int256(12345)) == "-12345" && string(typemax(UInt256)) == string(big(2)^256 - 1)
    @test Float64(Int256(2)^100) == 2.0^100 && Int256(2.0^100) === Int256(2)^100
    @test hash(UInt256(12345)) == hash(12345) && hash(Int256(-7)) == hash(-7)
    @test isodd(Int256(3)) && iseven(UInt256(2)^200)
    @test flipsign(Int256(5), -1) === Int256(-5)
    @test Base.Checked.checked_abs(Int256(-9)) === Int256(9) && gcd(UInt256(12), UInt256(18)) === UInt256(6)
    @test_throws OverflowError Base.Checked.checked_abs(typemin(Int256))
    @test Base.mul_with_overflow(Int256(2)^200, Int256(2)^60) == (Int256(0), true)
    @test Base.mul_with_overflow(Int256(3), Int256(4)) == (Int256(12), false)
    @test Base.add_with_overflow(typemax(Int256), one(Int256)) == (typemin(Int256), true)
    # random samplers
    v = rand(rng, zero(Int256):Int256(1000), 5000)
    @test all(0 .<= v .<= 1000) && length(unique(v)) > 900
    @test rand(rng, UInt256) isa UInt256 && rand(rng, Int256) isa Int256
    w = rand(rng, Int256(-5):Int256(5), 2000)
    @test minimum(w) == -5 && maximum(w) == 5
    @test rand(rng, UInt256(3):UInt256(3)) === UInt256(3)
end
