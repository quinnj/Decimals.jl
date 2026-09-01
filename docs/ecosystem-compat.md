# Ecosystem compatibility: `Decimal`/`DecimalValue` across the Julia stack

*August 2026. The question this answers: when Arrow/Postgres/MySQL/CSV start
returning these types, and users take them into DataFrames, Statistics,
Plots, JuMP, DiffEq, Unitful, JSON, etc. — where are the rough edges,
MethodErrors, silent-precision losses, and perf dropoffs?*

**Method.** Three inputs: (1) a 117-trial live gauntlet exercising 16
ecosystem areas against the real packages (DataFrames 1.8, Statistics,
StatsBase 0.34, Distributions, ForwardDiff, OrdinaryDiffEq, JuMP, Unitful
1.28, StaticArrays, JSON, plus targeted landmine probes); (2) an
instrumented-probe study of the *implicit* `Real` interface — a minimal
`<: Real` type logging every method Base/stdlib generic machinery calls per
operation, cross-checked against Julia 1.12.6 source and the scar tissue of
DecFP.jl, FixedPointDecimals.jl, Unitful.jl, SaferIntegers.jl, and
Rational; (3) a cross-system semantics survey (PostgreSQL, DuckDB, SQL
Server, Spark, DataFusion, Arrow C++, NumPy/pandas, Python `decimal`,
simplejson) for every operation where "what *should* this return"
has more than one defensible answer.

