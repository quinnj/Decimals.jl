# Semantics

This page is the contract: what each operation returns, and what happens at the
edges. The short version is that nothing here silently loses a digit. Where a
result cannot be exact, either you passed a rounding mode, or you get an
exception.

## The rules in one table

| operation | rule |
|---|---|
| `+`, `-` | promote both operands value-preservingly, then compute **checked** — `OverflowError`, never a silent round or wrap |
| `*` | **exact**: result scale is `S1 + S2`, precision `min(P1+P2, 76)`, checked |
| `*` by an `Integer` | scale-preserving; the precision grows by the integer's digit count |
| `/` | rounds **half-even** at scale `max(S1, S2)`; [`divide(x, y, mode)`](@ref divide) for any other mode |
| `sum` | widens to the `Int128` tier, where overflow is provably impossible below 1.7e20 elements — safe *and* SIMD |
| `div`, `rem`, `mod`, `fld`, `cld`, `divrem` | real implementations in every rounding mode, not float fallbacks |
| `round`, `trunc`, `floor`, `ceil` | exact and in-type, with a `digits` keyword; no `sigdigits` |
| `convert`, constructors | **exact or throw** (`InexactError` / `OverflowError`) |
| `Decimal{P,S}(::AbstractFloat)` | rounds half-even at scale `S`, as cross-representation float conversions in Base do |
| `DecimalValue(::AbstractFloat)` | the *exact* binary expansion — that is what a runtime scale is for |
| `parse`, `tryparse` | round half-even at the target scale, like `parse(Float64, s)`; `tryparse` returns `nothing` |
| [`rescale`](@ref), `round(D, x, mode)` | the explicit rounding conversions between decimal types |
| `==`, `<`, `hash` | by numeric value across scales, precisions, and number types |
| `≈` | exact equality (`rtoldefault` is 0 for a non-`AbstractFloat` `Real`, as for `Rational`) |
| `string`, `print`, `writedecimal!` | always the plain positional form |
| `show` (`text/plain`) | positional, switching to scientific notation past 44 characters |
| rounding state | there is none |

## Why checked, not rounding

The 0.x package, like Python's `decimal`, rounded every operation to a
dynamically scoped precision. That is a correctness trap in exactly the
applications that reach for a decimal type: a sum quietly loses its low digits
and nothing tells you. `Rational` is Base's own proof that throwing is
sanctioned behaviour for an exact type, and FixedPointDecimals is the proof
that the other failure mode — wrapping on overflow — corrupts silently.

So `+`, `-`, and `*` throw `OverflowError` rather than round or wrap. The cost
is a branch per scalar operation, which is why `sum` and the broadcast kernels
are specialised: they widen or block-check so that the common columnar
reductions stay branch-free and vectorized while remaining safe. A *naive*
user-written `reduce(+, v)` over a narrow type will pay the checked-op cost;
that is the price of never wrapping.

## No global state

Rounding is never a mode you switch on. There is no context object, no scoped
value, no `setrounding`. Everywhere a rounding decision has to be made, the
mode is an argument:

- [`divide(x, y, mode)`](@ref divide) instead of `/`
- [`rescale(D, x, mode)`](@ref rescale), [`rescale(v, s, mode)`](@ref rescale)
- `round(D, x, mode)`, `round(I, x, mode)` for integer targets
- `round(x, mode; digits)` within a type
- `rounding=` on `Parsers.parse`

The seven accepted modes are `RoundNearest` (half-even, the default),
`RoundNearestTiesAway`, `RoundNearestTiesUp`, `RoundToZero`, `RoundFromZero`,
`RoundDown`, and `RoundUp`.

The design cost of a dynamic context is measurable — it is DecFP's 5–30%
dispatch tax — and the correctness cost is that a function's result depends on
its caller. Neither is worth paying.

## Result types

Arithmetic never invents a type wider than the promotion of its inputs, so
folds are type-stable. The result-type rules:

