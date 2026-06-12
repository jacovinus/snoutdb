# SnoutDB

A tiny embedded columnar database for metrics, logs, telemetry, and local analytics.

**Current version:** `v0.1.0` (early-stage; public interfaces may change before v1.0.0)

## Tagline
SnoutDB turns messy raw data into valuable local metrics.

## Key Features
- Raw ingestion (CSV, JSONL, logs) — including stdin (`-f -`)
- Automatic schema inference
- Columnar storage (.snout, chunked 64K rows, dictionary encoding)
- Merge & consolidation across files with schema alignment
- Rollups (aggregate during merge)
- Sniff reports — column roles, top-N values, outlier detection (σ / 3σ rule), query suggestions
- `count_distinct` aggregate
- Transforms: rename, cast, derive, bucket, date_trunc, regex_extract, json_extract
- Embedded C ABI (Python and Go examples)

---

## RFC / SPEC Status

| Doc | Title | Status |
|---|---|---|
| RFC-0001 | Vision | ✅ Reference |
| RFC-0002 | File Format | ✅ Implemented — TASK-0011 (v2 chunks + stats) |
| RFC-0003 | Query Engine | ✅ Implemented — TASK-0010 (group/filter/sort/percentile/error_rate) + count_distinct |
| RFC-0004 | Sniff Engine | ✅ Implemented — TASK-0006 (roles, top-N, query suggestions) + outlier detection (σ, outlier_count) |
| RFC-0005 | Transformations | ✅ Implemented — TASK-0014 (rename/drop/cast/derive/bucket/date_trunc/regex_extract/json_extract) |
| RFC-0006 | Merge & Consolidation | ✅ Implemented — TASK-0009 (append/consolidate/compact) + TASK-0013 (rollup) |
| RFC-0007 | C ABI | ✅ Implemented — TASK-0016 (25-function C ABI, Python and Go examples) |
| RFC-0008 | Odin Style Guide | ✅ Reference |
| RFC-0009 | Storage Engine v2 | ✅ Implemented — TASK-0011 (v2 format) + TASK-0012 (dictionary encoding) |
| RFC-0010 | Roadmap | ✅ Up to date |
| RFC-0011 | Hunt Analytics, Severity, and Configuration | 📝 Proposed — TASK-0019 |
| SPEC-0014 | Log Ingestion | ✅ Implemented — TASK-0015 (CLF/Combined/Logfmt/Syslog/Regex, auto-detect) |

**Tests:** 329 passing with `-vet -strict-style` · **Last updated:** 2026-06-11

---

## Project documents

| Document | Description |
|---|---|
| [ARCHITECTURE.md](../ARCHITECTURE.md) | Package structure, data flow, key data structures, design constraints |
| [docs/USE-CASES.md](USE-CASES.md) | 10 real-world workflows: log analysis, anomaly detection, SLA reports, API embedding |
| [examples/README.md](../examples/README.md) | Python and Go FFI examples |
| [benchmarks/README.md](../benchmarks/README.md) | Reproducible performance methodology and current baseline |
| [ROADMAP.md](../ROADMAP.md) | Current priorities, path to v1.0, and explicit non-goals |
| [CHANGELOG.md](../CHANGELOG.md) | Versioned snapshot contents and compatibility notes |
| [CLAUDE.md](../CLAUDE.md) | Build commands, test commands, architecture notes for AI assistants |
