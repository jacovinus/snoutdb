# ARCHITECTURE.md

## Overview

SnoutDB is a layered, single-binary columnar analytics tool. Data flows in one direction: **ingest → core → storage → query → exec → output**. Each layer is a separate Odin package with no circular dependencies.

```
cmd/snout/          — CLI entry point (6 files, package main)
core/               — shared types: Table, Column, Column_Type, Error enum
ingest/             — CSV, JSONL, and log readers; schema inference
storage/            — .snout file format reader/writer
sniff/              — automatic data profiling and query suggestions
query/              — filter (WHERE), group_by, sort — operate on Table structs
exec/               — aggregations: count, sum, avg, min, max, percentiles, error_rate
merge/              — append, consolidate, compact, rollup across .snout files
transform/          — column operations: rename, drop, cast, derive, bucket, date_trunc, regex_extract, json_extract
output/             — render results as table/csv/json/jsonl; sniff reports
cabi/               — shared library (libsnout) with experimental C ABI
tests/              — all tests; import by relative path (../core, ../ingest, etc.)
examples/           — ready-to-run demos: Python (ctypes), Go (cgo), Node.js (koffi)
```

---

## Package dependency graph

```
cmd/snout
    ├── core
    ├── ingest      → core
    ├── storage     → core
    ├── sniff       → core, ingest, query
    ├── query       → core
    ├── exec        → core
    ├── merge       → core, query
    ├── transform   → core
    └── output      → core, query, exec, sniff
```

No package imports `cmd/snout`. `core` imports nothing in this repo. The dependency graph is a DAG — no cycles.

---

## cmd/snout — CLI layer

The CLI is split into six files, all in `package main`:

| File | Responsibility |
|---|---|
| `main.odin` | `main()` entry point, command dispatch switch, `print_usage()` |
| `cmd_dispatch.odin` | One `run_X()` proc per command: `csv-info`, `csv-import`, `log-import`, `rollup`, etc. |
| `cmd_query.odin` | `run_group_command()` — the `-f file group=col -- agg=col` pipeline + `Pending_Sort` |
| `cmd_sniff.odin` | `run_sniff_command()` — the `sniff -f file` pipeline with all sniff options |
| `loaders.odin` | `load_*_or_exit()`, `resolve_stdin_path()`, `parse_log_opts()`, path utilities |
| `display.odin` | `print_table_info()`, `print_numeric_stats()`, `print_written()`, `print_processing_time()` |

---

## core — shared types

**`Column`** (`core/column.odin`) uses a union-of-slices layout (structure of arrays). Each column holds one active slice (`strings`, `int64s`, `float64s`, or `bools`) and a `null_mask []bool` when `nullable == true`.

**`Table`** (`core/types.odin`) owns an explicit `allocator` field. Always call `snout_core.free_table(&table)` — this is an explicit-allocator codebase.

**`Error`** (`core/types.odin`) is a flat enum, not a union. All public procedures return `(value, Error)`. Check `.None` before using the value.

---

## ingest — readers

### CSV (two-pass streaming)

`inspect_csv_file` (pass 1) reads the file once to determine exact schema and row count with O(1) memory per row. `populate_csv_table` (pass 2) reads again to fill typed columns directly. If the file changes between passes, returns `Input_Changed_During_Read`.

`profile_csv_file` (sniff path) feeds scanner fields directly into column accumulators without building a `core.Table` — memory is bounded by sniff config, not row count.

### JSONL (two-pass streaming)

`inspect_jsonl_file` (pass 1) uses a buffered line scanner + per-record arena to infer schema with O(1) memory per record. `populate_jsonl_table` (pass 2) fills typed columns directly, converting `Json_Scalar` values without intermediate `Json_Records`.

`profile_jsonl_file` (sniff path) feeds parsed JSON values directly into the same accumulators used by the CSV path.

### Log files

`inspect_log_file` + `read_log_table` support five formats: CLF, Combined, Logfmt, Syslog, Regex. Format is auto-detected from file content when `--format` is not specified. CLF timestamps are converted to ISO-8601 UTC. Syslog timestamps use a `0000-MM-DD` year placeholder (RFC 3164 has no year).

`profile_log_file` (sniff path) streams log lines through the same column accumulator infrastructure.

---

## storage — .snout file format

