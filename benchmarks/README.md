# SnoutDB Benchmarks

This directory contains focused benchmarks for ingestion, profiling, sorting,
merge operations, and `.snout` persistence.

Benchmarks are intended to detect regressions and describe current behavior.
They are not presented as comparisons with DuckDB, Polars, Miller, or other
projects unless the workloads and methodology are made equivalent.

## Reproduce the CSV Benchmark

Requirements:

- Odin
- Node.js only when the generated fixture does not already exist
- macOS `/usr/bin/time` for the optional CLI timing output

Run:

```bash
./scripts/benchmark-task-0007.sh 5000000
```

The generator uses only Node.js standard-library modules and installs no npm
packages:

```bash
node tools/generate_complex_metrics_500.mjs 5000000
```

## Current Baseline

Measured on June 11, 2026:

| Environment | Value |
|---|---|
| Machine | MacBook Pro, Apple M4 Pro |
| CPU | 14 cores: 10 performance, 4 efficiency |
| Memory | 24 GB |
| OS | macOS 15.3.2 |
| Odin | `dev-2026-05:ea5175d86` |
| Build | `-o:speed` |
| Dataset | Deterministic CSV, 5,000,000 rows, 20 columns |
| File size | 787,669,699 bytes, approximately 751 MiB |

Results from one run:

| Operation | Result |
|---|---|
| CSV scanner | 1.52 s, 494.8 MiB/s |
| Schema inspection | 2.76 s |
| Full typed table load | 5.74 s |
| Full `sniff` profile | 6.67 s |
| CLI `sniff --format json` | 6.80 s wall time |
| CLI `csv-info` | 8.79 s wall time |

These are single-run development measurements, not guaranteed service-level
objectives. Filesystem cache state, thermal conditions, Odin version, and
hardware affect results.

Peak RSS was not recorded in this run because the execution environment blocked
the macOS `time -l` system query. Future published baselines should include at
least three warm and cold runs plus peak memory.

## Other Benchmarks

```bash
# JSONL streaming and profiling
./scripts/benchmark-task-0008.sh 5000000

# Append, consolidate, and compact
./scripts/benchmark-task-0009.sh 500000

# Log ingestion and profiling
./scripts/benchmark-task-0015.sh 50000

# In-memory sort behavior
odin run benchmarks/query_sort_bench.odin -file -o:speed
```

Large generated fixtures are intentionally excluded from Git and release
archives. Regenerate them with the scripts in `tools/`.

## Reporting Performance Changes

Include:

- before and after results;
- exact command;
- commit SHA;
- Odin version;
- operating system and hardware;
- dataset row count and byte size;
- whether the filesystem cache was warm;
- peak memory when available.
