# Decimals maintenance

Read `docs/src/semantics.md` before changing arithmetic or promotion. Read
`docs/src/manual.md#integration-boundaries` before changing a wire adapter.

- Preserve `value = unscaled * 10^-scale`. Fixed values also require
  `abs(unscaled) < 10^precision`.
- Keep integer, rational, and decimal conversions exact or throwing. Float
  and string inputs round as documented. Rounding has no global state.
- Test optimized array paths against scalar behavior, including exceptions.
- Test parsing against the independent core scanner or a BigInt oracle.
- Test equality, hashing, and total ordering together across numeric types.
- Keep exports limited to `Decimal`, `Decimal64`, and `@dec_str`. Import other names explicitly.
- Reproduce each bug with a public API test before changing its implementation.

Run `julia --project -e 'using Pkg; Pkg.test()'` on Julia 1.10 and a current
stable Julia. The main test environment requires Parsers 3. JSON runs separately:

```sh
julia --project=test/json -e 'using Pkg; Pkg.develop(path=pwd()); Pkg.instantiate()'
julia --project=test/json test/json/runtests.jl
julia --project=docs -e 'using Pkg; Pkg.develop(path=pwd()); Pkg.instantiate()'
julia --project=docs docs/make.jl
```

The trim workload runs on supported Julia versions by default. Use
`DECIMALS_RUN_TRIM_TESTS=0` for an initial arithmetic-only pass, then run the
trim workload before reporting release readiness.

For downstream usage guidance, read `SKILL.md`. Historical benchmark and
ecosystem results are in `bench/PERF.md` and `docs/ecosystem-compat.md`; refresh
their evidence before treating them as results for a changed commit.
