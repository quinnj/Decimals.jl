using Test, Decimals, LinearAlgebra
using Decimals: DecimalValue, Decimal64, Decimal256, Int256

module DecimalPublicNamespace
using Decimals
end

@testset "release regressions" begin
    @testset "parameter validation precedes conversion" begin
        for D in (Decimal{-1,0,Int32}, Decimal{9,-1,Int32}, Decimal{9,10,Int32},
                  Decimal{1_000_000,0,Int32}, Decimal{9,typemin(Int),Int32},
                  Decimal{:bad,0,Int32}, Decimal{9,0,Union{Int32,Int64}})
            for x in (1, big(1), 1//1, big(1)//big(1), 1.0, "1", Decimal64{2}(1))
                @test_throws ArgumentError D(x)
            end
            @test_throws ArgumentError round(D, 1//2)
            @test_throws ArgumentError typemax(D)
            @test_throws ArgumentError one(D)
        end
        @test_throws ArgumentError Decimal{:bad,0}(1)
        @test_throws ArgumentError Decimal{1_000_000,0}("1")
    end
    @testset "qualified public API" begin
        @test isdefined(DecimalPublicNamespace, :Decimal)
        @test DecimalPublicNamespace.Decimal64 === Decimal64
        for name in (:DecimalValue, :Decimal32, :Decimal128, :Decimal256, :divide, :rescale)
            @test !isdefined(DecimalPublicNamespace, name)
        end
        x = DecimalValue(125, 2)
        @test Core.eval(DecimalPublicNamespace, Meta.parse(repr(x))) === x
    end
    @testset "scalar and broadcast promotion agree" begin
        x = Decimal256{0}(1)
        y = Decimal256{76}("-0.9")
        @test_throws OverflowError x + y
        @test_throws OverflowError [x] .+ [y]
        @test_throws OverflowError [x] .- [-y]
        @test_throws OverflowError [y] .+ [x]
        @test [zero(x)] .+ [y] == [y]
    end
    @testset "total ordering of signed zero" begin
        for z in (Decimal64{2}(0), DecimalValue(0, 100)), F in (Float16, Float32, Float64, BigFloat)
            nz, pz = -zero(F), zero(F)
            @test !isequal(nz, z)
            @test isless(nz, z)
            @test !isless(z, nz)
            @test isequal(pz, z)
            @test !isless(pz, z)
            @test !isless(z, pz)
            @test hash(pz) == hash(z)
        end
    end
    @testset "sign for fractional-only types" begin
        for D in (Decimal{2,2,Int32}, Decimal256{76})
            for s in ("-0.25", "0.00", "0.25")
                x = D(s)
                @test sign(x) == sign(Decimals.unscaled(x))
            end
        end
    end
    @testset "nonfinite rational conversion" begin
        for n in (-1, 1), I in (Int64, BigInt)
            x = I(n)//I(0)
            @test_throws InexactError Decimal64{2}(x)
            @test_throws InexactError round(Decimal64{2}, x)
        end
        @test Int256(BigFloat(42)) == 42
        @test_throws InexactError Int256(BigFloat("1.5"))
    end
    @testset "runtime-scale rational promotion" begin
        x = DecimalValue(1, 100)
        @test x + 1//2 == big(x) + 1//2
        @test x * (1//2) == big(x) * (1//2)
        @test promote_type(typeof(x), Rational{Int}) === Rational{BigInt}
    end
    @testset "explicit factorization arguments" begin
        A = Decimal64{2}.([4 2; 2 3])
        @test cholesky(A, NoPivot()) isa Cholesky{Float64}
        @test cholesky(A, RowMaximum()) isa CholeskyPivoted{Float64}
        @test lu(A, NoPivot()) isa LU{Float64}
        @test qr(A, ColumnNorm()) isa QRPivoted{Float64}
        @test eigen(A, float(A)).values ≈ ones(2)
        @test isempty(Test.detect_ambiguities(Decimals, Base.get_extension(Decimals, :DecimalsLinearAlgebraExt), Base, LinearAlgebra; recursive=true))
    end
    @testset "structured inverse" begin
        A = Diagonal(Decimal64{2}.([3, 7]))
        @test inv(A) ≈ inv(float(A))
        @test eltype(inv(A)) === Float64
        b = Decimal64{2}.([1, 1])
        @test A \ b ≈ float(A) \ float(b)
        @test A \ reshape(b, 2, 1) ≈ float(A) \ reshape(float(b), 2, 1)
        for wrap in (UpperTriangular, LowerTriangular)
            B = wrap(Decimal64{2}.([3 2; 1 7]))
            @test inv(B) ≈ inv(float(B))
            @test eltype(inv(B)) === Float64
            @test B \ b ≈ float(B) \ float(b)
        end
    end
end
