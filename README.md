# Decimals.jl

[![Docs](https://img.shields.io/badge/docs-dev-blue.svg)](https://JuliaMath.github.io/Decimals.jl/dev/)
[![License: MIT](https://img.shields.io/badge/license-MIT-green.svg)](LICENSE)

Exact fixed-point decimals for Julia, shaped like the ones the data-systems
world already speaks. `Decimal{P,S,T}` is an isbits value whose numeric content
is an integer coefficient and a decimal scale — the same `(precision, scale,
storage width)` triple Arrow, Parquet, DuckDB, PostgreSQL, and MySQL use — so a
`Vector{Decimal{18,2,Int64}}` is byte-identical to a decimal column buffer and
crosses the wire without a conversion pass. Arithmetic is exact and *checked*:
`+`, `-`, `*` never silently round and never wrap, and every place where
rounding is unavoidable takes an explicit `RoundingMode` argument rather than
reading a global context. It is pure Julia with one small dependency, and it is
fast: **8.4 ns** to parse a money string (rust_decimal 7.6, DecFP 25.5),
**1.75 ns** to multiply, **6.7 ns** to divide, and **0.165 ms** to sum a
million values — see [`bench/RESULTS.md`](bench/RESULTS.md).

## Installation

```julia
using Pkg
Pkg.add("Decimals")
```

Julia 1.10 or later. The only runtime dependency is
[BitIntegers.jl](https://github.com/rfourquet/BitIntegers.jl), for the 256-bit
tier.

## Quick start

```julia
using Decimals

# Construct: from a literal, from a string, or straight from a wire coefficient
dec"1.25"                              # Decimal{3,2,Int32} — minimal fitting type
Decimal64{2}("1234.56")                # Decimal{18,2,Int64} — a money column
parse(Decimal64{2}, "1234.567")        # 1234.57 — parsing rounds half-even
reinterpret(Decimal64{2}, 123456)      # 1234.56 — zero-copy from an Arrow buffer

# Arithmetic. + and - keep the scale and are checked; * is exact; / rounds.
Decimal64{2}("1.20") + Decimal64{2}("0.05")     # 1.25   :: Decimal{18,2,Int64}
Decimal64{2}("1.25") * Decimal64{3}("2.500")    # 3.12500 :: Decimal{36,5,Int128}
Decimal64{2}("1.00") / Decimal64{2}("3.00")     # 0.33   (half-even at scale 2)
sum(fill(Decimal64{2}("0.10"), 10))             # 1.00   :: Decimal{38,2,Int128}

# Rounding is always an argument, never a mode you switch on globally
divide(Decimal64{2}("1.00"), Decimal64{2}("3.00"), RoundUp)   # 0.34
rescale(Decimal64{2}, Decimal64{4}("1.2356"), RoundUp)        # 1.24
round(Decimal64{4}("1.2346"); digits=2)                       # 1.2300

# DecimalValue carries its scale per value (a PostgreSQL numeric's dscale)
DecimalValue(12345, 3)                 # 12.345
rescale(DecimalValue(12345, 3), 1)     # 12.3
Decimals.normalize(dec"1.2000")        # 1.2 :: DecimalValue{Int32}

# Printing and reading back
string(Decimal64{2}("-12.30"))         # "-12.30" — always positional, never 1.2e1
parse(Decimal64{2}, "-12.30")          # round-trips
Float64(Decimal64{2}("1.25"))          # 1.25 — correctly rounded
Rational(Decimal64{2}("1.25"))         # 5//4 — exact
```

Overflow, inexactness, and division by zero are errors, not surprises:

```julia
typemax(Decimal64{2}) + Decimal64{2}("1.00")   # OverflowError
convert(Decimal64{2}, Decimal64{4}("1.2345"))  # InexactError (use rescale)
Decimal64{2}("1.00") / zero(Decimal64{2})      # DivideError
```

At the REPL a decimal displays as plain digits (`1234.56`); `repr` and `show`
give the round-trippable typed form, `Decimal{18,2,Int64}("1234.56")`.

Exported names are `Decimal`, `DecimalValue`, `Decimal32`, `Decimal64`,
`Decimal128`, `Decimal256`, `rescale`, `divide`, and `@dec_str`.
`Decimals.normalize`, `Decimals.unscaled`, `Decimals.scale`,
`Decimals.writedecimal!`, `Decimals.decimallength`, and
`Decimals.AbstractDecimal` are public but not exported (`normalize` stays
qualified so it never collides with `LinearAlgebra.normalize`).

## Types

`Decimal{P,S,T}` holds `unscaled::T` and means `unscaled * 10^-S`, with the
invariant `|unscaled| < 10^P`. `P` is the precision, `S` the scale
(`0 <= S <= P`), and `T` the storage integer. The four aliases name the storage
tiers at their maximum precision — exactly the tiers Arrow/Parquet/DuckDB
define:

| alias | expands to | digits | storage | typical use |
|---|---|---|---|---|
| `Decimal32{S}` | `Decimal{9,S,Int32}` | 9 | 32-bit | narrow Arrow/Parquet columns |
| `Decimal64{S}` | `Decimal{18,S,Int64}` | 18 | 64-bit | money, most SQL `DECIMAL` |
| `Decimal128{S}` | `Decimal{38,S,Int128}` | 38 | 128-bit | DuckDB/Spark default width |
| `Decimal256{S}` | `Decimal{76,S,Decimals.Int256}` | 76 | 256-bit | Arrow `Decimal256` |

Write `Decimal{P,S}` when a schema pins a precision narrower than the tier
maximum; the storage type is filled in from `P`. `Decimal{9,2}` and
`Decimal32{2}` differ only in the precision they will accept before throwing.

`DecimalValue{T}` is the runtime-scale sibling: it stores the scale (an
`Int32`, `0:16383`) alongside the coefficient, for row-oriented wire values
whose scale travels with each value — a PostgreSQL `numeric` `dscale`, or the
output of `Decimals.normalize`. It is still isbits, but prefer `Decimal{P,S}` for
columnar data, where the scale is a schema fact and belongs in the type.

Both are `<: Decimals.AbstractDecimal <: Real`. There is deliberately no
`AbstractFloat` subtyping and there are no `NaN` or `Inf` values: `isfinite` is
always `true`, and operations that would produce a non-value throw instead.

## Semantics

| operation | rule |
|---|---|
| `+`, `-` | promote both operands value-preservingly, then compute **checked** — `OverflowError`, never a silent round or wrap |
| `*` | **exact**: result scale is `S1 + S2`, precision `min(P1+P2, 76)`, checked |
| `*` by an `Integer` | scale-preserving (multiplying by a count should not widen the scale) |
| `/` | rounds **half-even** at scale `max(S1, S2)`; `divide(x, y, mode)` for any other `RoundingMode` |
| `sum` | widens to the `Int128` tier, where overflow is provably impossible below 1.7e20 elements — so it is both safe and SIMD |
| `div`, `rem`, `mod`, `fld`, `cld`, `divrem` | real implementations in every rounding mode, not float fallbacks |
| `round`, `trunc`, `floor`, `ceil` | exact and in-type, with a `digits` keyword |
| `convert`, constructors | **exact or throw** (`InexactError`/`OverflowError`) |
| `Decimal{P,S}(::AbstractFloat)` | rounds half-even at scale `S`, as every cross-representation float conversion in Base does; `DecimalValue(x)` gives the *exact* binary expansion instead |
| `parse`, `tryparse` | provided by the Parsers extension (`using Parsers`); round half-even at the target scale, like `parse(Float64, s)`; `tryparse` returns `nothing`. String constructors and `dec"..."` literals need no extension |
| `rescale`, `round(D, x, mode)` | the explicit rounding conversions between decimal types |
| `==`, `<`, `hash` | by numeric value across scales, precisions, and number types: `dec"1.20" == dec"1.2" == 12//10`, and `hash` agrees with equal `Int`/`Float64`/`Rational` |
| `≈` | exact equality (Base's `rtoldefault` for non-`AbstractFloat` reals is 0, as for `Rational`); pass `rtol`/`atol` if you want tolerance |
| `string`, `print`, `writedecimal!` | always the plain positional form — a valid SQL literal, CSV field, and JSON number |
| `show` (`text/plain`) | positional too, switching to scientific notation past 44 characters |
| rounding state | there is none. Every rounding decision is an argument at the call site |

Seven rounding modes are accepted everywhere a mode is taken: `RoundNearest`
(half-even, the default), `RoundNearestTiesAway`, `RoundNearestTiesUp`,
`RoundToZero`, `RoundFromZero`, `RoundDown`, `RoundUp`.

## Extensions

Loaded automatically as package extensions when the companion package is
present:

- **Parsers.jl** — byte-level `Parsers.parse`/`tryparse`/`parsenext` over
  strings or byte spans, with `decimal=','` and `rounding=` keywords, and the
  `Base.parse`/`tryparse` methods for decimal types (there is one parsing
  machinery, and it lives here). This is the ~7 ns path, and it is what a CSV
  or wire reader should call. Requires Parsers 3; under Parsers 2 the
  extension loads as a no-op so environments still resolve — `parse` is then
  unavailable, while string constructors and literals keep working.

  ```julia
  using Decimals, Parsers
  Parsers.parse(Decimal64{2}, "1234.56")                    # 1234.56
  Parsers.parse(Decimal64{2}, "1,25"; decimal=',')          # 1.25
  Parsers.parse(Decimal64{2}, "1.005"; rounding=RoundUp)    # 1.01
  buf = codeunits("12.34,56.78")
  Parsers.parsenext(Decimal64{2}, buf, 1, length(buf))      # (12.34, 6, RC_OK)
  ```

- **Printf.jl** — `%f`/`%e`/`%g` print the true digits (they route through a
  1024-bit `BigFloat`, not `Float64(x)`, so nothing past 17 significant digits
  is silently lost); `%d` is exact-or-`InexactError`, matching `Rational`.

- **JSON.jl** (1.x) — decimals serialize as raw exact-digit JSON *numbers*,
  not strings and not `Float64`-rounded:
  `JSON.json((price = Decimal64{2}("1234.56"),))` gives
  `{"price":1234.56}`.

- **LinearAlgebra.jl** — `A*B`, `dot`, `tr`, `A+B` stay exact decimal;
  factorizations (`lu`, `qr`, `svd`, `eigen`, `det`, `inv`, `\`, …) convert to
  `Float64` first, because in-place elimination at a fixed scale either throws
  mid-factorization or silently corrupts the answer. Use `lu(Rational.(A))` if
  you need an exact factorization.

## Ecosystem

[`docs/ecosystem-compat.md`](docs/ecosystem-compat.md) reports a 117-trial
gauntlet across DataFrames, Statistics, StatsBase, LinearAlgebra, Random,
ForwardDiff, OrdinaryDiffEq, JuMP, Unitful, StaticArrays, and JSON, plus an
instrumented study of the implicit `Real` interface and a cross-system survey
(PostgreSQL, DuckDB, SQL Server, Spark, DataFusion, Arrow C++, pandas, Python
`decimal`) of every operation with more than one defensible answer.

115 of the 117 trials pass. The two that do not — `StatsBase.summarystats` and
adaptive ODE solvers — fail identically for `Rational`, Base's own exact type,
because both require `AbstractFloat` upstream; `float.(v)` is the answer in
each case. The document also records which analytics operations stay decimal
(`sum`, `mean`, `median`) and which return `Float64` (`var`, `std`, `norm`,
`sqrt`, `quantile` at a float `p`), and why.

## Migrating from Decimals 0.x

Version 1.0 is a ground-up rewrite; it shares the package name and little
else. The 0.x `Decimal` was a single heap-backed arbitrary-precision *floating*
decimal (`<: AbstractFloat`, sign + `BigInt` coefficient + exponent) with
Python-style context semantics — every operation silently rounded to a
dynamically scoped precision, 28 significant digits by default. That design
made the type impossible to use as a wire or column type, and its silent
rounding is the opposite of what the applications that reach for decimals
want. The full API diff, including bugs found in 0.5.1 while auditing, is in
[`docs/registered-decimals-audit.md`](docs/registered-decimals-audit.md).

**Keeps working unchanged.** The name `Decimal`; `==`, `<`, and `hash` by
numeric value; `parse`/`string` round-trips for ordinary values;
`round(x; digits)`; `zero`, `one`, `abs`, `signbit`, `iszero`; `dec"..."`
literals; `Decimals.normalize`; scientific-notation display for extreme exponents.

**Needs a change.**

| 0.x | 1.0 |
|---|---|
| `Decimal(1.25)`, one untyped decimal | choose a type: `Decimal64{2}("1.25")` for a fixed-scale column, `DecimalValue` when the scale is per value, `dec"1.25"` for a literal |
| silent rounding to context precision on `+`/`-`/`*` | exact and checked; opt into rounding explicitly with `rescale(D, x, mode)` or `divide(x, y, mode)` |
| `Context`, `with_context`, `@with_context`, `CONTEXT`, `rounding(Decimal)` | removed. Rounding is an argument at each call site — no dynamic state to get wrong, and no 5–30% dispatch tax |
| `DivisionByZeroError`, `UndefinedDivisionError` | Base's `DivideError` |
| `Decimal <: AbstractFloat` | `Decimal <: Real` (the `AbstractFloat` claim is what produced 0.x's `floatmin`/`floatmax`/`Inf` bug reports) |
| `precision(x)` = the context's digit budget | `precision(x)` = the type's `P`; `Decimals.scale(x)` for the scale |
| `round(x; sigdigits)` | not applicable — a fixed-point type has no floating significand. Use `digits` |
| `number` (exported but undefined in 0.5.1) | gone; use `Float64(x)`, `Rational(x)`, or `Int(x)` |

**Genuinely lost.** Values beyond 76 significant digits or scale 16383, and
dynamically scoped precision. If you need unbounded exactness,
`Rational{BigInt}(x)` — which is what `big(x)` returns for a decimal — is the
escape hatch.

**New in 1.0** and worth knowing about if you are coming from 0.x: the
`Decimal32/64/128/256` tiers with schema-fidelity precision and scale;
`DecimalValue`; the zero-copy wire API (`unscaled`, `scale`, `reinterpret`,
`writedecimal!`, `decimallength`); explicit rounding (`rescale`, `divide`,
`round(D, x, mode)`); real `div`/`rem`/`mod`/`fld`/`cld`/`divrem` in every
mode; exact `Rational` and correctly-rounded `Float64`/`Float32`/`Float16` and
`BigFloat` conversions; the Parsers/Printf/JSON/LinearAlgebra extensions; and
SIMD broadcast and `sum` kernels.

## Performance

[`bench/RESULTS.md`](bench/RESULTS.md) has the full comparison against DecFP,
FixedPointDecimals, rust_decimal, Python `decimal`, `Float64`, and
single-threaded polars and duckdb, with the methodology. Headlines, on an Apple
M2 Max, money-shaped values, nanoseconds per operation:

| op | Decimals.jl | DecFP | rust_decimal | py-decimal |
|---|---|---|---|---|
| parse | **8.4** | 25.5 | 7.6 | 88.9 |
| format → `String` | **23.0** | 116.8 | 49.5 | 44.3 |
| format → buffer (`writedecimal!`) | **5.0** | — | — | — |
| multiply | **1.75** | 24.7 | 5.75 | 105.9 |
| divide | **6.7** | 33.6 | 33.1 | 187.5 |
| add (1k-element sum) | **0.17** | 8.6 | 3.2 | 35.4 |

Over a million-element column, single-threaded: parse 8.1 ms, sum 0.165 ms,
multiply ~1.8 ms, format 23 ms (5.0 ms to a buffer) — faster than
single-threaded polars and duckdb on parse, sum, and multiply. Bulk decimal
parse is faster than Parsers.jl's own `Float64` parse over the same strings
(8.1 ms vs 11.6 ms): parsing a money column into an exact decimal now costs
less than parsing it into a lossy float. [`bench/SWEEP.md`](bench/SWEEP.md)
records the shape-by-shape cliff audit behind those numbers.

Everything is allocation-free, and the package is compatible with
`juliac --trim=safe`.

## Contributing

Issues and pull requests are welcome. Run the test suite with

```
julia --project=. -e 'using Pkg; Pkg.test()'
```

The scripts in `bench/` (`compare.jl`, `kernels.jl`, `sweep.jl`, `mt.jl`) need
an environment carrying Chairmarks, Parsers, DecFP, and FixedPointDecimals
alongside this package; each file's header says what it measures. New
functionality wants regression coverage beside the code it touches (parser
changes in `test/parsers.jl`, and so on), and performance claims want
before/after numbers.

## License

MIT. See [LICENSE](LICENSE).
