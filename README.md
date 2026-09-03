# Decimals.jl

[![Docs](https://img.shields.io/badge/docs-dev-blue.svg)](https://JuliaMath.github.io/Decimals.jl/dev/)
[![License: MIT](https://img.shields.io/badge/license-MIT-green.svg)](LICENSE)

Exact fixed-point decimal numbers for Julia.

`Decimal{P,S,T}` is an isbits value holding one integer coefficient, with the
precision `P` and scale `S` fixed in the type. That is the same
`(precision, scale, storage width)` description Arrow, Parquet, DuckDB,
PostgreSQL, and MySQL use for a decimal column, so a
`Vector{Decimal{18,2,Int64}}` already has the layout of a decimal column
buffer and needs no per-element conversion at a format boundary.

Arithmetic is exact and checked. `+`, `-`, and `*` neither round nor wrap;
they throw `OverflowError` when a result does not fit. Where rounding is
unavoidable it takes a `RoundingMode` argument at the call site, rather than
reading a global context.

Version 1.0 is a rewrite and shares little with 0.x beyond the package name;
see [Migrating from 0.x](#migrating-from-0x).

## Installation

```julia
using Pkg
Pkg.add("Decimals")
```

Julia 1.10 or later. There are no runtime dependencies outside the standard
library; the 256-bit storage integers (`Decimals.Int256`/`UInt256`) are
implemented in the package, on LLVM's native wide-integer arithmetic.

## Quick start

```julia
using Decimals

# Construct: from a literal, from a string, or from a wire coefficient
dec"1.25"                              # Decimal{3,2,Int32}, the minimal fitting type
Decimal64{2}("1234.56")                # Decimal{18,2,Int64}, a money column
reinterpret(Decimal64{2}, 123456)      # 1234.56, zero-copy from an Arrow buffer

# + and - keep the scale and are checked; * is exact; / rounds
Decimal64{2}("1.20") + Decimal64{2}("0.05")     # 1.25    :: Decimal{18,2,Int64}
Decimal64{2}("1.25") * Decimal64{3}("2.500")    # 3.12500 :: Decimal{36,5,Int128}
Decimal64{2}("1.00") / Decimal64{2}("3.00")     # 0.33    (half-even at scale 2)
sum(fill(Decimal64{2}("0.10"), 10))             # 1.00    :: Decimal{38,2,Int128}

# Rounding is an argument, not a mode to switch on
divide(Decimal64{2}("1.00"), Decimal64{2}("3.00"), RoundUp)   # 0.34
rescale(Decimal64{2}, Decimal64{4}("1.2356"), RoundUp)        # 1.24
round(Decimal64{4}("1.2346"); digits=2)                       # 1.2300

# DecimalValue carries its scale per value, like a PostgreSQL numeric dscale
DecimalValue(12345, 3)                 # 12.345
rescale(DecimalValue(12345, 3), 1)     # 12.3
Decimals.normalize(dec"1.2000")        # 1.2 :: DecimalValue{Int32}

# Printing and conversion
string(Decimal64{2}("-12.30"))         # "-12.30", always positional
Float64(Decimal64{2}("1.25"))          # 1.25, correctly rounded
Rational(Decimal64{2}("1.25"))         # 5//4, exact
```

Parsing lives in the Parsers extension, so `parse` and `tryparse` need
`using Parsers` alongside `using Decimals`:

```julia
using Decimals, Parsers

parse(Decimal64{2}, "1234.567")        # 1234.57, half-even at the target scale
tryparse(Decimal64{2}, "nope")         # nothing
```

String constructors and `dec"..."` literals use the package's own exact
scanner and work without any extension.

Overflow, inexactness, and division by zero are errors:

```julia
typemax(Decimal64{2}) + Decimal64{2}("1.00")   # OverflowError
convert(Decimal64{2}, Decimal64{4}("1.2345"))  # InexactError (use rescale)
Decimal64{2}("1.00") / zero(Decimal64{2})      # DivideError
```

At the REPL a decimal displays as plain digits (`1234.56`); `repr` and `show`
give the round-trippable typed form, `Decimal{18,2,Int64}("1234.56")`.

`Decimal`, `DecimalValue`, `Decimal32`, `Decimal64`, `Decimal128`,
`Decimal256`, `rescale`, `divide`, and `@dec_str` are exported.
`Decimals.normalize`, `Decimals.unscaled`, `Decimals.scale`,
`Decimals.writedecimal!`, `Decimals.decimallength`, and
`Decimals.AbstractDecimal` are public but not exported; `normalize` stays
qualified so that it does not collide with `LinearAlgebra.normalize`.

## Types

`Decimal{P,S,T}` holds `unscaled::T` and means `unscaled * 10^-S`, with the
invariant `|unscaled| < 10^P`. `P` is the precision, `S` the scale
(`0 <= S <= P`), and `T` the storage integer. The four aliases name the
storage tiers at their maximum precision, which are the tiers
Arrow/Parquet/DuckDB define:

| alias | expands to | digits | storage | typical use |
|---|---|---|---|---|
| `Decimal32{S}` | `Decimal{9,S,Int32}` | 9 | 32-bit | narrow Arrow/Parquet columns |
| `Decimal64{S}` | `Decimal{18,S,Int64}` | 18 | 64-bit | money, most SQL `DECIMAL` |
| `Decimal128{S}` | `Decimal{38,S,Int128}` | 38 | 128-bit | DuckDB/Spark default width |
| `Decimal256{S}` | `Decimal{76,S,Decimals.Int256}` | 76 | 256-bit | Arrow `Decimal256` |

Write `Decimal{P,S}` when a schema pins a precision narrower than the tier
maximum; the storage type is filled in from `P`. `Decimal{7,2}` and
`Decimal32{2}` both store an `Int32` and differ only in the number of digits
they accept before throwing.

`DecimalValue{T}` is the runtime-scale sibling: it stores the scale (an
`Int32` in `0:16383`) alongside the coefficient, for row-oriented values
whose scale travels with the value rather than the column, such as a
PostgreSQL `numeric` dscale or the result of `Decimals.normalize`. It is
still isbits, but for columnar data `Decimal{P,S}` is the better fit, since
there the scale is a schema fact and belongs in the type.

Both are `<: Decimals.AbstractDecimal <: Real`. There is no `AbstractFloat`
subtyping and there are no `NaN` or `Inf` values: `isfinite` is always
`true`, and an operation that would produce a non-value throws.

## Semantics

| operation | rule |
|---|---|
| `+`, `-` | promote both operands value-preservingly, then compute checked: `OverflowError`, never a silent round or wrap |
| `*` | exact; result scale is `S1 + S2`, precision `min(P1+P2, 76)`, checked |
| `*` by an `Integer` | scale-preserving, since multiplying by a count should not widen the scale |
| `/` | rounds half-even at scale `max(S1, S2)`; `divide(x, y, mode)` for any other `RoundingMode` |
| `sum` | widens to the `Int128` tier, where overflow is provably impossible below 1.7e20 elements, so the reduction is both safe and vectorizable |
| `div`, `rem`, `mod`, `fld`, `cld`, `divrem` | real implementations in every rounding mode, not float fallbacks |
| `round`, `trunc`, `floor`, `ceil` | exact and in-type, with a `digits` keyword |
| `convert`, constructors | exact or throw (`InexactError`/`OverflowError`) |
| `Decimal{P,S}(::AbstractFloat)` | rounds half-even at scale `S`, as cross-representation float conversions in Base do; `DecimalValue(x)` keeps the exact binary expansion instead |
| `parse`, `tryparse` | provided by the Parsers extension; round half-even at the target scale, like `parse(Float64, s)`; `tryparse` returns `nothing` |
| `rescale`, `round(D, x, mode)` | the explicit rounding conversions between decimal types |
| `==`, `<`, `hash` | by numeric value across scales, precisions, and number types: `dec"1.20" == dec"1.2" == 12//10`, and `hash` agrees with an equal `Int`, `Float64`, or `Rational` |
| `≈` | exact equality between decimals, since Base's `rtoldefault` is 0 for a non-`AbstractFloat` `Real`, as for `Rational`; pass `rtol`/`atol` for a tolerance |
| `string`, `print`, `writedecimal!` | always the plain positional form, which is a valid SQL literal, CSV field, and JSON number |
| `show` (`text/plain`) | positional too, switching to scientific notation past 44 characters |
| rounding state | there is none; every rounding decision is an argument at the call site |

Seven rounding modes are accepted wherever a mode is taken: `RoundNearest`
(half-even, the default), `RoundNearestTiesAway`, `RoundNearestTiesUp`,
`RoundToZero`, `RoundFromZero`, `RoundDown`, and `RoundUp`.

## Extensions

These load as package extensions when the companion package is present.

- **Parsers.jl** provides byte-level `Parsers.parse`, `Parsers.tryparse`, and
  `Parsers.parsenext` over strings or byte spans, with `decimal=` and
  `rounding=` keywords, and defines the `Base.parse`/`Base.tryparse` methods
  for decimal types. All string parsing goes through here, which is where a
  CSV or wire reader already is. It requires Parsers 3; under Parsers 2 the
  extension loads as a no-op so that such environments still resolve, and
  `parse` is then unavailable while string constructors and literals keep
  working.

  ```julia
  using Decimals, Parsers
  Parsers.parse(Decimal64{2}, "1234.56")                    # 1234.56
  Parsers.parse(Decimal64{2}, "1,25"; decimal=',')          # 1.25
  Parsers.parse(Decimal64{2}, "1.005"; rounding=RoundUp)    # 1.01
  buf = codeunits("12.34,56.78")
  Parsers.parsenext(Decimal64{2}, buf, 1, length(buf))      # (12.34, 6, Parsers.RC_OK)
  ```

- **Printf.jl**: `%f`, `%e`, and `%g` print the true digits, routing through a
  1024-bit `BigFloat` rather than `Float64(x)`, so nothing past 17
  significant digits is lost. `%d` is exact-or-`InexactError`, matching
  `Rational`.

- **JSON.jl** (1.x): decimals serialize as JSON numbers with their exact
  digits, neither as strings nor `Float64`-rounded, so
  `JSON.json((price = Decimal64{2}("1234.56"),))` gives `{"price":1234.56}`.

- **LinearAlgebra.jl**: `A*B`, `dot`, `tr`, and `A+B` stay exact decimal.
  Factorizations (`lu`, `qr`, `svd`, `eigen`, `det`, `inv`, `\`, and the rest)
  convert to `Float64` first, because in-place elimination at a fixed scale
  either throws mid-factorization or silently corrupts the result. Use
  `lu(Rational.(A))` for an exact factorization.

## Ecosystem

[`docs/ecosystem-compat.md`](docs/ecosystem-compat.md) records how these
types behave under DataFrames, Statistics, StatsBase, LinearAlgebra, Random,
ForwardDiff, OrdinaryDiffEq, JuMP, Unitful, StaticArrays, and JSON, together
with the reasoning behind each operation that has more than one defensible
answer, checked against PostgreSQL, DuckDB, SQL Server, Spark, DataFusion,
Arrow C++, pandas, and Python `decimal`.

115 of its 117 trials pass. The two that do not, `StatsBase.summarystats`
and adaptive ODE solvers, require `AbstractFloat` input and fail identically
for `Rational`; `float.(v)` is the answer in both cases. The document also
records which analytics operations stay decimal (`sum`, `mean`, `median`) and
which return `Float64` (`var`, `std`, `norm`, `sqrt`, `quantile` at a float
`p`).

## Migrating from 0.x

The 0.x `Decimal` was a heap-backed arbitrary-precision floating decimal
(`<: AbstractFloat`, sign plus `BigInt` coefficient plus exponent) with
Python-style context semantics, rounding every operation to a dynamically
scoped precision. Names that keep working include `Decimal` itself, `==`/`<`
and `hash` by numeric value, `parse`/`string` round-trips for ordinary
values, `round(x; digits)`, `dec"..."` literals, and `Decimals.normalize`.
The context API (`Context`, `with_context`, `CONTEXT`) is gone, and the
single untyped `Decimal` becomes a choice between `Decimal{P,S}` and
`DecimalValue`.

The [migration guide](https://JuliaMath.github.io/Decimals.jl/dev/migration/)
covers the replacements one by one;
[`docs/comparison-with-0.5.1.md`](docs/comparison-with-0.5.1.md) is the full
API comparison.

## Performance

On an Apple M3 Max under Julia 1.12.6, with money-shaped `Decimal64{2}`
values: 6.57 ns to parse a string, 22.71 ns to format one, 1.57 ns to
multiply, 6.50 ns to divide, and 0.165 ms to sum a million-element column.
Scalar arithmetic and comparison are allocation-free. CI also compiles a
`juliac --trim=safe` workload covering parsing, arithmetic, formatting, and
the wire API, so those paths stay statically compilable.

[`bench/PERF.md`](bench/PERF.md) has the method, the machine and version
table, the comparison against Decimals 0.5.1, DecFP, FixedPointDecimals,
rust_decimal, Python `decimal`, polars, and duckdb, the cases where another
library is faster, and the charts in [`bench/charts/`](bench/charts).

## Contributing

Issues and pull requests are welcome. Run the test suite with

```
julia --project=. -e 'using Pkg; Pkg.test()'
```

The scripts in `bench/` need an environment carrying Chairmarks, Parsers,
DecFP, and FixedPointDecimals alongside this package; each file's header says
what it measures, and `bench/PERF.md` lists the steps. New functionality
wants regression coverage beside the code it touches (parser changes in
`test/parsers.jl`, and so on), and performance claims want before/after
numbers.

## License

MIT. See [LICENSE](LICENSE).
