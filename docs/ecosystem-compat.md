# `Decimal` and `DecimalValue` across the Julia ecosystem

A design note on how these types behave when they leave the package: what
happens when Arrow, PostgreSQL, MySQL, or CSV hand them to DataFrames,
Statistics, Plots, JuMP, DiffEq, Unitful, or JSON, and which operations
change type on the way.

It draws on three things. The first is a 117-trial suite run against the real
packages (DataFrames 1.8, Statistics, StatsBase 0.34, Distributions,
ForwardDiff, OrdinaryDiffEq, JuMP, Unitful 1.28, StaticArrays, JSON, plus
edge-case probes). The second is an instrumented study of the implicit `Real`
interface: a minimal `<: Real` type that logs every method Base and stdlib
generic machinery call per operation, cross-checked against Julia 1.12.6
source and against the problems DecFP.jl, FixedPointDecimals.jl, Unitful.jl,
SaferIntegers.jl, and `Rational` have hit. The third is a comparison with
PostgreSQL, DuckDB, SQL Server, Spark, DataFusion, Arrow C++, NumPy/pandas,
Python `decimal`, and simplejson, for every operation where more than one
return type is defensible.

115 of the 117 trials pass. The two failures come from downstream
requirements, fail identically for `Rational`, and have documented
workarounds (section 1). Every item in the 25-point checklist distilled from
the interface study is implemented, apart from two policy choices and one
open item (section 2).

## 1. Coverage by area

