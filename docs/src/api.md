# API Reference

```@meta
CurrentModule = Decimals
```

## Types

```@docs
Decimals.AbstractDecimal
Decimal
DecimalValue
Decimal32
Decimal64
Decimal128
Decimal256
```

## Literals

```@docs
@dec_str
```

## Rounding and rescaling

```@docs
rescale
divide
Decimals.normalize
```

## Wire and byte-level API

```@docs
Decimals.unscaled
Decimals.scale
Decimals.decimallength
Decimals.writedecimal!
```

## Base methods

These `Base` functions have methods for the decimal types; they are documented
by `Base` and behave as described in [Semantics](@ref).

Construction and conversion
: `convert`, `reinterpret`, `parse` and `tryparse` (via the Parsers extension), `promote_rule`,
  `Float64` / `Float32` / `Float16` / `BigFloat` / `AbstractFloat`, `Rational`,
  `Integer` and the concrete integer types, `big`, `rationalize`, `widen`.

Arithmetic
: `+`, `-`, `*`, `/`, `div`, `rem`, `mod`, `fld`, `cld`, `divrem`, `sum`,
  `abs`, `Base.Checked.checked_add` / `checked_sub` / `checked_mul` /
  `checked_neg` / `checked_abs`.

Rounding
: `round`, `trunc`, `floor`, `ceil` — both the in-type forms (with a `digits`
  keyword) and the converting forms `round(T, x, mode)`.

Comparison and hashing
: `==`, `<`, `<=`, `isless`, `Base.decompose`, `hash`, `signbit`, `iszero`,
  `isinteger`, `isfinite`, `isnan`, `isinf`.

Type traits and constants
: `zero`, `one`, `eps`, `typemin`, `typemax`, `floatmin`, `floatmax`,
  `precision`.

Text
: `string`, `print`, `show`.

Other
: `Random.rand` (uniform on `[0, 1)` at the type's scale), and broadcast
  kernels for elementwise `+`, `-`, `*` over vectors.

## Extension entry points

Available when the corresponding package is loaded; see
[Extensions](@ref) in the manual.

`Parsers.parse`, `Parsers.tryparse`, `Parsers.parsenext`
: byte-level parsing with `decimal=` and `rounding=` keywords (Parsers 3).

`Printf.tofloat`, `Printf.toint`
: exact `%f` / `%e` / `%g` and exact-or-`InexactError` `%d`.

`JSON.tostring`
: raw exact-digit JSON numbers (JSON 1.x).

`LinearAlgebra` factorizations
: `lu`, `cholesky`, `qr`, `svd`, `eigen`, `hessenberg`, `schur`, `lq`, `det`,
  `logdet`, `inv`, `eigvals`, `svdvals`, `cond`, `nullspace`, `pinv`, `rank`
  route through `float(A)`.

## Index

```@index
```
