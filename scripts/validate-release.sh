#!/usr/bin/env bash

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/snoutdb-release.XXXXXX")"
SNOUT_BIN="$TMP_DIR/snout"

cleanup() {
	rm -rf "$TMP_DIR"
}
trap cleanup EXIT

step() {
	printf '\n==> %s\n' "$1"
}

require_command() {
	if ! command -v "$1" >/dev/null 2>&1; then
		printf 'error: required command not found: %s\n' "$1" >&2
		exit 1
	fi
}

require_command odin
require_command python3

cd "$ROOT_DIR"

step "Validate canonical version"
VERSION="$(tr -d '[:space:]' < VERSION)"
if [[ ! "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+(-[0-9A-Za-z.-]+)?(\+[0-9A-Za-z.-]+)?$ ]]; then
	printf 'error: invalid VERSION: %s\n' "$VERSION" >&2
	exit 1
fi

step "Build CLI with strict checks"
odin build ./cmd/snout -out:"$SNOUT_BIN" -vet -strict-style
test "$("$SNOUT_BIN" version)" = "SnoutDB $VERSION"
test "$("$SNOUT_BIN" --version)" = "SnoutDB $VERSION"
test "$("$SNOUT_BIN" -v)" = "SnoutDB $VERSION"

step "Run complete test suite with strict checks and memory tracking"
odin test ./tests -out:"$TMP_DIR/snout_tests" -vet -strict-style

step "Validate ingestion and storage"
"$SNOUT_BIN" csv-import tests/fixtures/simple_metrics.csv "$TMP_DIR/csv.snout" >/dev/null
"$SNOUT_BIN" jsonl-import tests/fixtures/simple_events.jsonl "$TMP_DIR/jsonl.snout" >/dev/null
"$SNOUT_BIN" log-import tests/fixtures/access.log "$TMP_DIR/log.snout" >/dev/null
"$SNOUT_BIN" info "$TMP_DIR/csv.snout" >"$TMP_DIR/info.txt"
grep -q '^rows: 5$' "$TMP_DIR/info.txt"

step "Validate sniff and query"
"$SNOUT_BIN" sniff -f tests/fixtures/simple_metrics.csv --format json >"$TMP_DIR/sniff.json"
python3 -c 'import json,sys; assert json.load(open(sys.argv[1]))["version"] == 1' \
	"$TMP_DIR/sniff.json"
"$SNOUT_BIN" -f "$TMP_DIR/csv.snout" group=endpoint -- count=rows \
	--sort count=rows desc >"$TMP_DIR/query.txt"
grep -q '/checkout' "$TMP_DIR/query.txt"

step "Validate transform, merge, and rollup"
"$SNOUT_BIN" transform "$TMP_DIR/csv.snout" "$TMP_DIR/transformed.snout" \
	rename=endpoint:path
"$SNOUT_BIN" consolidate "$TMP_DIR/csv.snout" "$TMP_DIR/csv.snout" \
	"$TMP_DIR/consolidated.snout"
"$SNOUT_BIN" rollup "$TMP_DIR/csv.snout" "$TMP_DIR/csv.snout" \
	"$TMP_DIR/rollup.snout" group=endpoint -- count=rows avg=latency_ms
"$SNOUT_BIN" info "$TMP_DIR/rollup.snout" >"$TMP_DIR/rollup-info.txt"
grep -q '^  avg_latency_ms ' "$TMP_DIR/rollup-info.txt"

step "Build and smoke-test C ABI"
odin build ./cabi -build-mode:shared -out:libsnout -o:speed -vet -strict-style
python3 tests/cabi_smoke.py

step "Run available language examples"
python3 examples/python/snout_example.py >/dev/null
if command -v go >/dev/null 2>&1; then
	(cd examples/go && go run main.go >/dev/null)
fi
if command -v node >/dev/null 2>&1 &&
   test -d examples/nodejs/node_modules/koffi; then
	(cd examples/nodejs && node snout_example.mjs >/dev/null)
fi

printf '\nSnoutDB v%s pre-release validation passed.\n' "$VERSION"
