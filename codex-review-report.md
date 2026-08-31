# Decimals.jl adversarial review report

Review scope: milestones M0-M2 at original head `027f97f`, through final reviewed
code on branch `codex/review-m0-m2`. All fixes are local. Nothing was pushed.

## Fixed findings

1. **Critical - wide remainder comparison could overflow.**
   `src/conversions.jl:9` doubled a `UInt256` remainder to classify half values.
   Values above `2^255` wrapped and selected the wrong rounding result. I changed
   the comparison to use `r` versus `d - r` and added a wide-divisor regression.

2. **Critical - parsed coefficients could wrap through `Int256`.**
   `src/show.jl:129` converted an unsigned parsed magnitude to signed storage
   before checking its range. Large positive values could become negative. I
   kept the coefficient unsigned through rescaling and final sign-aware checks.

3. **High - fixed-scale string constructors rounded inexact input.**
   `src/show.jl:129` used the explicit-rounding rescale path. For example, an
   input with excess fractional digits was silently rounded. I routed parsing
   through the exact-or-throw path and added `InexactError` regressions.

4. **High - large rational rounding was bounded by `UInt256`.**
   `src/conversions.jl:75` narrowed arbitrary-precision numerators and
   denominators before division. I kept both in `BigInt` on the cold path and
   rounded the exact quotient.

5. **High - high-precision float input used a bounded decomposition path.**
   `src/conversions.jl:108` forced `BigFloat` decompositions through `UInt256`.
   The positive-exponent cold path also applied decimal scaling before the
   binary shift at `src/conversions.jl:144`. I routed `BigInt` decompositions to
   the arbitrary-precision path and fixed the operation order.

6. **High - decimal-to-float conversion double-rounded subnormals.**
   `src/conversions.jl:383` previously rounded through an intermediate value.
   I now round the exact rational value directly at the target IEEE spacing for
   `Float16`, `Float32`, and `Float64`.

7. **High - `BigFloat(decimal)` lost precision through a narrow fallback.**
   `src/conversions.jl:413` now builds exact MPFR numerator and denominator
   operands, then divides once at the requested precision and rounding mode.

8. **High - `DecimalValue` rejected or mishandled the negative storage limit.**
   Sign-blind magnitude checks excluded `typemin(T)` across construction,
   rescaling, parsing, multiplication, division, and hashing. I added the
   sign-aware limit helper at `src/round.jl:63` and used it across all paths.

9. **High - unary operations could wrap `DecimalValue(typemin(T), scale)`.**
   `src/types.jl:149` and `src/types.jl:156` now throw `OverflowError` for
   unrepresentable `abs` and unary-negation results.

10. **High - rational output narrowed before reduction.**
    `src/conversions.jl:360` converted the power-of-ten denominator to the
    requested integer type before cancelling common factors. It also bounded
    runtime-scale output to the fixed 76-digit table. I build and reduce in
    `BigInt`, then narrow the reduced numerator and denominator. Unqualified
    `Rational(DecimalValue)` now uses `Rational{BigInt}`.

11. **Medium - partial fixed target parsing recursed through `tryparse`.**
    `src/show.jl:135` now resolves `Decimal{P,S}` to its storage tier directly.
    This removes the stack overflow and preserves the exact parsing contract.

12. **Medium - widest-tier identities were incomplete.**
    `src/types.jl:32` lacked idempotent `Int256` widening, and
    `src/types.jl:128` lacked the runtime-scale representational quantum. I
    defined both and added widest-tier regressions.

13. **Medium - unsigned integer promotion could select an invalid storage type.**
    The `DecimalValue` rule at `src/conversions.jl:481` could produce unsigned
    storage, which violates the type constraint. It now selects the smallest
    supported signed tier and caps the result at `Int256`.

14. **Medium - fixed decimals omitted `UInt256` promotion.**
    `src/conversions.jl:462` supported `UInt256` construction, comparison, and
    multiplication but not promotion-based arithmetic. I added it to the
    capped 76-digit promotion rule.

15. **Medium - `BigInt` arithmetic dispatch was incomplete.**
    The package could compare with `BigInt` but could not reliably add or
    multiply one. I added widest-tier promotion at `src/conversions.jl:467` and
    checked cold multiplication paths at `src/arithmetic.jl:240` and
    `src/arithmetic.jl:257`.

16. **Medium - runtime-scale rounding methods were missing.**
    `round`, `trunc`, `floor`, and `ceil` failed for `DecimalValue`. I added
    scale-preserving checked implementations at `src/arithmetic.jl:289`.

17. **Medium - mixed fixed/runtime explicit division was missing.**
    `divide(Decimal, DecimalValue, mode)` and its reverse had no method. I route
    both through value-preserving promotion at `src/arithmetic.jl:492`.

