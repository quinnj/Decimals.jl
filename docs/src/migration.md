# Migration from 0.x

Version 1.0 is a rewrite. It shares the package name with the 0.x `Decimals`
and very little else.

## What changed, and why

The 0.x `Decimal` was a heap-backed arbitrary-precision floating decimal:
`Decimal <: AbstractFloat`, holding a sign, a `BigInt` coefficient, and an
exponent, with Python-style context semantics. Every operation rounded to a
dynamically scoped precision, 28 significant digits by default, within
exponent limits of ±999999.

That design has two problems for the applications that reach for a decimal
type. The first is the silent rounding: a 31-digit sum quietly loses three
digits and nothing says so, which is the opposite of the guarantee a ledger
or a wire format needs. The second is the representation: a heap-allocated
`BigInt` coefficient cannot be a column type, so decimal data arriving from
Arrow, Parquet, DuckDB, or a SQL driver had to be converted element by
element on the way in and on the way out.

Version 1.0 addresses both. [`Decimal{P,S,T}`](@ref Decimal) is isbits with
the precision and scale in the type, matching the
`(precision, scale, width)` triple those systems already use, so a `Vector`
of them is a column buffer; and arithmetic is exact and checked, with
rounding available only as an explicit argument.
[`DecimalValue{T}`](@ref DecimalValue) covers the row-oriented case where the
scale travels per value.

The full API comparison, including three bugs found in 0.5.1 while writing
it, is in `docs/comparison-with-0.5.1.md` in the repository.

## What keeps working unchanged

- The name `Decimal`.
- `==`, `<`, `<=`, `cmp`, and `hash` by numeric value: `dec"1.20" == dec"1.2"`
  still holds, and hashes still agree with equal `Int`s, `Rational`s, and
  `Float64`s.
- `parse` / `string` round-trips for ordinary values, with `parse` now
  provided by the Parsers extension.
- `round(x; digits)`.
- `zero`, `one`, `abs`, unary `-`, `signbit`, `iszero`, `isfinite`, `isnan`.
- `dec"..."` literals, including `_` digit separators.
- `Decimals.normalize` for stripping trailing zeros.
- Scientific-notation display for extreme exponents (past 44 characters of
  positional form).

## What needs a change

| 0.x | 1.0 |
|---|---|
| `Decimal(1.25)`, one untyped decimal | choose a type: `Decimal64{2}("1.25")` for a fixed-scale column, [`DecimalValue`](@ref) when the scale is per value, `dec"1.25"` for a literal |
| silent rounding to context precision on `+`/`-`/`*` | exact and checked; opt into rounding with [`rescale(D, x, mode)`](@ref rescale) or [`divide(x, y, mode)`](@ref divide) |
| `Context`, `with_context`, `@with_context`, `CONTEXT`, `rounding(Decimal)` | removed; rounding is an argument at each call site |
| `DivisionByZeroError`, `UndefinedDivisionError` | Base's `DivideError` |
| `Decimal <: AbstractFloat` | `Decimal <: Real`; the `AbstractFloat` claim is what produced 0.x's `floatmin`/`floatmax`/`Inf` bug reports |
| `precision(x)` = the context's digit budget | `precision(x)` = the type's `P`; `Decimals.scale(x)` for the scale |
| `round(x; sigdigits)` | not applicable; a fixed-point type has no floating significand, so use `digits` |
| `number` (exported but undefined in 0.5.1) | gone; use `Float64(x)`, `Rational(x)`, or `Int(x)` |
| blanket `T(x) = T(BigFloat(x))` conversions | exact-or-throw per family, with correctly rounded float conversions; 0.5.1's blanket route returned `10^80` for `BigInt(Decimal(10^80 + 1))` |

### Porting a context block

Where 0.x code set a context to control rounding:

```julia
# 0.x
with_context(Context(precision=10, rounding=RoundUp)) do
    a / b
end
```

the 1.0 form names the target scale and the mode at the call site:

```julia
# 1.0
rescale(Decimal64{10}, divide(a, b, RoundUp))
```

It is more to write, and in exchange the result no longer depends on which
caller it runs inside.

### Porting arithmetic that relied on silent rounding

If 0.x code accumulated values and let the context trim them, the 1.0
equivalent is to say where the trimming happens:

```julia
# 0.x: the context rounded this back to 28 digits
total = a * b + c

# 1.0: exact by default, so either keep the exact wide result…
total = a * b + c                        # scale S_a+S_b, checked

# …or say what scale you want
total = rescale(Decimal64{2}, a * b + c) # half-even into 2 decimal places
```

## What is lost

Values beyond 76 significant digits or scale 16383, and dynamically scoped
precision. If you need unbounded exactness, `Rational{BigInt}(x)`, which is
what `big(x)` returns for a decimal, is the escape hatch, and it is the same
one Base offers for `Rational` arithmetic that outgrows its integer type.

## What is new

Worth knowing about coming from 0.x:

- The `Decimal32` / `Decimal64` / `Decimal128` / `Decimal256` tiers, with
  precision and scale carried in the type.
- [`DecimalValue`](@ref) for runtime scales.
- The zero-copy wire API: `Decimals.unscaled`, `Decimals.scale`,
  `reinterpret` construction, [`writedecimal!`](@ref Decimals.writedecimal!),
  and [`decimallength`](@ref Decimals.decimallength), memcpy-compatible with
  Arrow/Parquet/DuckDB buffers.
- The explicit rounding API: [`rescale`](@ref), [`divide`](@ref), and
  `round(D, x, mode)`, in seven modes and with no global state.
- Real `div` / `rem` / `mod` / `fld` / `cld` / `divrem` implementations in
  every rounding mode; 0.x had only `AbstractFloat` fallbacks.
- Exact `Rational` conversions in both directions, correctly rounded
  `Float64` / `Float32` / `Float16`, and exact `BigFloat` at any requested
  precision and mode.
- The Parsers, Printf, JSON, and LinearAlgebra extensions.
- SIMD broadcast kernels for `+`, `-`, `*` and a vectorized `sum`.
- `typemin` / `typemax` / `eps` / `floatmin` / `floatmax` / `widen`.

## A note for downstream packages

LibPQ.jl pins `Decimals = 0.4.1`, a pre-0.5 API that already stopped working
with 0.5.x, so 1.0 is no worse for it, and [`DecimalValue`](@ref) is the
natural target for a PostgreSQL `numeric`, whose scale travels per value.
