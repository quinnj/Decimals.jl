# Decimals.jl

Exact fixed-point decimal numbers for Julia.

[`Decimal{P,S,T}`](@ref Decimal) is an isbits value holding one integer
coefficient, with the precision `P` and scale `S` fixed in the type. That is
the same `(precision, scale, storage width)` description Arrow, Parquet,
DuckDB, PostgreSQL, and MySQL use for a decimal column, so a
`Vector{Decimal{18,2,Int64}}` already has the layout of a decimal column
buffer and needs no per-element conversion at a format boundary.

Arithmetic is exact and checked. `+`, `-`, and `*` neither round nor wrap;
they throw `OverflowError` when a result does not fit. Where rounding is
unavoidable it takes a `RoundingMode` argument at the call site, rather than
reading a global context.

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

## Where to go next

- [Manual](@ref) covers choosing a type, constructing values, arithmetic,
  rounding, printing, the wire API, and the package extensions.
- [Semantics](@ref) states the rules for every operation, and what the
  ecosystem study found when these types were taken through DataFrames,
  Statistics, LinearAlgebra, and their neighbours.
- [Migration from 0.x](@ref) lists what changed from the 0.x `Decimals`
  package, with replacements for the old API.
- [API Reference](@ref) lists every exported and public name.

## Further reading in the repository

- `bench/PERF.md`: benchmark method and results, with charts in
  `bench/charts/`.
- `docs/ecosystem-compat.md`: behaviour across the Julia package ecosystem.
- `docs/comparison-with-0.5.1.md`: API comparison with `Decimals` 0.5.1.

Licensed under the MIT License.
