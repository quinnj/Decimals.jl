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
    @eval LinearAlgebra.$f(A::_DecMatrix, args...; kwargs...) =
        LinearAlgebra.$f(float(A), args...; kwargs...)
end

for f in (:det, :logdet, :inv, :eigvals, :svdvals, :cond, :nullspace, :pinv, :rank)
    @eval LinearAlgebra.$f(A::_DecMatrix, args...; kwargs...) =
        LinearAlgebra.$f(float(A), args...; kwargs...)
end

end # module
