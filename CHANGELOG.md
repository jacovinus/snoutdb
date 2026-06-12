# Changelog

## v0.2.0

Hunt becomes SnoutDB's automatic local analysis workflow.

### Added

- `snout hunt` for CSV, JSONL, logs, and `.snout` inputs.
- Severity summaries, stacked overviews, frequent message patterns, and
  deterministic severity-aware finding ranking.
- Compact and verbose Hunt reports with temporal histograms, peaks,
  first/last matches, representative samples, and reproduction commands.
- JSON and JSONL Hunt output with a schema version and no ANSI escapes.
- Color-free text and structured Markdown report export through
  `-o` / `--output`.
- Application and bracketed application log formats.
- `contains`, `not-contains`, and ASCII case-insensitive `icontains` string
  filters.

### Changed

- Improved terminal wrapping for long values.
- Expanded direct log querying and stdin log-format detection.
- Documented Hunt as a primary product workflow and added its architecture,
  security considerations, limitations, and release validation.

### Compatibility

- The `.snout` file format remains v2 with v1 read compatibility.
- The experimental C ABI is unchanged.
- Hunt output is new and remains pre-1.0.
- Hunt does not yet support stdin or file-based configuration.

## v0.1.0

Initial versioned snapshot of SnoutDB.

### Included

- CSV ingestion
- JSONL ingestion
- Log ingestion
- `.snout` columnar file format v2 with v1 read compatibility
- Sniff engine
- Query engine
- Transform engine
- Merge engine
- Rollups
- Experimental C ABI / `libsnout`

### Release Notes

- The CLI, C ABI, and `.snout` format may change before `v1.0.0`.
- The C ABI imports CSV, JSONL, and `.snout` files. Log ingestion is currently
  available through the CLI.
- Storage encodings implemented in this snapshot are Plain and Dictionary.