Single-file columnar format: `[header][metadata][chunks…][dictionaries][statistics][footer]`. Chunk size is 64K rows (65,536). Each chunk carries per-column null_count, min, and max statistics for future chunk-skip optimization.

Supported encodings in v0.1.0: Plain and Dictionary. Dictionary encoding is
applied automatically to String and Timestamp columns when it is smaller than
plain encoding.

The format is versioned (current: v2). The reader supports v1 for backward compatibility.

Full binary spec: `codex/SPEC-0004-file-format.md`.

---

## sniff — profiling engine

`sniff/` profiles any input source without loading it entirely into memory. It classifies each column as one of: `Timestamp`, `Identifier`, `Dimension`, or `Metric` based on cardinality ratios.

Key internals:

- **`Column_Scan_State`** (`sniff/cardinality.odin`) accumulates per-column stats in one pass: distinct value maps, frequency maps, numeric min/max/mean, and Welford M2 for population standard deviation.
- **`finalize_column_profile`** (`sniff/accumulator.odin`) materializes the scan state into a `Column_Profile`. `std_dev` is computed here as `sqrt(m2/count)`.
- **`profile_table`** (`sniff/profile.odin`) runs a second pass over in-memory data to count outliers (values beyond 3σ from the mean). Streaming paths (CSV, JSONL, log) get `std_dev` but `outlier_count = 0`.
- **`build_suggestions`** generates ranked executable query commands based on classified column roles.

`--max-distinct` bounds exact cardinality tracking. Above the limit, `cardinality_exact = false` and only a lower bound is reported.

---

## query — group-by pipeline

`query.execute_group_query` runs in three stages:

1. **Filter** — `apply_filters` scans each row against `[]Filter_Predicate` and builds a keep-mask.
2. **Group** — `build_groups` hashes the group-key columns into a `map[string]int` (key = concatenated string representation). Each group accumulates `[]Aggregate_State`.
3. **Sort** — `sort_group_results` applies `[]Sort_Term` with `core.sort`.

Aggregate kinds: `Count`, `Sum`, `Avg`, `Min`, `Max`, `Percentile` (exact, nearest-rank), `Error_Rate` (Bool columns), `Count_Distinct` (type-specific maps on `context.temp_allocator`).

`Aggregate_State` for percentiles collects all values into a dynamic slice; the slice is sorted at materialization time. `Count_Distinct` uses per-type maps (`map[string]struct{}`, `map[i64]struct{}`, `map[u64]struct{}`, `[2]bool`) to avoid string conversion overhead.

Vectorized execution runs in 4096-row batches (`exec/`).

---

## merge — multi-file operations

`append_tables` aligns schemas (missing columns → null-padded, type promotion Int64→Float64→String, nullable widening) and concatenates row data.

`rollup_tables` applies `query.execute_group_query` to each source table, merges the results, then applies a second group-by to combine partial aggregates. Rollup output is a regular `.snout` file — one row per group, columns named `count`, `avg_latency_ms`, `p95_bytes`, etc.

---

## transform — column reshaping

Operations applied in a single pass over the source table, returning a new `core.Table`. No in-place mutation. Each op is parsed from a `key=value` CLI argument into a `Transform_Op` union variant.

Available ops: `Rename`, `Drop`, `Cast`, `Derive` (binary arithmetic: +, -, *, /), `Bucket` (edge-based labeling), `Date_Trunc` (timestamp floor to year/month/day/hour/minute), `Regex_Extract` (named capture group), `Json_Extract` (key from a JSON string column).

---

## output — rendering

`write_group_results` renders a `Group_Result_Set` as table, CSV, JSON, or JSONL to any `io.Writer`. Column widths for table format are computed in a first scan over all values.

`write_sniff_report` renders a `Sniff_Report` as table or JSON. The table format shows one row per column with role, null count, distinct count, and a details string (top-N values for Dimensions, min/mean/max/σ/outliers for Metrics, timestamp range for Timestamps).

---

## C ABI (libsnout)

`cabi/` exports 25 functions through an experimental C ABI. The ABI may change
before v1.0.0. Build with:

```bash
./scripts/build-cabi.sh          # → libsnout.dylib (macOS) / libsnout.so (Linux)
```

The header is `include/snoutdb.h`. Ready-to-run examples are in `examples/` for
Python (ctypes), Go (cgo), and Node.js (koffi). The ABI imports CSV, JSONL, and
`.snout` files; log ingestion remains a CLI operation in v0.1.0.

