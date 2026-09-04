# Matrix factorizations on decimal matrices route through Float64: the generic
# lu!/qr! kernels divide in place, and fixed-point division would either round
# silently at the data's scale or throw InexactError partway through. Exact
# factorization needs `map(Rational{BigInt}, A)`; matmul, dot, +, tr and cumsum
# stay exact decimal.
module DecimalsLinearAlgebraExt

using Decimals
using Decimals: AbstractDecimal
using LinearAlgebra

const _DecMatrix = StridedMatrix{<:AbstractDecimal}

for f in (:lu, :cholesky, :qr, :svd, :eigen, :hessenberg, :schur, :lq)
    @eval LinearAlgebra.$f(A::_DecMatrix; kwargs...) =
        LinearAlgebra.$f(float(A); kwargs...)
end

for f in (:det, :logdet, :inv, :eigvals, :svdvals, :cond, :nullspace, :pinv, :rank)
    @eval LinearAlgebra.$f(A::_DecMatrix; kwargs...) =
        LinearAlgebra.$f(float(A); kwargs...)
end

# Match the positional argument types instead of intercepting every arity.
# Broad varargs collide with Base's pivot and generalized-eigen methods.
for pivot in (NoPivot, RowMaximum, RowNonZero)
    @eval LinearAlgebra.lu(A::_DecMatrix, p::$pivot; kwargs...) = lu(float(A), p; kwargs...)
end
for pivot in (NoPivot, RowMaximum)
    @eval LinearAlgebra.cholesky(A::_DecMatrix, p::$pivot; kwargs...) = cholesky(float(A), p; kwargs...)
end
for pivot in (NoPivot, ColumnNorm)
    @eval LinearAlgebra.qr(A::_DecMatrix, p::$pivot; kwargs...) = qr(float(A), p; kwargs...)
end
LinearAlgebra.cond(A::_DecMatrix, p::Real) = cond(float(A), p)

# Structured inverses otherwise divide at the fixed decimal scale.
for M in (Diagonal, UpperTriangular, LowerTriangular, UnitUpperTriangular, UnitLowerTriangular)
    @eval LinearAlgebra.inv(A::$M{<:AbstractDecimal}) = inv(float(A))
    @eval Base.:\(A::$M{<:AbstractDecimal}, b::AbstractVector) = float(A) \ float(b)
    @eval Base.:\(A::$M{<:AbstractDecimal}, B::StridedMatrix) = float(A) \ float(B)
end

end # module