18. **Medium - rational rounding methods were ambiguous with Base.**
    The broad source parameter intersected Base's rational methods, including a
    separate `Rational{Bool}` intersection. I added exact source signatures at
    `src/conversions.jl:281`. Final Base ambiguity detection reports zero.

19. **Medium - extreme scale requests produced incidental exceptions.**
    `rescale(DecimalValue, scale)` accepted targets outside `0:16383`, and very
    negative `digits` values could wrap an `Int` shift or index a table. I added
    target validation at `src/conversions.jl:315` and a saturating shift helper
    at `src/arithmetic.jl:268`.

20. **Medium - integer quotient and remainder APIs were absent.**
    `div`, `rem`, `mod`, and `divrem` failed, which also broke ordinary decimal
    ranges. I added exact one-division implementations for both decimal types
    at `src/arithmetic.jl:107` and `src/arithmetic.jl:376`. Quotient and
    remainder construction are independent, so overflow of one does not reject
    a valid result from the other. All seven rounding modes have regressions.

21. **Medium - Julia 1.12 same-type `fld` and `cld` compatibility was missing.**
    Base deliberately throws for a custom same-type `Real` unless it supplies
    adapters. This also broke `fld1` and `fldmod1`. I added fixed-scale adapters
    at `src/arithmetic.jl:155` and runtime-scale adapters at
    `src/arithmetic.jl:461`.

22. **Medium - `tryparse` swallowed unexpected implementation failures.**
    `src/show.jl:152` converted every exception except an interrupt to
    `nothing`. It now catches only invalid, inexact, and out-of-range input
    errors, and rethrows other failures.

23. **Low - typed wide representations were not self-contained.**
    `repr` printed bare `Int256`, which was not in scope after `using Decimals`.
    `src/show.jl:27` now prints `Decimals.Int256`; clean-module round trips pass.

24. **Low - fixed decimal extrema omitted `floatmin` and `floatmax`.**
    I defined the fixed-point contracts at `src/types.jl:130`: `floatmin` is the
    representational quantum and `floatmax` is `typemax`.

25. **Low - the parser accepted only two of the six standard ASCII spaces.**
    `src/show.jl:63` now accepts tab, line feed, vertical tab, form feed,
    carriage return, and space at input boundaries.

26. **Low - the test suite overwrote its oracle method.**
    `test/arithmetic.jl:7` reused the type-suite method name. This emitted a
    method-overwrite warning and could hide future fixture differences. I gave
    the arithmetic oracle a distinct name. The full suite is warning-free.

## Assumptions

- `reinterpret` remains an unchecked raw constructor. Its invariant is the
  caller's contract.
- Arbitrary-precision work remains acceptable only on documented cold paths.
- `DecimalValue{T}(x::AbstractFloat)` remains exact-or-throw. A high-precision
  value such as binary `BigFloat("0.1")` can correctly overflow `Int256`.
- Registration, documentation, CI scaffolding, and wire integrations remain
  out of scope.

## Decisions made without user direction

- `div` returns an integer-valued result in the promoted decimal type. This is
  consistent with Julia fixed-point behavior and preserves scale.
- Runtime quotient and remainder results use the maximum operand scale, which
  matches the existing runtime division contract.
- Parser whitespace follows Base's ASCII numeric whitespace behavior. I did
  not add a Unicode-normalization layer to the simple M1 parser.
- I used `Test.detect_ambiguities` instead of adding Aqua as a test dependency.
- I left the public export surface unchanged because the named exports are part
  of the supplied package design.

## Validation

- `julia --startup-file=no --project=. -e 'using Pkg; Pkg.test()'`:
  **697,886 passed, 0 failed, 0 errored** on Julia 1.12.6.
- `Test.detect_ambiguities(Decimals, Base; recursive=true)`: **0 ambiguities**.
- Independent full-width quotient/remainder differential checks:
  **16,000 cases passed** across `Int32`, `Int64`, `Int128`, and `Int256`.
- Independent Knuth `UInt256` division differential checks:
  **200,000 cases passed** against `BigInt`.
- Independent subnormal conversion checks:
  **2,000 cases per target float type passed** against exact/MPFR oracles.
- Hot fixed-scale arithmetic, runtime arithmetic, quotient/remainder, rescale,
  and cross-scale comparison checks report **0 allocations**.
- `git diff --check` passes. All 23 implementation and test commits contain the
  required `Co-Authored-By: Codex <codex@openai.com>` trailer.
- User-owned untracked files `codex-review-prompt.md` and `codex-run.log` were
  not modified.

VERDICT: CLEAN
