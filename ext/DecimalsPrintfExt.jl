# Printf integration. %d takes the same exact-or-InexactError route as a
# Rational. %f/%e/%g go through a 1024-bit BigFloat rather than Printf's default
# Float64(x), which would silently round away everything past 17 significant
# digits; 1024 bits covers the 78-digit value range and the format's width.
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
