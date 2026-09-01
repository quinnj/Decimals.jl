# Printf integration:
# - %d gets Rational-equivalent behavior (exact-or-InexactError) via toint.
# - %f/%e/%g route through a high-precision BigFloat instead of the default
#   Float64(x), so wide decimals print their true digits (the default tofloat
#   silently rounds anything beyond 17 significant digits). 1024 bits covers
#   the 78-digit value range plus any sane fractional format width.
module DecimalsPrintfExt

using Decimals
using Decimals: AbstractDecimal
import Printf

@static if isdefined(Printf, :toint)
    Printf.toint(x::AbstractDecimal) = Integer(x)
end

@static if isdefined(Printf, :tofloat)
    Printf.tofloat(x::AbstractDecimal) = BigFloat(x; precision=1024)
end

end # module
