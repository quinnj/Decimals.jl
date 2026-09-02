# Manual

## Choosing a type

There are two value types, and the choice between them is about *where the
scale lives*.

[`Decimal{P,S,T}`](@ref Decimal) puts the scale in the type. It holds one
field, `unscaled::T`, and means `unscaled * 10^-S` with the invariant
`|unscaled| < 10^P`. `P` is the precision (total decimal digits), `S` the scale
(fractional digits, `0 <= S <= P`), and `T` the storage integer. Because the
struct is nothing but the coefficient, `Vector{Decimal{P,S,T}}` has exactly the
layout of an Arrow/Parquet/DuckDB decimal buffer with the same precision and
scale — no per-element conversion when data crosses the boundary.

Four aliases name the storage tiers at their maximum precision, which are the
tiers those formats define:

| alias | expands to | digits | storage | typical use |
|---|---|---|---|---|
| [`Decimal32{S}`](@ref Decimal32) | `Decimal{9,S,Int32}` | 9 | 32-bit | narrow Arrow/Parquet columns |
| [`Decimal64{S}`](@ref Decimal64) | `Decimal{18,S,Int64}` | 18 | 64-bit | money, most SQL `DECIMAL` |
| [`Decimal128{S}`](@ref Decimal128) | `Decimal{38,S,Int128}` | 38 | 128-bit | DuckDB/Spark default width |
| [`Decimal256{S}`](@ref Decimal256) | `Decimal{76,S,Decimals.Int256}` | 76 | 256-bit | Arrow `Decimal256` |

Write `Decimal{P,S}` when a schema pins a precision narrower than its tier's
maximum — `Decimal{9,2}` accepts fewer digits than `Decimal32{2}` before
throwing, though both store an `Int32`. The storage type is filled in from `P`
whenever you leave it off.

[`DecimalValue{T}`](@ref DecimalValue) is the runtime-scale sibling: it stores
the scale (an `Int32` in `0:16383`) alongside the coefficient. Use it when the
scale travels with each value rather than with the column — a PostgreSQL
`numeric`'s per-value `dscale`, a value whose scale is not known until runtime,
or the result of [`Decimals.normalize`](@ref). It is still isbits, but it is a word
wider and its arithmetic has to align scales at run time, so for columnar data
`Decimal{P,S}` is the right default.

Both are subtypes of `Decimals.AbstractDecimal <: Real`. There is deliberately
no `AbstractFloat` subtyping, and there are no `NaN` or `Inf` values: `isnan`
is always `false`, `isfinite` always `true`, and an operation that would
produce a non-value throws.

## Constructing values

```julia
dec"1.25"                          # literal, minimal fitting type
dec"1_000_000.25"                  # underscores allowed between digit groups
dec"1.5e-3"                        # exponents fold into the scale

Decimal64{2}("1234.56")            # from a string (exact core scanner)
using Parsers                      # parse/tryparse come from the Parsers extension
parse(Decimal64{2}, "1234.567")    # 1234.57 — rounds half-even at the target scale
tryparse(Decimal64{2}, "nope")     # nothing

Decimal64{2}(5)                    # from an Integer — exact or throws
Decimal64{2}(1//4)                 # from a Rational — exact or throws
Decimal64{2}(0.1)                  # from a Float — rounds half-even at scale 2

reinterpret(Decimal64{2}, 123456)  # from an unscaled coefficient, unchecked
```

The rule is *exact or throw*, with two documented exceptions. Construction from
an `AbstractFloat` rounds half-even at the target scale, as every
cross-representation float conversion in Base does; a `DecimalValue` built from
a float instead keeps the exact binary expansion, which is what a runtime scale
is for:

```julia
Decimal64{2}(0.1)   # 0.10
DecimalValue(0.1)   # 0.1000000000000000055511151231257827021181583404541015625
```

And `parse` rounds half-even at the target scale, like `parse(Float64, s)`.
Everything else — `convert`, the integer and rational constructors — raises
`InexactError` or `OverflowError` rather than losing a digit.

[`@dec_str`](@ref) produces the *minimal* type that fits the literal, so
`dec"1.25"` is a `Decimal{3,2,Int32}` and not a money type. That is what you
want for a constant in an expression (it promotes to whatever the other operand
needs) and not what you want for a column; annotate explicitly there.

`reinterpret` is the zero-copy path: it builds a value directly from an
unscaled coefficient without checking the `|u| < 10^P` invariant, because in a
wire decode the invariant is the producer's contract and re-checking it per
element is the cost you are trying to avoid.

## Arithmetic

`+` and `-` promote both operands value-preservingly and then compute
*checked*: a result that no longer fits throws `OverflowError`. They never
wrap and never silently round.

