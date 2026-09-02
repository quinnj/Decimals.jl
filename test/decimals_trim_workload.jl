# JuliaC --trim=safe workload: drives the major Decimals.jl paths — parsing
# (Base.parse/tryparse and the Parsers.jl extension), checked arithmetic,
# division with rounding modes, rescale/normalize, conversions and rounding,
# value-based hashing and cross-type comparison, reductions (the SIMD sum
# specialization), broadcast kernels, formatting (string/writedecimal!/print),
# and random generation — so a trimmed executable proves the whole surface is
# statically compilable.
#
# Deliberately excluded: BigFloat/BigInt escape hatches (`big`, the Printf
# %f/%e/%g extension) — GMP/MPFR are not trim-friendly and those are cold
# convenience paths, not wire/compute paths.

using Decimals, Parsers

const D2 = Decimal64{2}
const D128_10 = Decimal{38, 10, Int128}
const D256_40 = Decimal{76, 40, Decimals.Int256}

@noinline function check(cond::Bool, name::String)::Nothing
    if !cond
        Core.println("FAILED: " * name)
        error(name)
    end
    return nothing
end

function parse_paths()::Nothing
    x = parse(D2, "123.45")
    check(Decimals.unscaled(x) == Int64(12345), "parse basic")
    check(parse(D2, "1.005") == parse(D2, "1.00"), "parse rounds half-even")
    check(tryparse(D2, "not a number") === nothing, "tryparse rejects")
    w = parse(D128_10, "-9876543210.0123456789")
    check(Decimals.unscaled(w) == Int128(-98765432100123456789), "parse wide")
    deep = parse(D256_40, "1.0000000000000000000000000000000000000001")
    check(Decimals.scale(deep) == 40, "parse 256-tier")
    dv = parse(DecimalValue{Int64}, "0.005")
    check(Decimals.unscaled(dv) == Int64(5) && Decimals.scale(dv) == Int32(3),
          "parse DecimalValue")
    # Parsers.jl extension (the CSV-adjacent path)
    p = Parsers.parse(D2, "42.42")
    check(Decimals.unscaled(p) == Int64(4242), "Parsers.parse")
    buf = codeunits("7.25,8.50")
    v1, pos, rc = Parsers.parsenext(D2, buf, 1, length(buf))
    check(rc == Parsers.RC_OK && Decimals.unscaled(v1) == Int64(725),
          "Parsers.parsenext")
    v2 = Parsers.parse(D2, buf, pos + 1, length(buf))
    check(Decimals.unscaled(v2) == Int64(850), "Parsers span parse")
    return nothing
end

function arithmetic_paths()::Nothing
    a = parse(D2, "10.05")
    b = parse(D2, "2.50")
    check(string(a + b) == "12.55", "add")
    check(string(a - b) == "7.55", "sub")
    check(string(a * b) == "25.1250", "mul exact")
    check(string(a / b) == "4.02", "div half-even")
    check(string(divide(a, b, RoundDown)) == "4.02", "divide RoundDown")
    check(string(div(a, b)) == "4.00", "div integer")
    check(string(rem(a, b)) == "0.05", "rem")
    q, r = divrem(a, b)
    check(q == div(a, b) && r == rem(a, b), "divrem")
    check(string(fld(-a, b)) == "-5.00", "fld")
    check(string(mod(-a, b)) == "2.45", "mod")
    overflowed = false
    try
        _ = typemax(D2) + eps(D2)
    catch e
        overflowed = e isa OverflowError
    end
    check(overflowed, "checked add throws")
    check(string(rescale(Decimal64{4}, a)) == "10.0500", "rescale up")
    check(string(rescale(Decimal64{1}, a)) == "10.0", "rescale rounds")
    nv = Decimals.normalize(parse(D128_10, "1.5000000000"))
    check(Decimals.scale(nv) == Int32(1), "normalize strips zeros")
    wide = parse(D256_40, "3.0000000000000000000000000000000000000000")
    check(string(wide / parse(D256_40, "7.0000000000000000000000000000000000000000")) ==
          "0.4285714285714285714285714285714285714286", "deep-scale divide")
    return nothing
end

function conversion_paths()::Nothing
    x = parse(D2, "2.50")
    check(Float64(x) == 2.5, "Float64")
    check(Float32(x) == 2.5f0, "Float32")
    check(Int(parse(D2, "7.00")) == 7, "Int exact")
    check(Rational{Int}(x) == 5//2, "Rational")
    check(D2(3) == parse(D2, "3.00"), "from Int")
    check(D2(1.25) == parse(D2, "1.25"), "from Float64")
    check(string(round(parse(D2, "1.25"); digits=1)) == "1.20", "round digits half-even")
    check(floor(Int, x) == 2 && ceil(Int, x) == 3, "floor/ceil")
    check(string(round(x, RoundUp)) == "3.00", "round mode")
    wide = parse(D128_10, "12345.6789012345")
    check(Float64(wide) == 12345.6789012345, "Float64 wide reciprocal path")
    return nothing
end

function compare_hash_paths()::Nothing
    a = parse(D2, "1.50")
    b = parse(Decimal128{10}, "1.5000000000")
    check(a == b, "cross-scale equality")
    check(hash(a) == hash(b), "cross-scale hash")
    check(hash(a) == hash(1.5), "hash agrees with Float64")
    check(a == 1.5 && a < 2 && a > 1.49, "cross-type compare")
    check(isequal(a, 3//2), "Rational isequal")
    d = Dict(a => 1)
    check(d[b] == 1, "Dict lookup by value")
    return nothing
end

function reduction_paths()::Nothing
    v = D2[parse(D2, "0.01") * D2(i) for i in 1:1000]
    s = sum(v)
    check(string(s) == "5005.00", "sum SIMD/widen path")
    w = v .+ v
    check(string(w[1000]) == "20.00", "broadcast add kernel")
    m = v .* v
    check(Decimals.scale(m[1]) == 4, "broadcast mul widen")
    check(string(maximum(v)) == "10.00" && string(minimum(v)) == "0.01", "extrema")
    sv = sort(D2[parse(D2, "3.00"), parse(D2, "1.00"), parse(D2, "2.00")])
    check(string(sv[1]) == "1.00" && string(sv[3]) == "3.00", "sort")
    return nothing
end

function format_paths()::Nothing
    x = parse(D128_10, "-42.0000000001")
    s = string(x)
    check(s == "-42.0000000001", "string round-trip form")
    n = Decimals.decimallength(x)
    buf = Vector{UInt8}(undef, n)
    pos = Decimals.writedecimal!(buf, 1, x)
    check(pos == n + 1 && String(buf) == s, "writedecimal!")
    io = IOBuffer()
    print(io, x)
    check(String(take!(io)) == s, "print")
    show(io, parse(D2, "1.25"))
    check(!isempty(String(take!(io))), "show")
    return nothing
end

function random_paths()::Nothing
    r = rand(D2)
    check(zero(D2) <= r < one(D2), "rand in [0,1)")
    rv = rand(D2, 8)
    check(length(rv) == 8, "rand vector")
    return nothing
end

function (@main)(args::Vector{String})::Cint
    parse_paths()
    arithmetic_paths()
    conversion_paths()
    compare_hash_paths()
    reduction_paths()
    format_paths()
    random_paths()
    Core.println("decimals trim workload passed")
    return Cint(0)
end
