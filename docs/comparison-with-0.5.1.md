# Comparison with Decimals 0.5.1

A design note comparing the registered `Decimals` 0.5.1 (JuliaMath/Decimals.jl,
942 source lines) with this package, written for the discussion in
JuliaMath/Decimals.jl#107. Method lists were enumerated programmatically from
exports, public names, and every method defined on a `Base` function;
semantics were probed at the REPL.

## The two designs

- **0.5.1** is one heap-backed arbitrary-precision floating decimal:
  `Decimal <: AbstractFloat`, holding a sign, a `BigInt` coefficient, and an
  exponent, with Python-style context semantics. Every operation rounds to a
  dynamically scoped precision (28 significant digits by default) within
  exponent limits of ±999999.
- **This package** is a family of width-tiered isbits fixed-point decimals,
  `Decimal{P,S,T} <: Real` with `T` one of `Int32`, `Int64`, `Int128`, or
  `Int256`, plus a runtime-scale `DecimalValue{T}`. Arithmetic is exact and
  checked; rounding happens only at explicit `rescale`, `round`, `divide`,
  and `parse` boundaries. The layout is chosen for zero-copy wire interop.

## Shared surface, diverging semantics

| surface | 0.5.1 | this package |
|---|---|---|
| `Decimal` type | one non-parametric type, heap `BigInt`, `<: AbstractFloat` | parametric isbits family, `<: Real` |
| `+`, `-`, `*` | exact, then rounded to the context precision (28 significant digits by default; a 31-digit sum loses three digits with no indication) | exact and checked; `OverflowError` rather than a silent round |
| `/` | rounded to the context precision; throws `DivisionByZeroError` or `UndefinedDivisionError` | half-even at `max(S1,S2)`; throws Base's `DivideError` |
| `==`, `<`, `<=`, `cmp` | value-based across representations (`1.20 == 1.2`) | the same |
| `hash` | `Base.decompose`-based, consistent with `Rational` and the floats | the same, with batched digit stripping and no allocation |
| `round` | `digits` and `sigdigits` keywords, six modes | `digits` keyword plus the rounding conversion `round(D, x, mode)`, seven modes; no `sigdigits`, since a fixed-point type has no floating significand |
| `parse`, `tryparse` | regex-based, exact into arbitrary precision | byte-level scanners in the Parsers extension, rounding half-even into the target scale, with a `rounding=` keyword |
| `string`, `show` | plain or scientific notation depending on the exponent | plain positional form from `string`; the `text/plain` `show` switches to scientific notation past 44 characters |
| `precision` | the context's digit budget, dynamic, default 28 | the type's `P` parameter, static |
| `promote_rule` | `Decimal` absorbs every `Real`, including `BigFloat` | floats win promotion; decimals promote among themselves value-preservingly |
| number conversions | blanket `(::Type{T<:Number})(x) = T(BigFloat(x))` (see the bugs below) | exact-or-throw per family; float conversions correctly rounded |
| `zero`, `one`, `abs`, unary `-`, `signbit`, `iszero`, `isfinite`, `isnan` | present | present |
| `min`, `max`, including float mixes | explicit methods | through the `isless` generics |
| float construction `Decimal(0.1)` | the exact binary expansion | `Decimal{P,S}(0.1)` rounds to the scale, `DecimalValue(0.1)` keeps the exact expansion; both behaviours exist, split by type |
| `normalize` | strips trailing zeros | the same, returning a `DecimalValue`, public as `Decimals.normalize` |
| `dec"..."` literals | `@dec_str`, with `_` separators | the same, producing the minimal fitting type |

## In 0.5.1 and not here

| item | disposition |
|---|---|
| the context system: `Context`, `with_context`, `@with_context`, `CONTEXT` (a `ScopedValue`), `rounding(Decimal)`, `Emax`/`Emin` | not carried over. Dynamic rounding state costs dispatch on every operation and makes a result depend on its caller; rounding here is an argument at the call site |
| arbitrary precision: any number of digits, exponents to ±999999 | the ceiling here is 76 digits and scale 16383 (`DecimalValue`). This is the one capability 0.5.1 has that this package does not; `Rational{BigInt}(x)`, which is what `big(x)` returns, is the escape hatch |
| `DivisionByZeroError`, `UndefinedDivisionError` | replaced by Base's `DivideError`; aliases could keep the names if a deprecation path wants them |
| `Decimal <: AbstractFloat` | not carried over; the `AbstractFloat` claim is the source of 0.5.1's `floatmin`/`floatmax`/`Inf` bug reports |
| unreleased on 0.x master, not in 0.5.1: `inv`, `sqrt`, `isone` | `isone` works through the `Base` `==` fallback; `inv` is `one(x)/x` and returns a rounded decimal; `sqrt` returns `Float64`, following `Rational` |

