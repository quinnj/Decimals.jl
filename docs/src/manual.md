# Manual

## Choosing a type

There are two value types, and the choice between them is about where the
scale lives.

[`Decimal{P,S,T}`](@ref Decimal) puts the scale in the type. It holds one
field, `unscaled::T`, and means `unscaled * 10^-S` with the invariant
`|unscaled| < 10^P`. `P` is the precision (total decimal digits), `S` the
scale (fractional digits, `0 <= S <= P`), and `T` the storage integer.
A vector stores coefficients contiguously. Arrow buffers with the same width
and host byte order can share this layout. Parquet byte arrays use big-endian
two's-complement coefficients and require encoding. DuckDB uses 16/32/64/128-bit
storage for precisions up to 4/9/18/38; it has no 256-bit decimal tier.
See the [Arrow format](https://arrow.apache.org/docs/format/Columnar.html),
[Parquet decimal specification](https://github.com/apache/parquet-format/blob/master/LogicalTypes.md#decimal),
and [DuckDB numeric types](https://duckdb.org/docs/stable/sql/data_types/numeric).

Four aliases name this package's storage tiers at their maximum precision:

| alias | expands to | digits | storage | typical use |
|---|---|---|---|---|
| [`Decimals.Decimal32{S}`](@ref Decimals.Decimal32) | `Decimal{9,S,Int32}` | 9 | 32-bit | narrow Arrow/Parquet columns |
| [`Decimals.Decimal64{S}`](@ref Decimals.Decimal64) | `Decimal{18,S,Int64}` | 18 | 64-bit | money, most SQL `DECIMAL` |
| [`Decimals.Decimal128{S}`](@ref Decimals.Decimal128) | `Decimal{38,S,Int128}` | 38 | 128-bit | DuckDB/Spark default width |
| [`Decimals.Decimal256{S}`](@ref Decimals.Decimal256) | `Decimal{76,S,Decimals.Int256}` | 76 | 256-bit | Arrow `Decimals.Decimal256` |

Write `Decimal{P,S}` when a schema pins a precision narrower than its tier's
maximum: `Decimal{7,2}` accepts fewer digits than `Decimals.Decimal32{2}` before
throwing, though both store an `Int32`. The storage type is filled in from
`P` whenever you leave it off, so `Decimal{9,2}` is another spelling of
`Decimals.Decimal32{2}`.

[`Decimals.DecimalValue{T}`](@ref Decimals.DecimalValue) is the runtime-scale sibling: it
stores the scale (an `Int32` in `0:16383`) alongside the coefficient. Use it
when the scale travels with each value rather than with the column, as with a
PostgreSQL `numeric`'s per-value dscale, a value whose scale is not known
until run time, or the result of [`Decimals.normalize`](@ref). It is still
isbits, but it is a word wider and its arithmetic has to align scales at run
time, so `Decimal{P,S}` is the better default for columnar data.

Both are subtypes of `Decimals.AbstractDecimal <: Real`. There is no
`AbstractFloat` subtyping, and there are no `NaN` or `Inf` values: `isnan` is
always `false`, `isfinite` always `true`, and an operation that would produce
a non-value throws.

## Constructing values

```julia
dec"1.25"                          # literal, minimal fitting type
dec"1_000_000.25"                  # underscores allowed between digit groups
dec"1.5e-3"                        # exponents fold into the scale

Decimals.Decimal64{2}("1234.56")            # from a string (exact core scanner)
using Parsers                      # parse/tryparse come from the Parsers extension
parse(Decimals.Decimal64{2}, "1234.567")    # 1234.57, rounds half-even at the target scale
tryparse(Decimals.Decimal64{2}, "nope")     # nothing

Decimals.Decimal64{2}(5)                    # from an Integer: exact or throws
Decimals.Decimal64{2}(1//4)                 # from a Rational: exact or throws
Decimals.Decimal64{2}(0.1)                  # from a Float: rounds half-even at scale 2

reinterpret(Decimals.Decimal64{2}, 123456)  # from an unscaled coefficient, unchecked
```

The rule is exact-or-throw, with two documented exceptions. Construction from
an `AbstractFloat` rounds half-even at the target scale, as cross-representation
float conversions in Base do; a `Decimals.DecimalValue` built from a float instead keeps
the exact binary expansion, which is what a runtime scale is for:

```julia
Decimals.Decimal64{2}(0.1)   # 0.10
Decimals.DecimalValue(0.1)   # 0.1000000000000000055511151231257827021181583404541015625
```

String construction and `parse` also round half-even at the target scale.
`convert(D, x)` follows the numeric constructor: float sources round, while
integer, rational, and decimal sources are exact or throw. Use an exact string
literal or rational source when binary float rounding is not intended.

[`@dec_str`](@ref) produces the minimal type that fits the literal, so
`dec"1.25"` is a `Decimal{3,2,Int32}` and not a money type. That suits a
constant in an expression, where it promotes to whatever the other operand
needs; annotate the type explicitly for a column.

`reinterpret` is the zero-copy path: it builds a value directly from an
unscaled coefficient without checking the `|u| < 10^P` invariant, because in
a wire decode the invariant is the producer's contract and re-checking it per
element is the cost being avoided.

## Arithmetic

`+` and `-` promote both operands value-preservingly and then compute
checked: a result that no longer fits throws `OverflowError`. They never wrap
and never silently round.

```julia
Decimals.Decimal64{2}("1.20") + Decimals.Decimal64{2}("0.05")    # 1.25  :: Decimal{18,2,Int64}
typemax(Decimals.Decimal64{2}) + Decimals.Decimal64{2}("1.00")   # OverflowError
```

`*` is exact: the result has scale `S1 + S2` and precision `min(P1 + P2, 76)`.
Multiplying by a plain `Integer` is scale-preserving instead, because
multiplying by a count should not widen the scale.

```julia
Decimals.Decimal64{2}("1.25") * Decimals.Decimal64{3}("2.500")   # 3.12500 :: Decimal{36,5,Int128}
Decimals.Decimal64{2}("2.50") * 3                       # 7.50    :: Decimal{37,2,Int128}
```

`/` rounds half-even at scale `max(S1, S2)`. [`Decimals.divide`](@ref) is the same
operation with the rounding mode spelled out:

```julia
Decimals.Decimal64{2}("1.00") / Decimals.Decimal64{2}("3.00")                     # 0.33
Decimals.divide(Decimals.Decimal64{2}("1.00"), Decimals.Decimal64{2}("3.00"), RoundUp)     # 0.34
```

`sum` widens to the `Int128` tier, where overflow is provably impossible
below 1.7e20 elements, so the accumulation loop needs no per-element check
and vectorizes while staying safe:

```julia
sum(fill(Decimals.Decimal64{2}("0.10"), 10))    # 1.00 :: Decimal{38,2,Int128}
```

`div`, `rem`, `mod`, `fld`, `cld`, and `divrem` are real implementations
rather than float fallbacks, and take a rounding mode where Base's do.
Elementwise `a .+ b`, `a .- b`, and `a .* b` over same-shaped vectors hit SIMD
kernels that compute per lane and check overflow once for the whole array.

## Rounding

There is no global rounding state in the package. Every rounding decision is
an argument at a call site, and the seven modes accepted are `RoundNearest`
(half-even, the default), `RoundNearestTiesAway`, `RoundNearestTiesUp`,
`RoundToZero`, `RoundFromZero`, `RoundDown`, and `RoundUp`.

```julia
# change the scale of a value
Decimals.rescale(Decimals.Decimal64{2}, Decimals.Decimal64{4}("1.2356"), RoundUp)   # 1.24
Decimals.rescale(Decimals.DecimalValue(12345, 3), 1)                       # 12.3
round(Decimals.Decimal64{2}, 1.005)                               # 1.00 (same thing, Base spelling)

# round within a type
round(Decimals.Decimal64{4}("1.2346"); digits=2)                  # 1.2300
trunc(Decimals.Decimal64{2}("1.99"))                              # 1.00
floor(Decimals.Decimal64{2}("-1.01"))                             # -2.00
ceil(Decimals.Decimal64{2}("1.01"))                               # 2.00

# round out to an integer
round(Int, Decimals.Decimal64{2}("1.50"))                         # 2
floor(Int, Decimals.Decimal64{2}("1.99"))                         # 1
```

`round(x; digits)` stays exact and in-type; Base's generic fallback for a
custom `Real` returns a `Float64`, and that is overridden here. There is no
`sigdigits` keyword, since a fixed-point type has no floating significand.

`convert` between decimal types is the exact-or-throw counterpart of
[`Decimals.rescale`](@ref); reach for `Decimals.rescale` when the intent is "round this into
that scale".

## Comparison and hashing

Equality and ordering are by numeric value, across scales, precisions,
storage types, and other `Real` types. The representation still remembers its
scale, so `string` prints the trailing zeros, but the number does not:

```julia
dec"1.20" == dec"1.2" == 12//10              # true
hash(Decimals.Decimal64{2}("1.25")) == hash(1.25)     # true
sort([dec"3.5", dec"1.25", dec"2.0"])        # works; sorts on the coefficient
```

Hashing goes through `Base.decompose`, so a decimal hashes identically to an
equal `Int`, `Rational`, or `Float64`, which is what makes `Dict` keys,
`unique`, and DataFrames `groupby`/`join` behave.

Between decimals, `≈` is exact equality, because Base's `rtoldefault` is zero
for a non-`AbstractFloat` `Real`. That is the same behaviour `Rational` has,
and it is arguably what money wants; pass `rtol` or `atol` for a tolerance.
Comparing against a `Float64` brings that type's default tolerance with it,
again as for `Rational`.

## Printing and parsing

`string` and `print` always produce the plain positional form, which is a
valid SQL literal, CSV field, and JSON number, and never scientific notation:

```julia
string(Decimals.Decimal64{2}("-12.30"))    # "-12.30"
```

`show`, and therefore `repr`, gives the round-trippable typed form,
`Decimal{18,2,Int64}("-12.30")`. At the REPL, though, values display through
the `text/plain` method, which prints plain digits and only switches to
scientific notation once the positional form passes 44 characters:

```julia-repl
julia> Decimals.Decimal64{2}("1234.56")
1234.56

julia> Decimals.DecimalValue{Decimals.Int256}(123, 50)
1.23E-48
```

`parse` and `tryparse`, defined by the Parsers extension, accept an optional
sign, digits, an optional decimal point, and an optional `e`/`E` exponent,
with surrounding ASCII whitespace allowed. They round half-even into the
target scale. The string constructors (`Decimals.Decimal64{2}("1.25")`) and `dec"..."`
literals use the package's own exact scanner and need no extension.

## The wire API

Four public names cover byte-level interop:

```julia
using Decimals: unscaled, scale, writedecimal!, decimallength

x = Decimals.Decimal64{2}("-1.25")
unscaled(x)                       # -125 :: Int64, what the buffer stores
scale(x)                          # 2
reinterpret(typeof(x), unscaled(x)) === x   # true

decimallength(x)                  # 5, bytes needed, computed without formatting
buf = zeros(UInt8, 16)
pos = writedecimal!(buf, 1, x)    # 6, the position after the written bytes
String(buf[1:pos-1])              # "-1.25"
```

[`writedecimal!`](@ref Decimals.writedecimal!) is the allocation-free
formatter that `string` is built on; it bounds-checks nothing, so reserve
[`decimallength(x)`](@ref Decimals.decimallength) bytes first. Together with
`reinterpret`, this is enough to read and write decimal columns without
materialising an intermediate `String`.

[`Decimals.normalize`](@ref) is the other representation-level tool: it
strips trailing zeros from the coefficient and lowers the scale to match,
returning a `Decimals.DecimalValue`, since the scale is then a property of the value
rather than the type. The number is unchanged; only the digits a wire format
would carry are.

!!! note
    `normalize` is public but not exported, so that it does not collide with
    `LinearAlgebra.normalize`; call it as `Decimals.normalize`.

## Extensions

These load automatically as package extensions when the companion package is
present.

### Parsers.jl

Byte-level `parse`, `tryparse`, and `parsenext` over strings or byte spans,
with `decimal=` and `rounding=` keywords. This is the entry point for a CSV
reader or wire decoder.

```julia
using Decimals, Parsers

Parsers.parse(Decimals.Decimal64{2}, "1234.56")                    # 1234.56
Parsers.parse(Decimals.Decimal64{2}, "1,25"; decimal=',')          # 1.25
Parsers.parse(Decimals.Decimal64{2}, "1.005"; rounding=RoundUp)    # 1.01
Parsers.tryparse(Decimals.Decimal64{2}, "nope")                    # nothing

buf = codeunits("12.34,56.78")
Parsers.parsenext(Decimals.Decimal64{2}, buf, 1, length(buf))      # (12.34, 6, Parsers.RC_OK)
```

`parsenext` returns `(value, nextpos, returncode)` and is the tokenizer entry
point: it stops at the first byte that cannot continue a decimal, so the
caller can step through a delimited line. It requires Parsers 3. Under
Parsers 2 the extension loads as a no-op, so that an environment which also
contains a Parsers-2-pinned package still resolves, and `parse`/`tryparse`
are unavailable until Parsers 3 is (string constructors and literals still
work). The extension also defines `Base.parse`/`Base.tryparse` for decimal
types, so plain `parse(Decimals.Decimal64{2}, s)` is the same code path once Parsers
is loaded.

### Printf.jl

`%f`, `%e`, and `%g` round the decimal value half-even at the requested
precision before conversion to `BigFloat`. Binary precision grows with the
requested output precision. This preserves decimal ties and long output. `%d` is exact-or-`InexactError`, matching `Rational`.

```julia
@printf("%.2f", Decimals.Decimal64{2}("1234.56"))   # 1234.56
@printf("%d", Decimals.Decimal64{2}("1234.00"))     # 1234
@printf("%d", Decimals.Decimal64{2}("1234.56"))     # InexactError
```

### JSON.jl

Decimals serialize as JSON numbers carrying their exact digits, neither as
strings nor `Float64`-rounded (the default path for an unknown `Real`
stringifies `convert(Float64, x)`). Requires JSON 1.x.

```julia
JSON.json((price = Decimals.Decimal64{2}("1234.56"), qty = 3))
# {"price":1234.56,"qty":3}
```

### LinearAlgebra.jl

`A*B`, `dot`, `tr`, `A+B`, and `kron` stay exact decimal, widening the result
type as the product requires. Factorizations, namely `lu`, `cholesky`, `qr`,
`svd`, `eigen`, `hessenberg`, `schur`, `lq`, and the functions built on them
(`det`, `logdet`, `inv`, `eigvals`, `svdvals`, `cond`, `nullspace`, `pinv`,
`rank`), convert to `Float64` first. See [LinearAlgebra](@ref) under
Semantics for why. If you need an exact factorization, `lu(Rational.(A))`
gives one.

## Integration boundaries

Only `Decimal`, `Decimal64`, and `@dec_str` are exported. Other public names use the
`Decimals.` namespace. Explicit imports such as `using Decimals: DecimalValue`
are supported. `sign(x)` returns the storage integer's sign, so it works even
when the decimal type cannot hold 1. Mixing a runtime-scale `DecimalValue`
with a rational promotes to `Rational{BigInt}` so deep scales stay exact.

The fixed family supports `1 <= P <= 76` and `0 <= S <= P`. Arrow schemas can
carry negative scales or scales above their precision; those schemas need an
explicit adapter policy and cannot be mapped directly to `Decimal{P,S}`.
`DecimalValue` permits scales through 16383, but its coefficient is still
bounded by its storage integer. It does not cover all PostgreSQL `numeric`
values, including NaN, infinities, or coefficients beyond 256 bits.

Validate schema parameters, coefficients, byte order, and null masks before
using `reinterpret` for external data. Null values belong in `missing` or a
format's validity bitmap. A scalar `reinterpret(D, u)` is unchecked and can
truncate a wider integer. Use `convert(D, x)` to convert a numeric value.

The LinearAlgebra extension supports ordinary dense matrices, pivot arguments,
and diagonal/triangular inverses and solves with vector or dense matrix right
sides. Other structured or in-place operations can still use fixed-scale
arithmetic; convert inputs with `float` first. Use `Rational{BigInt}` inputs
when exact algebra is required.