**Bottom line: 115/117 gauntlet trials pass.** The two failures are
inherent to the downstream packages, fail identically for `Rational`
(Base's own exact type), and are documented below with the recommended
escape hatch. Every item in the 25-point "maximally compatible custom Real"
checklist distilled from the interface study is implemented, except two
deliberate policy choices and one backlog item, all called out below.

---

## 1. What just works (gauntlet evidence)

| Area (trials) | Status | Notes |
|---|---|---|
| Base numerics (28) | ✅ | `sqrt/hypot/log/exp` → Float64 (Rational precedent: `sqrt(4//1) == 2.0`); `float`, `isapprox`, `round` families, `divrem`, `^`, `muladd`, `clamp`, `widen`, `eps`, `typemin/typemax` |
| Collections (11) | ✅ | `Dict`/`Set`/`unique`/`sort`/`searchsorted`/`extrema`/`findmax`; hash agrees with `Int`/`Float64`/`Rational` across types (decompose-based) |
| Ranges (5) | ✅ | `a:s:b`, `a:b`, `range(; step/length)`, getindex, `in`, `searchsortedfirst` — the generic `StepRange` path; TwicePrecision is float-gated and never engages (where Unitful bled for years) |
| DataFrames (6) | ✅ | `groupby` (both the all-integral fast path — needs `isinteger`/`BigInt`/`Int`/`x-Int`, and the hash path), 4 join types, `combine`, sort-with-missing, display |
| Statistics (8) | ✅ | `mean/var/std/median/quantile/middle/cor/cov` — semantics in §3 |
| StatsBase (4) | ⚠️ 3/4 | histogram fit, `ecdf`, `skewness` work; `summarystats` requires `AbstractFloat` — fails identically for `Rational` (upstream design) |
| LinearAlgebra (18) | ✅ | matmul/`dot`/`tr`/`+` exact; factorizations route through `float` (§4) |
| Random (3) | ✅ | `rand(D)` uniform [0,1) at scale via SamplerType hook; vector/range sampling |
| ForwardDiff (3) | ✅ | `derivative(x->x^2+3x, d)` exact in-type (Duals of Decimal); float-free polynomial ADs stay exact |
| DiffEq (2) | ⚠️ 1/2 | non-adaptive exact-coefficient solves (Euler, fixed dt) work; adaptive solvers (Tsit5) need float time/tolerances — SciML-documented restriction, `Rational` fails the same way |
| JuMP (2) | ✅ | Decimal coefficients convert cleanly into `Model` (Float64) and `GenericModel{Float64}` builds |
| Unitful (7) | ✅ | `Quantity{Decimal}` arithmetic, integer-factor `uconvert` stays decimal; rational factors promote to `Rational` (exact, never throws — kept, §5) |
| StaticArrays (2) | ✅ | `SVector` arithmetic/`dot` exact |
| JSON (2) | ✅ | raw exact-digit JSON numbers via ext (§6) |
| Landmines (10) | ✅ | `-0.0` isequal probes, empty-range dead-branch arithmetic (SaferIntegers#26 class), promotion round-trips, `Bool` conversion in matmul, mixed-type comparisons vs floats too wide for Float64 |
| Perf probes (6) | ✅ | reductions/broadcast on 10⁶ elements allocation-free; SIMD sum specialization intact through the ecosystem paths |

The two ⚠️ items are the *only* failures, both inherent upstream:

1. **`StatsBase.summarystats` / `describe`** requires `AbstractFloat`
   input. `summarystats(float.(v))` is the answer.
   (`Rational` fails identically.)
2. **Adaptive ODE solvers** (`Tsit5()` etc.). SciML documents that adaptive
   time types must be floating point; adaptivity also uses NaN as a
   reject-step sentinel, which no exact type has. Non-adaptive solvers with
   exactly-representable coefficients (e.g. `Euler(), dt=dec"0.1"`) work —
   and are *exact*. For anything adaptive: `solve(remake(prob, u0=float.(u0)), ...)`.

## 2. The implicit `Real` interface — checklist coverage

The instrumented-probe study produced a 25-item checklist of what Base and
the ecosystem *actually call* on a custom Real (with the load-bearing
fallback chains: `Base.decompose` → hash/isfinite/Rational-compare;
`Base.AbstractFloat` → `float(x)`/`float(T)`/norm/plots/histograms; the
`T(::T)` identity constructor → range getindex/oneunit/DiffEq; `<` not
`isless` — Base derives isless *from* `<` for Reals). Our coverage:

| Tier | Items | Status |
|---|---|---|
| 0 — existence | `T(::T)`, Int/Float64/Bool/Rational construction+convert, promote rules, `==`/`<` (exact cross-type vs floats, not promote-and-pray), show/parse/tryparse, `Base.decompose`, `AbstractFloat`/`Float64`/`Float32` | ✅ all (decompose batched 5-strip; float conversions correctly rounded, never double-rounded) |
| 1 — arithmetic protocol | `+ - * /` (checked), `abs/abs2/sign/signbit`, `zero/one/oneunit`, `iszero/isone`, `isfinite/isnan/isinf/isinteger` (explicit + fast), `inv`, `muladd`, `sqrt`→Float64, `min/max/clamp` | ✅ all |
| 2 — ranges | `rem/div/mod/fld/cld`, `round(x, ::RoundingMode)`, `Integer/Int/BigInt` conversion | ✅ all |
| 3 — text/serialization | `round(; digits)` staying exact (Base's fallback silently returns Float64!), `Printf.tofloat`, JSON `tostring` | ✅ all (§6) |
| 4 — statistics polish | `/(T, Int)` semantics (§3), `eps`, `typemin/typemax/widen` | ✅ all |
| 5 — opt-in hooks | `Random.rand` sampler ✅; `Base.checked_*` aliases ✅; Unitful closure rules — deliberate policy (§5); Plots/Makie type recipes — **backlog** (works today via the Float64 path; a recipe adds exact-digit *tick labels*, cosmetic) |

Two deliberate non-defaults, both matching `Rational` precedent:

- **`≈` is exact equality** (`rtoldefault = 0` for non-AbstractFloat
  Reals). Arguably correct for money; users can pass `rtol`/`atol`.
- **No `NaN`/`Inf` values** — `isnan` is always `false`, `isfinite` always
  `true`; operations that would produce them throw instead.

## 3. Semantics: what analytics operations return, and why

For every contested operation we surveyed what SQL engines, Arrow, Spark,
pandas, and Julia's own exact type (`Rational`) do. Decisions:

| Operation | Ours | Precedent |
|---|---|---|
| `sum` | exact decimal, auto-widened to the Int128 tier (SIMD where provably safe) | universal: every engine widens sum at fixed scale (PG `numeric`, DuckDB `DECIMAL(38,s)`, Spark `p+10`); wrapping corrupts (FixedPointDecimals `sum` returns garbage silently), checked-throw without widening trips on real data |
| `mean` | same-scale decimal, half-even rounded | the Arrow C++ camp. The alternative camps: raise scale (PG/Spark/SQL Server `s+4`) or go DOUBLE (DuckDB). Rounding at the input's own scale is visible, deterministic, and type-stable; `mean(float.(v))` is one call away. Revisit if it bites. |
| `var`/`std`, `skewness`/`kurtosis` | Float64 | near-universal (DOUBLE everywhere except PG); `std(::Vector{Rational})::Float64` in Base |
| `median`/`middle` | decimal (rounds only if the midpoint needs an extra digit) | DuckDB: `median(DECIMAL(10,2)) → DECIMAL(10,2)` |
| `quantile(v, p::Float64)` | Float64 (float `p` contaminates); exact `p::Rational` stays exact | exactly `Rational`'s behavior in Base |
| `norm`/`hypot`/`sqrt`/`exp`/`log`/trig | Float64 | settled Base convention (`norm([3//1,4//1]) == 5.0`; Unitful PR#500 adopted it too). Don't fight it. |
| `lu`/`det`/`inv`/`\`/factorizations | route through `float(A)` (§4) | — |
| overflow anywhere | **throw `OverflowError`**, never wrap, never silently round `+`/`-`/`*` | `Rational` is Base's proof this is sanctioned citizen behavior; FixedPointDecimals is the proof wrapping isn't |

## 4. LinearAlgebra: exact where exact is honest, float where it isn't

`A*B`, `dot`, `tr`, `A+B`, `kron` stay exact (widening product types via
`promote_op`). Factorizations (`lu`, `cholesky`, `qr`, `svd`, `eigen`,
`det`, `inv`, `\`, `nullspace`, `pinv`, `cond`, …) **convert to Float64
first** via `DecimalsLinearAlgebraExt`. Rationale, validated three ways:

- Generic `lu!` on a fixed-scale decimal either throws `InexactError`
  mid-elimination or — worse — *silently corrupts* (we measured
  `det = -2.0004` for a matrix whose true determinant is `-2`): every
  elimination step rounds at scale, and pivoting decisions compound it.
- No system in our survey runs LAPACK-style algorithms in fixed decimal;
  eigensolvers are float-only even for DecFP (whose maintainers point users
  at Float64/GenericLinearAlgebra — eigenvalues carry roundoff regardless,
  decimal exactness buys nothing there).
- `Rational`'s exact `lu` works only because Rational grows unboundedly;
  a fixed-scale type cannot honestly claim exact elimination.

Users who want generic-precision factorizations can still get them
explicitly: `lu(Rational.(A))` (exact) or GenericLinearAlgebra.jl over
`big.(A)`.

## 5. Unitful

`Quantity{Decimal}` arithmetic and integer-factor conversions
(`m ↔ cm`, etc.) stay decimal. Conversion factors that are
`Rational{Int}` promote the value to `Rational` — **exact, never throws,
never silently rounds**; we deliberately do *not* define
`*(Decimal, Rational) → Decimal` closure rules, because that would force
rounding inside a units library that users chose for correctness. If the
result must be decimal, `convert` back at the end (exact-or-throw).

## 6. Text and serialization exactness

- `print`/`string`: plain positional digits, always round-trippable;
  MIME `show` switches to scientific notation past 44 characters.
- `parse`/`tryparse`: round half-even (float-parse precedent), with
  `rounding=` control in the Parsers extension; parsing beats
  rust_decimal on our benchmarks.
- `round(x; digits=n)`: exact, in-type (Base's generic fallback returns
  Float64 — a documented wart for `Rational` that we override away).
- **Printf** (`DecimalsPrintfExt`): `%d` behaves like `Rational`'s
  (exact-or-InexactError); `%f/%e/%g` route through a 1024-bit `BigFloat`
  instead of the default `Float64(x)`, so all 78 possible digits print
  exactly. (DecFP shipped Float64-rounded `@printf` output for years
  before growing the same hook.)
- **JSON** (`DecimalsJSONExt`, JSON 1.x only): decimals emit as **raw
  exact-digit JSON numbers** via the documented `JSON.tostring` hook
  (the industry precedent: simplejson, PG/DuckDB JSON export; the
  default Julia path stringifies `Float64(x)`, silently rounding
  anything past 17 significant digits). Verified against JSON 1.7.1.
  *Note:* JSON 1.x still pins Parsers 1–2, so it can't share an
  environment with Parsers 3; Decimals' Parsers extension loads as a
  no-op under Parsers 2 so the pairing resolves, and the in-suite JSON
  tests (test/json.jl) activate once JSON gains Parsers 3 compat.
- JSON3: unknown Reals stringify via Float64. Overriding needs a
  `JSON3`/`StructTypes` weakdep; deferred until someone asks (JSON.jl v1
  is the going-forward line).

## 7. Documented "convert to float" domains

These are not gaps; they're domains where every comparable system
converts, and we document rather than pretend:

| Domain | Why | Escape hatch |
|---|---|---|
| `eigvals`/`eigen`/`svd`/Schur | LAPACK-only by stdlib design; roundoff inherent | automatic via our LA ext (`float(A)`) |
| Adaptive ODE | float tolerances/`eps`/NaN-sentinel stepping (SciML-documented) | `float.(u0)`; fixed-step stays exact |
| JuMP nonlinear / solver internals | solvers are Float64 (or Rational/BigFloat for exact LP) | coefficients auto-convert; use `Rational` if exactness is the point |
| `summarystats`/`describe` | upstream `AbstractFloat` requirement | `summarystats(float.(v))` |
| Plot coordinates | Plots/Makie pipelines are Float64 by design | automatic; exact tick *labels* = backlog type recipe |

## 8. Performance through ecosystem paths

The gauntlet's perf probes confirm the kernel-level results carry through
generic code: `sum`/`mean`/broadcast over 10⁶-element columns stay
allocation-free with the SIMD paths engaged; DataFrames groupby/join hit
the decompose-based hash without falling to `BigInt`; sort is pure `<` on
the unscaled integer. One perf note to keep: checked `+` in a *naive*
`reduce` defeats SIMD (the SaferIntegers lesson) — our `sum` sidesteps it
by widening to the Int128 tier where overflow is provably impossible and
summing unchecked; custom user reductions in narrow types will see the
checked-op cost, which is the price of never wrapping.
