# @printf "%d" support for integer-valued decimals, matching Rational's
# behavior (exact-or-InexactError). Printf routes non-Integer Reals through
# its internal toint, which has Rational/AbstractFloat methods only.
module DecimalsPrintfExt

using Decimals
using Decimals: AbstractDecimal
import Printf

@static if isdefined(Printf, :toint)
    Printf.toint(x::AbstractDecimal) = Integer(x)
end

end # module