```julia
Decimal64{2}("1.20") + Decimal64{2}("0.05")    # 1.25  :: Decimal{18,2,Int64}
typemax(Decimal64{2}) + Decimal64{2}("1.00")   # OverflowError
```

`*` is exact: the result has scale `S1 + S2` and precision `min(P1 + P2, 76)`.
Multiplying by a plain `Integer` is scale-preserving instead, because
multiplying by a count should not widen the scale.

```julia
Decimal64{2}("1.25") * Decimal64{3}("2.500")   # 3.12500 :: Decimal{36,5,Int128}
Decimal64{2}("2.50") * 3                       # 7.50    :: Decimal{37,2,Int128}
```

`/` rounds half-even at scale `max(S1, S2)`. [`divide`](@ref) is the same
operation with the rounding mode spelled out:

```julia
Decimal64{2}("1.00") / Decimal64{2}("3.00")                     # 0.33
divide(Decimal64{2}("1.00"), Decimal64{2}("3.00"), RoundUp)     # 0.34
```

`sum` widens to the `Int128` tier, where overflow is provably impossible below
1.7e20 elements — so the accumulation loop needs no per-element check and
vectorizes, while still being safe:

```julia
sum(fill(Decimal64{2}("0.10"), 10))    # 1.00 :: Decimal{38,2,Int128}
```

`div`, `rem`, `mod`, `fld`, `cld`, and `divrem` are real implementations (not
float fallbacks) and take a rounding mode where Base's do. Elementwise `a .+ b`,
`a .- b`, and `a .* b` over same-shaped vectors hit SIMD kernels that compute
per lane and check overflow once for the whole array.

## Rounding

There is no global rounding state anywhere in the package. Every rounding
decision is an argument at a call site, and the seven modes accepted are
`RoundNearest` (half-even, the default), `RoundNearestTiesAway`,
`RoundNearestTiesUp`, `RoundToZero`, `RoundFromZero`, `RoundDown`, and
`RoundUp`.

```julia
# change the scale of a value
rescale(Decimal64{2}, Decimal64{4}("1.2356"), RoundUp)   # 1.24
rescale(DecimalValue(12345, 3), 1)                       # 12.3
round(Decimal64{2}, 1.005)                               # 1.00 (same thing, Base spelling)

# round within a type
round(Decimal64{4}("1.2346"); digits=2)                  # 1.2300
trunc(Decimal64{2}("1.99"))                              # 1.00
floor(Decimal64{2}("-1.01"))                             # -2.00
ceil(Decimal64{2}("1.01"))                               # 2.00

# round out to an integer
round(Int, Decimal64{2}("1.50"))                         # 2
floor(Int, Decimal64{2}("1.99"))                         # 1
```

`round(x; digits)` stays exact and in-type. (Base's generic fallback for a
custom `Real` silently returns a `Float64`; that is overridden here.) There is
no `sigdigits` keyword — a fixed-point type has no floating significand.

`convert` and the constructors are the exact-or-throw counterpart of
[`rescale`](@ref); reach for `rescale` the moment you mean "round this into
that scale".

## Comparison and hashing

Equality and ordering are by numeric value, across scales, precisions, storage
types, and other `Real` types. The representation still remembers its scale —
`string` prints the trailing zeros — but the number does not care:

```julia
dec"1.20" == dec"1.2" == 12//10 == 1.2       # true
hash(Decimal64{2}("1.25")) == hash(1.25)     # true
sort([dec"3.5", dec"1.25", dec"2.0"])        # works; sorts on the coefficient
```

Hashing goes through `Base.decompose`, so a decimal hashes identically to an
equal `Int`, `Rational`, or `Float64` — which is what makes `Dict` keys,
`unique`, and DataFrames `groupby`/`join` behave.

`≈` is exact equality, because Base's `rtoldefault` is zero for a non-
`AbstractFloat` `Real`. That is the same behaviour `Rational` has, and it is
arguably what you want for money; pass `rtol` or `atol` when you want a
tolerance.

## Printing and parsing

`string` and `print` always produce the plain positional form — a valid SQL
literal, CSV field, and JSON number, and never scientific notation:

```julia
string(Decimal64{2}("-12.30"))    # "-12.30"
```

`show` (and therefore `repr`) gives the round-trippable typed form,
`Decimal{18,2,Int64}("-12.30")`. At the REPL, though, values display through
the `text/plain` method, which prints plain digits and only switches to
scientific notation once the positional form passes 44 characters:

```julia-repl
julia> Decimal64{2}("1234.56")
1234.56

julia> DecimalValue{Decimals.Int256}(123, 50)
1.23E-48
```

