#!/usr/bin/env bash
# TASK-0007 benchmark: streaming CSV ingestion and direct sniff profiling.
# Usage: ./scripts/benchmark-task-0007.sh [row-count]
# Default row count is 5,000,000. Generates the fixture when missing.
set -euo pipefail

cd "$(dirname "$0")/.."

ROW_COUNT="${1:-5000000}"
FIXTURE="tests/fixtures/complex_metrics_${ROW_COUNT}.csv"

if [[ ! -f "$FIXTURE" ]]; then
  echo "Generating ${FIXTURE} (${ROW_COUNT} rows)..." >&2
  node tools/generate_complex_metrics_500.mjs "$ROW_COUNT"
fi

echo "== Building release binary and benchmarks (-o:speed) ==" >&2
odin build ./cmd/snout -out:snout -o:speed
odin build benchmarks/csv_ingest_bench.odin -file -out:benchmarks/csv_ingest_bench -o:speed
odin build benchmarks/sniff_file_bench.odin -file -out:benchmarks/sniff_file_bench -o:speed

echo
echo "== Scanner / inspection / table-load benchmark =="
./benchmarks/csv_ingest_bench "$FIXTURE"

echo
echo "== Direct sniff benchmark =="
./benchmarks/sniff_file_bench "$FIXTURE"

echo
echo "== CLI gates (time + peak memory) =="
echo "-- sniff --format json (target <= 9s, peak RSS <= 512 MiB)"
/usr/bin/time -l ./snout sniff -f "$FIXTURE" --format json > /dev/null 2> /tmp/snout_bench_sniff.txt || true
grep "Elapsed" /tmp/snout_bench_sniff.txt || true
grep -E "real|maximum resident" /tmp/snout_bench_sniff.txt

echo "-- sniff --top 0 --suggestions 0 --format json (diagnostic)"
/usr/bin/time -l ./snout sniff -f "$FIXTURE" --top 0 --suggestions 0 --format json > /dev/null 2> /tmp/snout_bench_sniff_reduced.txt || true
grep "Elapsed" /tmp/snout_bench_sniff_reduced.txt || true
grep -E "real|maximum resident" /tmp/snout_bench_sniff_reduced.txt

echo "-- csv-info (target <= 13s)"
/usr/bin/time -l ./snout csv-info "$FIXTURE" > /dev/null 2> /tmp/snout_bench_info.txt || true
grep "Elapsed" /tmp/snout_bench_info.txt || true
grep -E "real|maximum resident" /tmp/snout_bench_info.txt