| expression | result |
|---|---|
| `Decimal{P1,S1} + Decimal{P2,S2}` | `promote_type` of the two: scale `max(S1,S2)`, integer digits `max(P1-S1, P2-S2)`, capped at 76 |
| `Decimal{P1,S1} * Decimal{P2,S2}` | scale `S1+S2`, precision `min(P1+P2, 76)` |
| `Decimal{P,S} * ::Integer` | scale `S`, precision `min(P + digits(I), 76)` |
| `Decimal{P1,S1} / Decimal{P2,S2}` | scale `max(S1,S2)`, precision sized for the widest possible quotient |
| `sum(::Vector{Decimal{P,S,T}})` | `Decimal{38,S,Int128}` for the 32/64-bit tiers; unchanged for wider ones |
| decimal ⊕ `AbstractFloat` | the float type — floats win promotion |
| decimal ⊕ `Rational{I}` | `Rational` — the exact type that can hold the result |
| `DecimalValue{T1}` ⊕ `DecimalValue{T2}` | `DecimalValue{promote_type(T1,T2)}`, scale `max` |
| `DecimalValue` ⊕ `Decimal` | `DecimalValue` with the promoted storage type |

The 76-digit cap is where the `Int256` tier ends; an operation whose exact
result would need more digits throws rather than truncating.

## Conversions

Out of a decimal:

| target | behaviour |
|---|---|
| `Float64`, `Float32`, `Float16` | correctly rounded, no double-rounding, no MPFR on the fast path |
| `BigFloat` | exact at any requested precision and MPFR rounding mode |
| `Rational{I}` | exact, in lowest terms; `Rational(::Decimal)` uses the storage type as `I` |
| `big(x)` | `Rational{BigInt}` — a `BigFloat` would re-round the fraction in binary |
| `Int`, `BigInt`, any `Integer` | exact or `InexactError`; `round`/`trunc`/`floor`/`ceil` with an `Integer` type argument are the rounding forms |

Note that `Integer(x)` returns the widest signed type the conversion machinery
uses (`Decimals.Int256`), while `Int(x)` gives an `Int`. Ask for the type you
want.

Into a decimal, everything is exact-or-throw except the two documented
rounding entry points — `AbstractFloat` construction and `parse`. Both round
half-even, which is what `parse(Float64, s)` and every cross-representation
float conversion in Base do.

## Equality, ordering, and hashing

Comparison is exact and cross-type. `dec"1.20"`, `dec"1.2"`, `12//10`, `1.2`,
and `Decimal128{9}("1.200000000")` all compare equal, and all hash equal.
Comparisons against floats are done exactly (a cross-multiply in the 2/5-power
domain), not by promoting the decimal to `Float64` and hoping — so a decimal
too wide for a `Float64` still compares correctly.

Hashing goes through `Base.decompose`, the same hook `Rational` and the float
types use, which is what makes `Dict`, `Set`, `unique`, `searchsorted`, and
DataFrames `groupby`/`join` behave across mixed numeric types.

Ordering is total. `isless` and `<` agree; there is no `NaN` to make them
differ. Sorting a decimal vector is a comparison on the unscaled integer when
the scales match.

## Text

`string`, `print`, and [`writedecimal!`](@ref Decimals.writedecimal!) always
emit the plain positional form, so the output is simultaneously a valid SQL
literal, CSV field, and JSON number, and always round-trips through `parse`.

Display is separate: `show(io, MIME"text/plain", x)` — what the REPL calls —
prints the positional form up to 44 characters and switches to scientific
notation beyond it, so a scale-1000 `DecimalValue` does not fill your screen
with zeros. Two-argument `show` gives the typed constructor form,
`Decimal{18,2,Int64}("1234.56")`, which is what `repr` and container display
use.

`Printf`'s `%f`/`%e`/`%g` print the true digits through a 1024-bit `BigFloat`;
`%d` is exact-or-`InexactError`. `JSON.json` emits raw exact digits. Both are
package extensions.

## The implicit `Real` interface

A study of what Base and the ecosystem *actually call* on a custom `Real`
produced a 25-item checklist, with the load-bearing fallback chains being
`Base.decompose` (feeding hash, `isfinite`, and `Rational` comparison),
`Base.AbstractFloat`/`float` (feeding norms, plotting, histograms), the
`T(::T)` identity constructor (feeding range `getindex`, `oneunit`, and DiffEq),
and `<` rather than `isless` (Base derives `isless` *from* `<` for `Real`s).

Every item is implemented, with two deliberate non-defaults — exact `≈`, and
the absence of `NaN`/`Inf` — and one backlog item, a Plots/Makie type recipe
that would give exact-digit tick *labels* (plotting works today through the
`Float64` path).

## Ecosystem behaviour

The full report is `docs/ecosystem-compat.md` in the repository: a 117-trial
gauntlet against real packages, plus a cross-system survey of PostgreSQL,
DuckDB, SQL Server, Spark, DataFusion, Arrow C++, pandas, and Python `decimal`
for every operation where "what should this return" has more than one
defensible answer.

