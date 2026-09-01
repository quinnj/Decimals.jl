# Matrix factorizations on decimal matrices route through Float64.
#
# Why: generic lu!/qr! and friends divide in place, and fixed-point division
# rounds at the data's scale — a Decimal{18,2} matrix would give det [1 2; 3 4]
# = -2.0004 (silent precision loss) or throw InexactError mid-factorization at
# other scales. Neither is acceptable, and exact factorization is not possible
# in a fixed-scale type (that is what Rational is for: convert with
# `map(Rational{BigInt}, A)` when exactness is required). Additive/multiplicative
# structure (matmul, dot, +, tr, cumsum) stays exact decimal.
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
