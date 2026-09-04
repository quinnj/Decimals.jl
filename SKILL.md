---
name: decimals-integration
description: Integrate Decimals.jl values into schemas, wire codecs, numeric columns, or exact text output.
---

# Integrating Decimals

1. Determine whether scale belongs to the schema or to each value. Use
   `Decimals.Decimal{P,S,T}` for a column and `Decimals.DecimalValue{T}` for
   a runtime scale. Check the limits in `docs/src/manual.md#integration-boundaries`.
2. Use `convert(D, x)` for exact conversion from an integer, rational, or
   decimal. Use `Decimals.rescale(D, x, mode)` to request rounding. Float and
   string constructors round half-even; `dec"..."` literals are exact.
3. For raw coefficients, validate precision, scale, signed range, null state,
   and byte order before calling `reinterpret(D, coefficient)`. It is unchecked.
4. Use `Decimals.unscaled`, `Decimals.scale`, and `precision` for schema and
   codec work. Use `string` or `Decimals.writedecimal!` for exact positional text.
   Reserve `Decimals.decimallength(x)` bytes before calling the byte writer.
5. Load Parsers 3 for `parse`, `tryparse`, and `Parsers.parsenext`. Parsers 2
   environments support constructors and JSON output but do not provide the
   decimal parsing extension. Check the whole dependency graph before upgrading.
6. Verify minimum/maximum coefficients, both signs, fractional-only scales,
   nulls, invalid input, and encode/decode round trips. Check the decoded type
   and coefficient as well as numeric equality.

```julia
using Decimals
D = Decimal{18,2,Int64}
x = D("1234.56")
@assert Decimals.unscaled(x) == 123456
@assert Decimals.scale(x) == 2
@assert Decimals.rescale(D, dec"1.235", RoundNearest) == D("1.24")
```

`big(x)` gives `Rational{BigInt}` for exact algebra outside bounded decimal
storage. Use `float.(values)` when an algorithm requires floating-point math.