**115 of the 117 trials pass.** Base numerics, collections, ranges, DataFrames
(`groupby`, four join types, `combine`, sorting with `missing`), Statistics,
LinearAlgebra, `Random`, ForwardDiff, JuMP, Unitful, StaticArrays, and JSON all
work, as do the landmine probes (`-0.0` `isequal`, empty-range dead-branch
arithmetic, promotion round-trips, comparisons against floats too wide for
`Float64`).

### What analytics operations return

| operation | ours | precedent |
|---|---|---|
| `sum` | exact decimal, widened to the `Int128` tier | universal — every engine widens `sum` at fixed scale |
| `mean` | same-scale decimal, half-even rounded | the Arrow C++ camp; PG/Spark raise the scale, DuckDB goes to `DOUBLE` |
| `median`, `middle` | decimal (rounds only if the midpoint needs an extra digit) | DuckDB: `median(DECIMAL(10,2)) → DECIMAL(10,2)` |
| `var`, `std`, `skewness`, `kurtosis` | `Float64` | near-universal; `std(::Vector{Rational})` is `Float64` in Base too |
| `quantile(v, p::Float64)` | `Float64`; an exact `p::Rational` stays exact | exactly `Rational`'s behaviour in Base |
| `norm`, `hypot`, `sqrt`, `exp`, `log`, trig | `Float64` | settled Base convention (`norm([3//1,4//1]) == 5.0`) |
| overflow anywhere | `OverflowError` | `Rational` is Base's precedent for throwing |

### LinearAlgebra: exact where exact is honest

`A*B`, `dot`, `tr`, `A+B`, and `kron` stay exact decimal. Factorizations
convert to `Float64` first, and this is a deliberate choice validated three
ways:

- A generic `lu!` on a fixed-scale decimal either throws `InexactError`
  mid-elimination or *silently corrupts*: the measured determinant of a matrix
  whose true determinant is `-2` came back as `-2.0004`, because every
  elimination step rounds at scale and the pivoting decisions compound it.
- No system in the survey runs LAPACK-style algorithms in fixed decimal.
  Eigensolvers are float-only even for DecFP, whose maintainers point users at
  `Float64` — eigenvalues carry roundoff regardless, so decimal exactness buys
  nothing there.
- `Rational`'s exact `lu` works only because `Rational` grows unboundedly. A
  fixed-scale type cannot honestly claim exact elimination.

If you want a generic-precision factorization, ask for one explicitly:
`lu(Rational.(A))`, or GenericLinearAlgebra.jl over `big.(A)`.

### Unitful

`Quantity{Decimal}` arithmetic and integer-factor conversions (`m` ↔ `cm`)
stay decimal. A conversion factor that is a `Rational{Int}` promotes the value
to `Rational` — exact, never throwing, never silently rounding. There is
deliberately no `*(Decimal, Rational) → Decimal` closure rule, because that
would force rounding inside a library users chose for correctness. Convert back
at the end if the result must be decimal.

### The two known failures

Both are upstream requirements, and both fail identically for `Rational`:

1. **`StatsBase.summarystats` / `describe`** requires `AbstractFloat` input.
   `summarystats(float.(v))` is the answer.
2. **Adaptive ODE solvers** (`Tsit5()` and friends). SciML documents that
   adaptive time types must be floating point, and adaptivity uses `NaN` as a
   reject-step sentinel, which no exact type has. Non-adaptive solvers with
   exactly-representable coefficients — `Euler()` with `dt = dec"0.1"` — work,
   and are *exact*. For anything adaptive, `solve(remake(prob, u0=float.(u0)), …)`.

More broadly, the domains where conversion to float is automatic are
`eigvals`/`eigen`/`svd`/Schur, adaptive ODE, JuMP solver internals,
`summarystats`, and plot coordinates. These are not gaps; they are domains
where every comparable system converts, documented rather than papered over.

## Performance notes

The kernel-level results carry through generic code: `sum`, `mean`, and
broadcast over million-element columns stay allocation-free with the SIMD paths
engaged; DataFrames `groupby`/`join` hit the `decompose`-based hash without
falling back to `BigInt`; sorting is a comparison on the unscaled integer.

The one thing to keep in mind is the checked-`+` cost in a hand-written
reduction over a narrow type — `sum` sidesteps it by widening to a tier where
overflow is provably impossible, but a custom `reduce(+, v)` cannot. That is
the price of never wrapping, and it is usually the right trade.
