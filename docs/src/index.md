# Decimals.jl

Exact fixed-point decimals for Julia, shaped like the ones the data-systems
world already speaks.

[`Decimal{P,S,T}`](@ref Decimal) is an isbits value whose numeric content is an
integer coefficient and a decimal scale — the same `(precision, scale, storage
width)` triple Arrow, Parquet, DuckDB, PostgreSQL, and MySQL use — so a
`Vector{Decimal{18,2,Int64}}` is byte-identical to a decimal column buffer and
crosses the wire without a conversion pass. Arithmetic is exact and *checked*:
`+`, `-`, `*` never silently round and never wrap, and every place where
rounding is unavoidable takes an explicit `RoundingMode` argument rather than
reading a global context.

It is pure Julia with one small dependency, and it is fast: 8.4 ns to parse a
money string (rust_decimal 7.6, DecFP 25.5), 1.75 ns to multiply, 6.7 ns to
divide, and 0.165 ms to sum a million values.

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
normalize(dec"1.2000")                 # 1.2 :: DecimalValue{Int32}

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

## Where to go next

- [Manual](@ref) — choosing a type, constructing values, arithmetic,
  rounding, printing, the wire API, and the package extensions.
- [Semantics](@ref) — the exact rules for every operation, and what the
  ecosystem study found when these types were taken through DataFrames,
  Statistics, LinearAlgebra, and friends.
- [Migration from 0.x](@ref) — what changed from the 0.x `Decimals` package
  and why, with replacements for the old API.
- [API Reference](@ref) — every exported and public name.

## Project links

- Benchmark methodology and full results: `bench/RESULTS.md` and
  `bench/SWEEP.md` in the repository.
- Ecosystem gauntlet report: `docs/ecosystem-compat.md`.
- API audit against the 0.x package: `docs/registered-decimals-audit.md`.

Licensed under the MIT License.
