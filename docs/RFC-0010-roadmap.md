# RFC-0010 Roadmap

## Phase 0
In-memory prototype

## Phase 1
.snout file format

## Phase 2
Raw ingestion

Status: CSV and JSONL ingestion implemented with streaming two-pass loaders.

CSV (TASK-0007): bounded-memory schema inference followed by direct
typed-column population. CSV sniff profiles files directly from the scanner
without materializing a table. 5M-row CSV sniff completes in ~7s, 69 MiB
peak RSS.

JSONL (TASK-0008): buffered line scanner with per-record arena reuse.
Pass 1 infers exact schema with O(1) memory per record. Pass 2A populates
typed columns directly without Json_Records. Pass 2B profiles directly
without building core.Table. 5M-row JSONL sniff completes with 75 MiB peak
RSS (previous path required >10 GB and was unusable for large files).

## Phase 3
Merge & compact

Status: implemented in TASK-0009. Three CLI operations: `append` (add rows
from N .snout files to a base), `consolidate` (merge N .snout files),
`compact` (rewrite a .snout file). Schema alignment handles missing columns
(null-padded), type promotion (Int64→Float64, anything→String), and nullable
widening. For 500,000-row files: append self×2 completes in 1.77s,
compact in 0.86s. Rollup (aggregate during merge) deferred to a later task.

## Phase 3.5
Aggregate extensions

Status: implemented in TASK-0010. Two new aggregate kinds: `p<N>` (exact
percentile, nearest-rank with `floor(p × (n-1))` index, consistent with
pandas `lower`/DuckDB disc) and `error_rate` (count(true)/count(non-null)
for Bool columns). `Numeric_Stats` extended with p50/p95/p99. Sort
resolution handles `--sort p95=col desc`. 30 new tests; 247 total green.

## Phase 4
Sniff intelligence

Status: basic deterministic profiling, role classification, and query
suggestions implemented. Outliers, correlations, and rollup analysis remain
future work.

## Phase 4.5
Storage Engine v2

Status: implemented in TASK-0011. Format major_version bumped to 2. Writer always
produces v2; reader supports both v1 (backward compat) and v2. Chunk size is
65,536 rows. Each column chunk carries a 32-byte header with encoding (Plain=0),
null_count, min, and max statistics (min/max as u64 bit-cast; meaningful for
Int64 and Float64; 0 for other types). Two layout-sensitive tests updated for
the new binary layout (chunk_count field in table metadata, unsupported version
bumped to 3). Two new tests: zero-row table round-trip, chunk stats verification.
249 tests green.

## Phase 4.6
Dictionary encoding

Status: implemented in TASK-0012. String and Timestamp columns use dictionary
encoding (ENCODING_DICTIONARY = 1) when it produces a smaller chunk than plain.
Writer builds a per-chunk dictionary (insertion-order, unique values), chooses
Plain if dict_total >= plain_total. Indices are u8 (≤256 distinct) or u16 (>256).
Reader dispatches on the encoding byte in the column chunk header. On the
complex_metrics fixture: endpoint/region/user_agent use Dict, timestamp/note use
Plain. 252 tests green.

## Phase 4.8
Transform Engine

Status: implemented in TASK-0014. New package `transform/` with 8 operations:
`rename` (column rename), `drop` (column removal), `cast` (type conversion with
soft-null on parse failure), `derive` (binary arithmetic expression appending a
new column; division always Float64; div-by-zero → null), `bucket` (N edges →
N-1 labeled bins; out-of-range → null), `date_trunc` (ISO-8601 truncation to
year/month/day/hour/minute; in-place or new column), `regex_extract` (capture
group N from `core:text/regex`; no-match → null), `json_extract` (top-level
key lookup in JSON string; missing/null → null). `apply_transforms` chains N
ops with single-copy intermediate tables. CLI: `snout transform <input>
<output.snout> op=args...`. 39 new tests; 302 total green.

## Phase 4.7
Rollups (merge + aggregate)

Status: implemented in TASK-0013; bug fix applied during live testing (2026-06-11).
New `rollup_tables` proc in `merge/rollup.odin` merges N source tables via
`merge_sources`, then calls `execute_group_query`, then materializes the
`Group_Result_Set` into a flat `core.Table` via `result_to_table`. Group key columns
preserve their source types (String, Int64, Bool, Timestamp). Aggregate columns are
named with the full `<fn>_<col>` convention (`avg_jitter_ms`, `p95_mos`, `count`)
via `query.aggregate_column_name` — earlier versions used the bare function name
(`avg`) causing duplicate column names when the same function appeared twice.
Count uses just `count` since `*` is not a valid column identifier. 11 new tests;
263 total green at original merge; 328 total green after live-test fix.

## Phase 4.9
Log Ingestion

Status: implemented in TASK-0015; two fixes applied during live testing (2026-06-11).
New files `ingest/log_schema.odin`, `ingest/log_formats.odin`, `ingest/log_reader.odin`,
`sniff/log_profile.odin`. Supports five formats: CLF (Apache/Nginx access logs),
Combined (CLF + referer + user_agent), Logfmt (key=value), Syslog RFC 3164, and
custom Regex with named capture groups (`(?P<name>...)`). Two-pass streaming reuses
`Jsonl_Scanner`. Fixed-format schemas (CLF, Combined, Syslog) are constant; dynamic
schemas (Logfmt, Regex) accumulate columns across all lines with type inference and
promotion. CLF timestamps are normalised to ISO-8601 UTC with integer-arithmetic
offset application. Syslog timestamps emit `0000-MM-DDTHH:MM:SS` (no year in
RFC 3164). Syslog PRI prefix (`<NNN>`) is stripped before parsing. Non-strict mode
null-pads malformed lines and counts `parse_errors`.

Auto-detection samples first 20 lines, picks the format matching ≥80%, and is now
invoked by `inspect_log_file` itself when `Log_Read_Options.has_format` is false —
meaning `log-info`, `log-import`, and `sniff` all auto-detect without the caller
needing to call `detect_log_format` first. The resolved format is stored in
`Log_File_Schema.format` so `populate_log_table` uses it without re-detecting.
`--format` (for `log-info`/`log-import`) and `--logformat` (for `sniff`) still
override auto-detect when provided.

CLI: `log-info` (schema + row count), `log-import` (ingest to .snout). Sniff
routing handles `.log`/`.access`/`.error` extensions. 26 new tests (including
PRI-prefix and auto-detect tests); 328 total green.

## Phase 5
C ABI and bindings