## Here and not in 0.5.1

- The type family: `Decimal32`/`Decimal64`/`Decimal128`/`Decimal256` width
  tiers, `Decimal{P,S,T}` carrying precision and scale in the type,
  `DecimalValue{T}` for runtime scales, `AbstractDecimal`, and `typemin`,
  `typemax`, `eps`, `floatmin`, `floatmax`, `widen`.
- The wire API: `unscaled`, `scale`, `reinterpret` construction,
  `writedecimal!`, and `decimallength`, memcpy-compatible with
  Arrow/Parquet/DuckDB buffers. This is the package's reason to exist.
- The explicit rounding API: `rescale(D, x, mode)`, `divide(x, y, mode)`, and
  rounding-mode-parameterized conversions, in seven modes and with no global
  state.
- Integer division: real `div`, `rem`, `mod`, `fld`, `cld`, and `divrem`
  implementations in all rounding modes; 0.5.1 has these only as
  `AbstractFloat` fallbacks.
- Exact conversions: `Rational` in both directions, correctly rounded
  `Float64`/`Float32`/`Float16`, exact `BigFloat` at any requested precision
  and mode, and exact-or-throw `Integer`.
- Parsers.jl integration: byte-span `parse`, `tryparse`, and a `parsenext`
  tokenizer, with `decimal=` and `rounding=` keywords. `bench/PERF.md` has
  the timings.
- Columnar kernels: SIMD checked broadcast `+` and `-` (same and mixed
  scale), exact widening broadcast `*`, and a vectorized `sum`.
- Scale-preserving integer multiply, `Bool`/`BigInt`/`UInt256` operands, and
  a value-preserving promotion grid.
- Allocation-free scalar arithmetic, checked overflow throughout, and
  differential test suites against a `Rational{BigInt}` oracle.

## Bugs observed in 0.5.1

1. `number` is exported but not defined: `using Decimals; number` raises an
   `UndefVarError`. It is a dangling export from the 0.5 rework.
2. Silent conversion corruption. The blanket `T(x) = T(BigFloat(x))` routes
   integer conversions through a default-precision (256-bit) `BigFloat`, so
   `BigInt(Decimal(10^80 + 1))` returns `10^80`: a wrong answer with no
   error.
3. `Rational{BigInt}(::Decimal)` is a `MethodError`, ambiguous between the
   blanket constructor and Base.MPFR's.

These are consistent with the correctness sweep filed upstream in June 2026,
and are worth reporting there regardless of what happens to this package.

## Migration implications

The 0.x semantics cannot be preserved under this design: different type
layout, no context, and checked rather than silently rounding arithmetic. So
adopting this package as `Decimals` 1.0 is a breaking release. The practical
shape of the migration:

- Keeps working unchanged: `Decimal` as a name, `==`/`<`/`hash` value
  semantics, `parse`/`string` round-trips for ordinary values,
  `round(x; digits)`, `zero`/`one`/`abs`/`signbit`, `dec"..."` literals,
  `normalize`, and scientific-notation display for extreme exponents.
- Breaks with a clear replacement: one `Decimal` type becomes a choice
  between `Decimal{P,S}` and `DecimalValue`; context blocks become explicit
  `rescale`/`divide` calls with a mode; silent rounding to 28 digits becomes
  checked exactness, so code that relied on the rounding opts in through
  `rescale`.
- Lost: values beyond 76 significant digits, and dynamically scoped
  precision.
- Known downstream pin: LibPQ.jl pins `Decimals = 0.4.1`, a pre-0.5 API using
  `number`, so it is already incompatible with 0.5.x and no worse off here.
  `DecimalValue` is the natural target for a PostgreSQL `numeric`.

`docs/src/migration.md` is the user-facing version of this section.
