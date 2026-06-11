# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Build & Run

```bash
# Build the CLI binary
odin build ./cmd/snout -out:snout

# Run all tests (329 tests, under 1s)
odin test ./tests -out:tests/snout_tests -vet -strict-style

# Run a single test by name
odin test ./tests -out:tests/snout_tests -define:ODIN_TEST_NAME=tests.csv_loads_successfully

# Build the shared C library
./scripts/build-cabi.sh
```

Tests must be run from the repo root — fixture paths are relative to it (`tests/fixtures/`).

## Architecture

SnoutDB is a layered pipeline: **ingest → core → storage → query → exec → output**. Each layer is a separate Odin package with no circular dependencies. See [ARCHITECTURE.md](ARCHITECTURE.md) for the full design document.

```
core/       — shared types: Table, Column, Column_Type, Error enum
ingest/     — CSV, JSONL, and log readers; two-pass streaming schema inference
storage/    — .snout file format reader/writer (chunked columnar, 64K rows/chunk)
sniff/      — automatic data profiling: cardinality, role detection, outlier detection, query suggestions
query/      — filter (WHERE), group_by, sort, count_distinct — operate on in-memory Table structs
exec/       — aggregations: count, sum, avg, min, max, percentiles — vectorized in 4096-row batches
merge/      — append, consolidate, compact, rollup across .snout files
transform/  — rename, drop, cast, derive, bucket, date_trunc, regex_extract, json_extract
output/     — render results as table/csv/json/jsonl; sniff_render for profile reports
cabi/       — shared library (libsnout) with 25-function experimental C ABI
cmd/snout/  — CLI entry point, split into 6 focused files (see below)
tests/      — package tests; all tests import by relative path (../core, ../ingest, etc.)
```

### cmd/snout — CLI structure

The CLI is split into 6 files within `package main`:

| File | Responsibility |
|---|---|
| `main.odin` | `main()` dispatch switch + `print_usage()` |
| `cmd_dispatch.odin` | One `run_X()` proc per command (`csv-info`, `log-import`, `rollup`, …) |
| `cmd_query.odin` | `run_group_command()` + `Pending_Sort` |
| `cmd_sniff.odin` | `run_sniff_command()` with all sniff options |
| `loaders.odin` | `load_*_or_exit()`, `resolve_stdin_path()`, `parse_log_opts()`, path helpers |
| `display.odin` | `print_table_info()`, `print_numeric_stats()`, `print_written()`, `print_processing_time()` |

### Key data structures

**`Column`** (`core/column.odin`) uses a union-of-slices layout (structure of arrays), not array of structs. Each column carries one active slice (`strings`, `int64s`, `float64s`, or `bools`) plus a `null_mask []bool` when `nullable == true`.

**`Table`** (`core/types.odin`) owns an explicit `allocator` field — always call `snout_core.free_table(&table)` to release memory. This is an explicit-allocator codebase; do not use `new`/`delete` implicitly.

**`Error`** (`core/types.odin`) is a flat enum, not a union. All public procedures return `(value, Error)`. Check `.None` before using the value.

### .snout file format

Single-file columnar format: `[header][metadata][chunks…][dictionaries][statistics][footer]`. Chunk size is 64K rows. Encodings implemented in v0.1.0 are Plain and Dictionary. See `codex/SPEC-0004-file-format.md` for the binary spec.

### Sniff engine

`sniff/` profiles any input source (CSV, JSONL, log, or .snout) without loading it into memory. Classifies each column as `Timestamp`, `Identifier`, `Dimension`, or `Metric` based on cardinality ratios. Computes population standard deviation (Welford algorithm) and outlier count (3σ rule, in-memory path only). `--max-distinct` bounds exact cardinality tracking.

### Streaming ingestion

CSV and JSONL use a two-pass pipeline:
- Pass 1 (`inspect_*`): exact schema + row count, O(1) memory per row/record.
- Pass 2 (`populate_*`): direct typed-column fill without intermediate records.

Log files (`ingest/log_*.odin`) use the same pattern. If a file changes between passes, loaders return `Input_Changed_During_Read`.

Sniff paths (`profile_csv_file`, `profile_jsonl_file`, `profile_log_file`) feed scanner values directly into column accumulators without building a `core.Table`.

## Design Constraints

Priority order: **Correctness > Simplicity > Maintainability > Performance**.

Never introduce: distributed systems, networking, SQL compatibility layers, ORM concepts.

Prefer: explicit allocators, structure-of-arrays layouts, vectorized execution, chunk-based storage.

Every change that touches a hot path needs a benchmark. Every change needs a test.

## Useful Scripts

```bash
./scripts/demo-sniff.sh                  # interactive sniff demo on bundled data
./scripts/demo-sniff.sh path/to/file     # sniff a custom file
./scripts/test-task-0006.sh              # end-to-end validation of sniff engine
./scripts/benchmark-task-0007.sh [rows]  # CSV streaming benchmark
./scripts/build-cabi.sh                  # build libsnout shared library
./scripts/validate-release.sh            # strict v0.1.0 pre-release validation
```

## Active Development

TASK-0001 through TASK-0017 are complete. Streaming JSONL ingestion (TASK-0008), merge engine (TASK-0009–0013), storage v2 (TASK-0011–0012), transforms (TASK-0014), log ingestion (TASK-0015), C ABI (TASK-0016), and v0.1.0 internal versioning (TASK-0017) are implemented. Planned: SPEC-0010 merge engine v2, C ABI stdin and log ingestion support.
