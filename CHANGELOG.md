# Changelog

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
