#!/usr/bin/env bash

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/snoutdb-sniff-demo.XXXXXX")"
SNOUT_BIN="$TMP_DIR/snout"
INPUT_PATH="${1:-tests/fixtures/complex_metrics_500.csv}"

cleanup() {
	rm -rf "$TMP_DIR"
}
trap cleanup EXIT

if ! command -v odin >/dev/null 2>&1; then
	printf 'error: odin is required\n' >&2
	exit 1
fi

cd "$ROOT_DIR"
odin build ./cmd/snout -out:"$SNOUT_BIN" -o:speed

printf '\n==> Default table report\n\n'
"$SNOUT_BIN" sniff -f "$INPUT_PATH"

printf '\n==> Reduced report: top 3 values and 2 suggestions\n\n'
"$SNOUT_BIN" sniff \
	-f "$INPUT_PATH" \
	--top 3 \
	--suggestions 2

printf '\n==> JSON report summary\n\n'
if command -v jq >/dev/null 2>&1; then
	"$SNOUT_BIN" sniff -f "$INPUT_PATH" --format json |
		jq '{
			version,
			table,
			role_counts,
			suggestions: [.suggestions[] | {reason, command}],
			warnings
		}'
else
	"$SNOUT_BIN" sniff -f "$INPUT_PATH" --format json
fi

printf '\n==> Cardinality truncation example\n\n'
if command -v jq >/dev/null 2>&1; then
	"$SNOUT_BIN" sniff -f "$INPUT_PATH" --max-distinct 10 --format json |
		jq '[
			.columns[] |
			select(.cardinality.exact == false) |
			{name, cardinality}
		][0:5]'
else
	"$SNOUT_BIN" sniff -f "$INPUT_PATH" --max-distinct 10
fi
