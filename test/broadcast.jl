# Broadcast kernel tests: SIMD paths must agree exactly with scalar ops.
using Decimals
using BitIntegers
using Test, Random

@testset "broadcast kernels" begin
    rng = Xoshiro(6001)
    n = 10_000
    a = [reinterpret(Decimal64{2}, rand(rng, -10^15:10^15)) for _ in 1:n]
    b = [reinterpret(Decimal64{2}, rand(rng, -10^15:10^15)) for _ in 1:n]
    c = a .+ b
    d = a .- b
    m = a .* b
    @test typeof(m) === Vector{Decimal{36,4,Int128}}
    for i in 1:n
        @test c[i] === a[i] + b[i]
        @test d[i] === a[i] - b[i]
        @test m[i] === a[i] * b[i]
    end
    # Int32 tier product stays in Int64
    a32 = [reinterpret(Decimal32{2}, rand(rng, Int32(-10^6):Int32(10^6))) for _ in 1:n]
    b32 = [reinterpret(Decimal32{2}, rand(rng, Int32(-10^6):Int32(10^6))) for _ in 1:n]
    m32 = a32 .* b32
    @test typeof(m32) === Vector{Decimal{18,4,Int64}}
    for i in 1:n
        @test m32[i] === a32[i] * b32[i]
    end
    # Int256 tier add kernel
    aw = [reinterpret(Decimal256{2}, Int256(rand(rng, -10^18:10^18)) * Int256(10)^20) for _ in 1:100]
    cw = aw .+ aw
    for i in 1:100
        @test cw[i] === aw[i] + aw[i]
    end
    # overflow anywhere in the array throws, matching the scalar contract
    abad = copy(a)
    bbad = copy(b)
    abad[7] = typemax(Decimal64{2})
    bbad[7] = eps(Decimal64{2})
    @test_throws OverflowError abad .+ bbad
    @test_throws OverflowError (.-(abad)) .- bbad
    # near-max magnitudes that wrap without overflowing the storage type
    ahigh = [typemax(Decimal64{2}) for _ in 1:8]
    @test_throws OverflowError ahigh .+ ahigh
    # generic fallbacks: length-1 expansion, views, fused expressions,
    # mixed scales — all must still work through the scalar machinery
    @test (a[1:3] .+ [b[1]])[2] === a[2] + b[1]
    @test (view(a, 1:5) .+ view(b, 1:5))[3] === a[3] + b[3]
    f = a[1:100] .+ b[1:100] .- a[1:100]
    @test all(i -> f[i] == b[i], 1:100)
    bmix = [reinterpret(Decimal{18,3,Int64}, rand(rng, -10^12:10^12)) for _ in 1:100]
    g = a[1:100] .+ bmix
    for i in 1:100
        @test g[i] === a[i] + bmix[i]
    end
    # empty and single-element
    @test (Decimal64{2}[] .+ Decimal64{2}[]) == Decimal64{2}[]
    @test ([a[1]] .* [b[1]])[1] === a[1] * b[1]
end

@testset "mixed-scale and wide broadcast kernels" begin
    rng = Xoshiro(6002)
    n = 5_000
    a = [reinterpret(Decimal64{2}, rand(rng, -10^14:10^14)) for _ in 1:n]
    bmix = [reinterpret(Decimal{18,4,Int64}, rand(rng, -10^14:10^14)) for _ in 1:n]
    c = a .+ bmix
    d = a .- bmix
    for i in 1:n
        @test c[i] === a[i] + bmix[i]
        @test d[i] === a[i] - bmix[i]
    end
    # genuine overflow of the promoted type throws like the scalar path
    amax = fill(typemax(Decimal64{2}), 8)
    bmax = fill(typemax(Decimal{18,3,Int64}), 8)
    @test_throws OverflowError amax .+ bmax
    # Int128-tier product kernel (exact, unchecked by construction)
    a128 = [reinterpret(Decimal{38,9,Int128}, Int128(rand(rng, -10^18:10^18))) for _ in 1:n]
    b128 = [reinterpret(Decimal{38,4,Int128}, Int128(rand(rng, -10^18:10^18))) for _ in 1:n]
    m = a128 .* b128
    @test typeof(m) === Vector{Decimal{76,13,Int256}}
    for i in 1:n
        @test m[i] === a128[i] * b128[i]
    end
    mmax = fill(typemax(Decimal{38,0,Int128}), 8) .* fill(typemax(Decimal{38,0,Int128}), 8)
    @test mmax[1] === typemax(Decimal{38,0,Int128}) * typemax(Decimal{38,0,Int128})
end
