# Write decimals as JSON numbers carrying their exact digits, through the JSON
# 1.x hook for it; the default for an unknown Real stringifies convert(Float64,
# x) and would round wide values away. The positional print form is always a
# valid JSON number, since a decimal is always finite.
module DecimalsJSONExt

using Decimals
using Decimals: AbstractDecimal
import JSON

JSON.tostring(x::AbstractDecimal) = string(x)

end # module
