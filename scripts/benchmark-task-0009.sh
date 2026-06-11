#!/usr/bin/env bash
# TASK-0009 benchmark: merge engine (append, compact).
# Usage: ./scripts/benchmark-task-0009.sh [row-count]
# Default row count is 500,000.
set -euo pipefail

cd "$(dirname "$0")/.."

ROW_COUNT="${1:-500000}"
FIXTURE_CSV="tests/fixtures/complex_metrics_${ROW_COUNT}.csv"

if [[ ! -f "$FIXTURE_CSV" ]]; then
  echo "Generating ${FIXTURE_CSV} (${ROW_COUNT} rows)..." >&2
  node tools/generate_complex_metrics_500.mjs "$ROW_COUNT"
fi

echo "== Building release binary and benchmark (-o:speed) ==" >&2
odin build ./cmd/snout -out:snout -o:speed
odin build benchmarks/merge_bench.odin -file -out:benchmarks/merge_bench -o:speed

# Prepare a .snout fixture from the CSV for the CLI gates
FIXTURE_SNOUT="/tmp/snout_bench_${ROW_COUNT}.snout"
echo "Importing ${FIXTURE_CSV} → ${FIXTURE_SNOUT} ..." >&2
./snout csv-import "$FIXTURE_CSV" "$FIXTURE_SNOUT" 2>/dev/null

echo
echo "== Component benchmark (500 / 50000 / ${ROW_COUNT} rows) =="
./benchmarks/merge_bench \
  tests/fixtures/complex_metrics_500.csv \
  tests/fixtures/complex_metrics_50000.csv \
  "$FIXTURE_CSV"

echo
echo "== CLI gates (time + peak memory) =="

echo "-- snout append (self×2) --"
/usr/bin/time -l \
  ./snout append "$FIXTURE_SNOUT" "$FIXTURE_SNOUT" /tmp/snout_bench_appended.snout \
  > /dev/null 2>/tmp/bench_append.txt || true
grep -E "real|maximum resident" /tmp/bench_append.txt

echo "-- snout compact --"
/usr/bin/time -l \
  ./snout compact "$FIXTURE_SNOUT" /tmp/snout_bench_compacted.snout \
  > /dev/null 2>/tmp/bench_compact.txt || true
grep -E "real|maximum resident" /tmp/bench_compact.txt

echo "-- snout consolidate (3 copies) --"
/usr/bin/time -l \
  ./snout consolidate "$FIXTURE_SNOUT" "$FIXTURE_SNOUT" "$FIXTURE_SNOUT" \
    /tmp/snout_bench_consolidated.snout \
  > /dev/null 2>/tmp/bench_consolidate.txt || true
grep -E "real|maximum resident" /tmp/bench_consolidate.txt

rm -f /tmp/snout_bench_*.snout
