# Benchmarks

`PERF.md` is the benchmark report for Decimals 1.0: methodology, the measured
numbers, and the six charts in `charts/`. Everything needed to reproduce it is
packed in `harness.tar.xz` so the repository does not carry the machinery in
its tree:

- `run.sh` and the Julia harness scripts (old-vs-new, cross-library, columnar,
  memory, parse-by-width), with `Project.toml` for ad-hoc runs
- the input corpora and the result files the tables and charts are generated from
- the Rust and Python comparison harnesses (rust_decimal; Python `decimal`,
  polars, duckdb)
- `charts/gen_charts.py` and `render_png.sh`, which draw the SVG charts and
  rasterize them, and `regen_tables.py`, which syncs `PERF.md`'s tables from the
  result files
- `gauntlet/`, the ecosystem harness behind `docs/ecosystem-compat.md`

To reproduce:

```bash
tar xJf bench/harness.tar.xz          # unpacks into bench/
bench/run.sh envs                     # pinned environments (once)
bench/run.sh new                      # measure this package
bench/run.sh charts                   # regenerate SVG + PNG
python3 bench/regen_tables.py         # sync PERF.md from results/
```

`PERF.md` lists the other steps (`old`, `others`) and the requirements (Julia
1.12, a Rust toolchain, Python with polars and duckdb, Chrome for rendering).
