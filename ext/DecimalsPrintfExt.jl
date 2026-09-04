# Decimal rounding precedes binary conversion: a BigFloat approximation alone
# can land on the wrong side of an exact decimal tie (2.675 at two places).
module DecimalsPrintfExt

using Decimals
using Decimals: AbstractDecimal
using Decimals: _mag, _ndigits10, _scaledown, scale
import Printf

@static if isdefined(Printf, :toint)
    Printf.toint(x::AbstractDecimal) = Integer(x)
end

@static if isdefined(Printf, :tofloat)
    Printf.tofloat(x::AbstractDecimal) = BigFloat(x; precision=1024)
end

const DecimalFormats = Union{Val{'f'}, Val{'F'}, Val{'e'}, Val{'E'}, Val{'g'}, Val{'G'}}

function Printf.fmt(buf, pos, x::AbstractDecimal, spec::Printf.Spec{T}) where {T <: DecimalFormats}
    s = scale(x)
    nd = _ndigits10(_mag(x))
    places = if T <: Union{Val{'f'}, Val{'F'}}
        spec.precision
    elseif T <: Union{Val{'e'}, Val{'E'}}
        spec.precision + 1 - nd + s
    else
        max(1, spec.precision) - nd + s
    end
    # Enough binary precision to render every requested decimal place without
    # exposing conversion noise, including requests beyond the stored scale.
    bits = max(256, 4 * (nd + max(0, places - s)) + 32)
    value = if places < s
        q, _ = _scaledown(_mag(x), s - places, signbit(x), RoundNearest)
        n = BigInt(q)
        r = places >= 0 ? n // big(10)^places : (n * big(10)^(-places)) // big(1)
        b = BigFloat(r, RoundNearest; precision=bits)
        signbit(x) ? -b : b
    else
        BigFloat(x, Base.MPFR.MPFRRoundNearest; precision=bits)
    end
    return Printf.fmt(buf, pos, value, spec)
end

end # module
