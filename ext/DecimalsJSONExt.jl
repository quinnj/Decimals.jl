# JSON writes decimals as raw JSON numbers with their exact digits via the
# documented JSON 1.x hook (the default for unknown Reals stringifies
# convert(Float64, x), silently rounding wide values). The plain positional
# print form is always a valid JSON number, and decimals are always finite.
module DecimalsJSONExt

using Decimals
using Decimals: AbstractDecimal
import JSON

JSON.tostring(x::AbstractDecimal) = string(x)

end # module