`parse` and `tryparse` (with Parsers loaded — they are defined by the Parsers
extension) accept an optional sign, digits, an optional decimal point, and an
optional `e`/`E` exponent, with surrounding ASCII whitespace allowed. They
round half-even into the target scale. The string constructors
(`Decimal64{2}("1.25")`) and `dec"..."` literals use the package's own exact
scanner and need no extension.

## The wire API

Four public names cover byte-level interop:

```julia
using Decimals: unscaled, scale, writedecimal!, decimallength

x = Decimal64{2}("-1.25")
unscaled(x)                       # -125 :: Int64 — what the buffer stores
scale(x)                          # 2
reinterpret(typeof(x), unscaled(x)) === x   # true

decimallength(x)                  # 5 — bytes needed, computed without formatting
buf = zeros(UInt8, 16)
pos = writedecimal!(buf, 1, x)    # 6 — the position after the written bytes
String(buf[1:pos-1])              # "-1.25"
```

[`writedecimal!`](@ref Decimals.writedecimal!) is the allocation-free formatter
that `string` is built on; it bounds-checks nothing, so reserve
[`decimallength(x)`](@ref Decimals.decimallength) bytes first. Together with
`reinterpret`, this is enough to read and write decimal columns without ever
materialising an intermediate `String`.

[`Decimals.normalize`](@ref) is the other representation-level tool: it strips trailing
zeros from the coefficient and lowers the scale to match, returning a
`DecimalValue` (the scale is now a property of the value, not the type). The
number is unchanged; only the digits a wire format would carry are.

!!! note
    `normalize` is public but deliberately not exported, so it never collides
    with `LinearAlgebra.normalize`; call it as `Decimals.normalize`.

## Extensions

These load automatically as package extensions when the companion package is
present.

### Parsers.jl

The fast path — byte-level `parse`, `tryparse`, and `parsenext` over strings or
byte spans, with `decimal=` and `rounding=` keywords. This is what a CSV reader
or wire decoder should call.

```julia
using Decimals, Parsers

Parsers.parse(Decimal64{2}, "1234.56")                    # 1234.56
Parsers.parse(Decimal64{2}, "1,25"; decimal=',')          # 1.25
Parsers.parse(Decimal64{2}, "1.005"; rounding=RoundUp)    # 1.01
Parsers.tryparse(Decimal64{2}, "nope")                    # nothing

buf = codeunits("12.34,56.78")
Parsers.parsenext(Decimal64{2}, buf, 1, length(buf))      # (12.34, 6, RC_OK)
```

`parsenext` returns `(value, nextpos, returncode)` and is the tokenizer entry
point: it stops at the first byte that cannot continue a decimal, so the caller
can step through a delimited line. It requires Parsers 3. Under Parsers 2 the
extension loads as a no-op — so an environment that also contains a
Parsers-2-pinned package still resolves — and `parse`/`tryparse` are
unavailable until Parsers 3 is (string constructors and literals still work).
The extension also defines `Base.parse`/`Base.tryparse` for decimal types, so
plain `parse(Decimal64{2}, s)` is the same fast path once Parsers is loaded.

### Printf.jl

`%f`, `%e`, and `%g` print the true digits: they route through a 1024-bit
`BigFloat` rather than `Float64(x)`, so nothing past 17 significant digits is
silently lost. `%d` is exact-or-`InexactError`, matching `Rational`.

```julia
@printf("%.2f", Decimal64{2}("1234.56"))   # 1234.56
@printf("%d", Decimal64{2}("1234.00"))     # 1234
@printf("%d", Decimal64{2}("1234.56"))     # InexactError
```

### JSON.jl

Decimals serialize as raw exact-digit JSON *numbers* — not strings, and not
`Float64`-rounded (the default path for an unknown `Real` stringifies
`convert(Float64, x)`). Requires JSON 1.x.

```julia
JSON.json((price = Decimal64{2}("1234.56"), qty = 3))
# {"price":1234.56,"qty":3}
```

### LinearAlgebra.jl

`A*B`, `dot`, `tr`, `A+B`, and `kron` stay exact decimal, widening the result
type as the product requires. Factorizations — `lu`, `cholesky`, `qr`, `svd`,
`eigen`, `hessenberg`, `schur`, `lq`, and the functions built on them (`det`,
`logdet`, `inv`, `eigvals`, `svdvals`, `cond`, `nullspace`, `pinv`, `rank`) —
convert to `Float64` first. See [LinearAlgebra: exact where exact is
honest](@ref) for why. If you need an exact factorization, `lu(Rational.(A))`
is the honest way to get one.
