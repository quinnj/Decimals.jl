# JSON writes decimals as raw JSON numbers with their exact digits (the
# default routes unknown Reals through Float64, silently rounding wide
# values). The plain positional print form is always a valid JSON number,
# and decimals are always finite.
#
# JSON 1.x hooks via the documented `JSON.tostring`; JSON 0.2x hooks via a
# `show_json` method on the writer (its own number path is Base.print).
module DecimalsJSONExt

using Decimals
using Decimals: AbstractDecimal
import JSON

@static if isdefined(JSON, :tostring)
    JSON.tostring(x::AbstractDecimal) = string(x)
else
    JSON.Writer.show_json(io::JSON.Writer.StructuralContext,
                          ::JSON.Serializations.CommonSerialization,
                          x::AbstractDecimal) = Base.print(io, x)
end

end # module
