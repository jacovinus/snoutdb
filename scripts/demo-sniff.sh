#!/usr/bin/env bash

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/snoutdb-sniff-demo.XXXXXX")"
SNOUT_BIN="$TMP_DIR/snout"
INPUT_PATH="${1:-$TMP_DIR/demo.csv}"

cleanup() {
	rm -rf "$TMP_DIR"
}
trap cleanup EXIT

if ! command -v odin >/dev/null 2>&1; then
	printf 'error: odin is required\n' >&2
	exit 1
fi

cd "$ROOT_DIR"
if [[ "$INPUT_PATH" == "$TMP_DIR/demo.csv" ]]; then
	cat >"$INPUT_PATH" <<'CSV'
timestamp,endpoint,region,status,latency_ms,bytes
2026-06-11T10:00:00Z,/checkout,eu-west,200,48,912
2026-06-11T10:00:01Z,/checkout,eu-west,500,380,311
2026-06-11T10:00:02Z,/users,us-east,200,27,1402
2026-06-11T10:00:03Z,/checkout,us-east,502,441,288
2026-06-11T10:00:04Z,/users,eu-west,200,31,1320
2026-06-11T10:00:05Z,/search,us-east,200,92,2048
CSV
fi
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
