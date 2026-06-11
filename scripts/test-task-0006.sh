#!/usr/bin/env bash

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/snoutdb-task-0006.XXXXXX")"
SNOUT_BIN="$TMP_DIR/snout"
BENCH_BIN="$TMP_DIR/sniff-bench"

cleanup() {
	rm -rf "$TMP_DIR"
}
trap cleanup EXIT

require_command() {
	if ! command -v "$1" >/dev/null 2>&1; then
		printf 'error: required command not found: %s\n' "$1" >&2
		exit 1
	fi
}

step() {
	printf '\n==> %s\n' "$1"
}

expect_failure() {
	label="$1"
	shift
	if "$@" >"$TMP_DIR/failure.stdout" 2>"$TMP_DIR/failure.stderr"; then
		printf 'error: expected failure: %s\n' "$label" >&2
		exit 1
	fi
	printf 'ok: %s -> %s\n' "$label" "$(tr '\n' ' ' <"$TMP_DIR/failure.stderr")"
}

require_command odin
require_command jq
require_command cmp

cd "$ROOT_DIR"

step "Build CLI and benchmark"
odin build ./cmd/snout -out:"$SNOUT_BIN" -o:speed
odin build ./benchmarks/sniff_bench.odin -file -out:"$BENCH_BIN" -o:speed

step "Run complete test suite with memory tracking"
odin test ./tests -all-packages

step "Validate human-readable report"
"$SNOUT_BIN" sniff \
	-f tests/fixtures/complex_metrics_500.csv \
	--top 3 \
	--suggestions 2 >"$TMP_DIR/report.txt"
grep -q '^profile_version: 1$' "$TMP_DIR/report.txt"
grep -q '^roles$' "$TMP_DIR/report.txt"
grep -q '^suggested queries$' "$TMP_DIR/report.txt"
grep -q 'call_id.*Identifier' "$TMP_DIR/report.txt"
grep -q 'timestamp.*Timestamp' "$TMP_DIR/report.txt"
grep -q 'region.*Dimension' "$TMP_DIR/report.txt"
grep -q 'mos.*Metric' "$TMP_DIR/report.txt"
test "$(grep -c '^   ./snout ' "$TMP_DIR/report.txt")" -eq 2

step "Validate JSON contract and native values"
"$SNOUT_BIN" sniff \
	-f tests/fixtures/complex_metrics_500.csv \
	--format json >"$TMP_DIR/csv.json"
jq empty "$TMP_DIR/csv.json"
jq -e '
	.version == 1 and
	.table.rows == 500 and
	.table.columns == 20 and
	(.columns | length) == 20 and
	(.suggestions | length) == 5 and
	([.columns[] | select(.name == "call_id")][0].role == "identifier") and
	([.columns[] | select(.name == "timestamp")][0].timestamp.min ==
		"2026-06-08T10:00:00Z") and
	([.columns[] | select(.name == "mos")][0].numeric.count == 489)
' "$TMP_DIR/csv.json" >/dev/null

step "Validate processing time on stderr without contaminating JSON stdout"
"$SNOUT_BIN" sniff \
	-f tests/fixtures/simple_metrics.csv \
	--format json >"$TMP_DIR/timed.json" 2>"$TMP_DIR/timed.stderr"
jq empty "$TMP_DIR/timed.json"
grep -Eq '^Elapsed: .+[.]$' "$TMP_DIR/timed.stderr"

step "Validate exact and truncated cardinality boundaries"
"$SNOUT_BIN" sniff \
	-f tests/fixtures/complex_metrics_500.csv \
	--max-distinct 3 \
	--format json >"$TMP_DIR/exact-limit.json"
jq -e '
	["result", "sip_code", "bitrate_kbps"] as $names |
	[.columns[] | select(.name as $name | $names | index($name)) |
		select(.cardinality.exact and .cardinality.distinct_count == 3)] |
	length == 3
' "$TMP_DIR/exact-limit.json" >/dev/null

"$SNOUT_BIN" sniff \
	-f tests/fixtures/complex_metrics_500.csv \
	--max-distinct 2 \
	--format json >"$TMP_DIR/truncated.json"
jq -e '
	[.columns[] | select(.name == "result")][0].cardinality ==
	{"exact":false,"distinct_count":null,"lower_bound":3}
' "$TMP_DIR/truncated.json" >/dev/null

step "Validate CSV, JSONL, NDJSON, and .snout logical parity"
"$SNOUT_BIN" sniff \
	-f tests/fixtures/complex_metrics_500.jsonl \
	--format json >"$TMP_DIR/jsonl.json"
cp tests/fixtures/complex_metrics_500.jsonl "$TMP_DIR/complex_metrics.ndjson"
"$SNOUT_BIN" sniff \
	-f "$TMP_DIR/complex_metrics.ndjson" \
	--format json >"$TMP_DIR/ndjson.json"
"$SNOUT_BIN" jsonl-import \
	tests/fixtures/complex_metrics_500.jsonl \
	"$TMP_DIR/complex_metrics.snout" >/dev/null
"$SNOUT_BIN" sniff \
	-f "$TMP_DIR/complex_metrics.snout" \
	--format json >"$TMP_DIR/snout.json"

for format in csv jsonl ndjson snout; do
	jq 'del(.table.name, .suggestions[].command)' \
		"$TMP_DIR/$format.json" >"$TMP_DIR/$format.logical.json"
done
cmp "$TMP_DIR/csv.logical.json" "$TMP_DIR/jsonl.logical.json"
cmp "$TMP_DIR/jsonl.logical.json" "$TMP_DIR/ndjson.logical.json"
cmp "$TMP_DIR/jsonl.logical.json" "$TMP_DIR/snout.logical.json"

step "Execute a generated suggestion"
generated_command="$(jq -r '.suggestions[0].command' "$TMP_DIR/csv.json")"
generated_command="${generated_command/#.\/snout/$SNOUT_BIN}"
bash -c "$generated_command" >"$TMP_DIR/generated-query.txt"
grep -q '^group:' "$TMP_DIR/generated-query.txt"
grep -q '^selected_rows: 500$' "$TMP_DIR/generated-query.txt"

step "Validate malformed CLI input"
expect_failure "unsupported format" \
	"$SNOUT_BIN" sniff -f tests/fixtures/simple_metrics.csv --format csv
expect_failure "duplicate option" \
	"$SNOUT_BIN" sniff -f tests/fixtures/simple_metrics.csv --top 2 --top 3
expect_failure "negative option" \
	"$SNOUT_BIN" sniff -f tests/fixtures/simple_metrics.csv --suggestions -1
expect_failure "unknown option" \
	"$SNOUT_BIN" sniff -f tests/fixtures/simple_metrics.csv --unknown
expect_failure "unsupported input" \
	"$SNOUT_BIN" sniff -f tests/fixtures/simple_metrics.log

step "Run sniff benchmark"
"$BENCH_BIN"

printf '\nTASK-0006 validation passed.\n'