| area (trials) | result | notes |
|---|---|---|
| Base numerics (28) | all pass | `sqrt`/`hypot`/`log`/`exp` return `Float64` (`Rational` precedent: `sqrt(4//1) == 2.0`); `float`, `isapprox`, the `round` families, `divrem`, `^`, `muladd`, `clamp`, `widen`, `eps`, `typemin`/`typemax` |
| Collections (11) | all pass | `Dict`, `Set`, `unique`, `sort`, `searchsorted`, `extrema`, `findmax`; hash agrees with `Int`, `Float64`, and `Rational` across types, via `decompose` |
| Ranges (5) | all pass | `a:s:b`, `a:b`, `range(; step/length)`, `getindex`, `in`, `searchsortedfirst`, all through the generic `StepRange` path; `TwicePrecision` is float-gated and never engages, which is where Unitful had trouble for years |
| DataFrames (6) | all pass | `groupby` on both the all-integral fast path (which needs `isinteger`, `BigInt`, `Int`, and `x-Int`) and the hash path; four join types; `combine`; sort with `missing`; display |
| Statistics (8) | all pass | `mean`, `var`, `std`, `median`, `quantile`, `middle`, `cor`, `cov`; return types in section 3 |
| StatsBase (4) | 3 of 4 | histogram fit, `ecdf`, and `skewness` work; `summarystats` requires `AbstractFloat` and fails identically for `Rational` |
| LinearAlgebra (18) | all pass | matmul, `dot`, `tr`, `+` exact; factorizations route through `float` (section 4) |
| Random (3) | all pass | `rand(D)` uniform on `[0,1)` at the type's scale via the `SamplerType` hook; vector and range sampling |
| ForwardDiff (3) | all pass | `derivative(x->x^2+3x, d)` exact in-type (`Dual`s of `Decimal`); float-free polynomial derivatives stay exact |
| DiffEq (2) | 1 of 2 | non-adaptive exact-coefficient solves (`Euler`, fixed `dt`) work; adaptive solvers need float time and tolerances, a SciML-documented restriction that `Rational` hits the same way |
| JuMP (2) | all pass | decimal coefficients convert cleanly into `Model` (`Float64`), and `GenericModel{Float64}` builds |
| Unitful (7) | all pass | `Quantity{Decimal}` arithmetic; integer-factor `uconvert` stays decimal; rational factors promote to `Rational` (section 5) |
| StaticArrays (2) | all pass | `SVector` arithmetic and `dot` exact |
| JSON (2) | all pass | JSON numbers with exact digits, via the extension (section 6) |
| Edge cases (10) | all pass | `-0.0` `isequal` probes, empty-range dead-branch arithmetic (the SaferIntegers #26 class), promotion round-trips, `Bool` conversion in matmul, comparisons against floats too wide for `Float64` |
| Performance probes (6) | all pass | reductions and broadcast over 10⁶ elements allocation-free; the SIMD `sum` specialization stays engaged through the ecosystem paths |

The two failures:

1. `StatsBase.summarystats` and `describe` require `AbstractFloat` input.
   `summarystats(float.(v))` is the answer. `Rational` fails identically.
2. Adaptive ODE solvers (`Tsit5()` and its neighbours). SciML documents that
   adaptive time types must be floating point; adaptivity also uses `NaN` as
   a reject-step sentinel, which no exact type has. Non-adaptive solvers with
   exactly-representable coefficients, such as `Euler()` with `dt=dec"0.1"`,
   work and are exact. For anything adaptive,
   `solve(remake(prob, u0=float.(u0)), ...)`.

## 2. The implicit `Real` interface

The instrumented study produced a 25-item checklist of what Base and the
ecosystem actually call on a custom `Real`. The load-bearing fallback chains
are `Base.decompose`, feeding `hash`, `isfinite`, and `Rational` comparison;
`Base.AbstractFloat`, feeding `float(x)`, `float(T)`, norms, plots, and
histograms; the `T(::T)` identity constructor, feeding range `getindex`,
`oneunit`, and DiffEq; and `<` rather than `isless`, since Base derives
`isless` from `<` for `Real`s.

| tier | items | coverage |
|---|---|---|
| 0, existence | `T(::T)`, `Int`/`Float64`/`Bool`/`Rational` construction and convert, promote rules, `==`/`<` (exact cross-type against floats rather than promote-and-hope), `show`/`parse`/`tryparse`, `Base.decompose`, `AbstractFloat`/`Float64`/`Float32` | all implemented; `decompose` strips in batches of five digits, and float conversions are correctly rounded, never double-rounded |
| 1, arithmetic protocol | `+ - * /` (checked), `abs`/`abs2`/`sign`/`signbit`, `zero`/`one`/`oneunit`, `iszero`/`isone`, `isfinite`/`isnan`/`isinf`/`isinteger`, `inv`, `muladd`, `sqrt` to `Float64`, `min`/`max`/`clamp` | all implemented |
| 2, ranges | `rem`/`div`/`mod`/`fld`/`cld`, `round(x, ::RoundingMode)`, `Integer`/`Int`/`BigInt` conversion | all implemented |
| 3, text and serialization | `round(; digits)` staying exact (Base's fallback returns `Float64`), `Printf.tofloat`, JSON `tostring` | all implemented; see section 6 |
| 4, statistics polish | `/(T, Int)` semantics (section 3), `eps`, `typemin`/`typemax`/`widen` | all implemented |
| 5, opt-in hooks | `Random.rand` sampler, `Base.checked_*` aliases, Unitful closure rules, Plots/Makie type recipes | sampler and `checked_*` implemented; Unitful closure rules are a policy choice (section 5); a Plots/Makie recipe is open, and would add exact-digit tick labels to a path that already works through `Float64` |

Two departures from the usual defaults, both matching `Rational`:

- `≈` between two decimals is exact equality, since `rtoldefault` is 0 for a
  non-`AbstractFloat` `Real`. That is arguably right for money, and `rtol` or
  `atol` is available. Comparing against a `Float64` brings that type's
  tolerance with it, again as for `Rational`.
- There are no `NaN` or `Inf` values. `isnan` is always `false`, `isfinite`
  always `true`, and operations that would produce them throw.

## 3. What analytics operations return

For each contested operation, the table records the choice made here and the
precedent behind it, drawn from the SQL engines, Arrow, Spark, pandas, and
Julia's own exact type.

| operation | result | precedent |
|---|---|---|
| `sum` | exact decimal, accumulated in a wider storage tier (SIMD where provably safe) | universal: every engine widens `sum` at fixed scale (PostgreSQL `numeric`, DuckDB `DECIMAL(38,s)`, Spark `p+10`). Wrapping corrupts silently, as FixedPointDecimals' `sum` does, and checked-throw without widening trips on real data |
| `mean` | same-scale decimal, half-even rounded | the Arrow C++ choice. The alternatives are raising the scale (PostgreSQL, Spark, SQL Server, `s+4`) or going to `DOUBLE` (DuckDB). Rounding at the input's own scale is visible, deterministic, and type-stable, and `mean(float.(v))` is one call away |
| `median`, `middle` | decimal (rounds only if the midpoint needs an extra digit) | DuckDB: `median(DECIMAL(10,2)) → DECIMAL(10,2)` |
| `var`, `cov`, `kurtosis` | decimal, widened as the intermediate squares require | the same as `Rational` in Base: `var(::Vector{Rational})` is a `Rational` |
| `std`, `cor`, `skewness` | `Float64`, since each ends in a square root or a ratio of roots | the same as `Rational` in Base; `DOUBLE` in every engine except PostgreSQL |
| `quantile(v, p::Float64)` | `Float64`, since a float `p` enters the interpolation; an exact `p::Rational` stays exact | the same as `Rational` in Base |
| `norm`, `hypot`, `sqrt`, `exp`, `log`, trig | `Float64` | settled Base convention (`norm([3//1,4//1]) == 5.0`; Unitful PR #500 adopted it too) |
| `lu`, `det`, `inv`, `\`, factorizations | route through `float(A)` | section 4 |
| overflow anywhere | `OverflowError`; `+`, `-`, `*` never wrap and never silently round | `Rational` is Base's precedent that throwing is acceptable; FixedPointDecimals is the precedent that wrapping is not |

## 4. LinearAlgebra

`A*B`, `dot`, `tr`, `A+B`, and `kron` stay exact, widening product types via
`promote_op`. Factorizations (`lu`, `cholesky`, `qr`, `svd`, `eigen`, `det`,
`inv`, `\`, `nullspace`, `pinv`, `cond`, and the rest) convert to `Float64`
first, in `DecimalsLinearAlgebraExt`. Three reasons:

- A generic `lu!` on a fixed-scale decimal either throws `InexactError`
  mid-elimination or silently corrupts the result: a measured `det` of
  `-2.0004` for a matrix whose true determinant is `-2`, because every
  elimination step rounds at scale and the pivoting decisions compound it.
- No system in the comparison runs LAPACK-style algorithms in fixed decimal.
  Eigensolvers are float-only even for DecFP, whose maintainers point users
  at `Float64` or GenericLinearAlgebra; eigenvalues carry roundoff
  regardless, so decimal exactness buys nothing there.
- `Rational`'s exact `lu` works only because `Rational` grows unboundedly. A
  fixed-scale type cannot offer exact elimination.

A generic-precision factorization is still available explicitly:
`lu(Rational.(A))`, or GenericLinearAlgebra.jl over `big.(A)`.

## 5. Unitful

`Quantity{Decimal}` arithmetic and integer-factor conversions (`m` to `cm`,
and so on) stay decimal. Conversion factors that are `Rational{Int}` promote
the value to `Rational`: exact, never throwing, never silently rounding.
There are no `*(Decimal, Rational) -> Decimal` closure rules, because those
would force rounding inside a units library that users chose for
correctness. If the result must be decimal, `convert` back at the end, which
is exact-or-throw.

## 6. Text and serialization

- `print` and `string` produce plain positional digits, always
  round-trippable; the `text/plain` `show` switches to scientific notation
  past 44 characters.
- `parse` and `tryparse` round half-even, following the float-parse
  precedent, with `rounding=` control in the Parsers extension.
  `bench/PERF.md` has the timings.
- `round(x; digits=n)` is exact and in-type. Base's generic fallback returns
  `Float64`, a documented wart for `Rational` that is overridden here.
- Printf (`DecimalsPrintfExt`): `%d` behaves as `Rational`'s does,
  exact-or-`InexactError`; `%f`, `%e`, and `%g` route through a 1024-bit
  `BigFloat` instead of the default `Float64(x)`, so digits past `Float64`'s
  17 are not lost. DecFP printed `Float64`-rounded `@printf` output for years
  before growing the same hook.
- JSON (`DecimalsJSONExt`, JSON 1.x only): decimals emit as JSON numbers with
  their exact digits, via the documented `JSON.tostring` hook. The precedent
  is simplejson and PostgreSQL/DuckDB JSON export; the default Julia path
  stringifies `Float64(x)`, rounding anything past 17 significant digits.
  Verified against JSON 1.7.1. JSON 1.x still pins Parsers 1–2, so it cannot
  share an environment with Parsers 3; the Parsers extension loads as a no-op
  under Parsers 2 so the pairing resolves, and the in-suite JSON tests
  (`test/json.jl`) activate once JSON gains Parsers 3 compatibility.
- JSON3 stringifies unknown `Real`s via `Float64`. Overriding that needs a
  `JSON3`/`StructTypes` weak dependency, deferred until someone asks, since
  JSON.jl v1 is the going-forward line.

## 7. Where conversion to float happens

These are domains where comparable systems convert as well, documented here
rather than left to be discovered:

| domain | why | escape hatch |
|---|---|---|
| `eigvals`, `eigen`, `svd`, Schur | LAPACK-only by stdlib design; roundoff inherent | automatic, via the LinearAlgebra extension (`float(A)`) |
| adaptive ODE | float tolerances, `eps`, and a `NaN` reject-step sentinel, as SciML documents | `float.(u0)`; fixed-step solving stays exact |
| JuMP nonlinear and solver internals | solvers are `Float64`, or `Rational`/`BigFloat` for exact LP | coefficients convert automatically; use `Rational` where exactness is the point |
| `summarystats`, `describe` | upstream `AbstractFloat` requirement | `summarystats(float.(v))` |
| plot coordinates | Plots and Makie pipelines are `Float64` by design | automatic; exact tick labels await a type recipe |

## 8. Performance through ecosystem paths

The performance probes confirm that the kernel-level results carry through
generic code: `sum`, `mean`, and broadcast over 10⁶-element columns stay
allocation-free with the SIMD paths engaged; DataFrames `groupby` and `join`
hit the `decompose`-based hash without falling back to `BigInt`; sorting is
`<` on the unscaled integer.

One note to carry: a checked `+` in a hand-written `reduce` defeats SIMD,
which is the lesson SaferIntegers taught. `sum` sidesteps it by widening to a
tier where overflow is provably impossible and accumulating unchecked; custom
reductions in narrow types will see the checked-operation cost, which is the
price of never wrapping.
