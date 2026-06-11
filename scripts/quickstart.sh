#!/usr/bin/env bash

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/snoutdb-quickstart.XXXXXX")"
SNOUT_BIN="$TMP_DIR/snout"
INPUT_PATH="$TMP_DIR/requests.csv"
SNOUT_PATH="$TMP_DIR/requests.snout"

cleanup() {
	rm -rf "$TMP_DIR"
}
trap cleanup EXIT

if ! command -v odin >/dev/null 2>&1; then
	printf 'error: odin is required: https://odin-lang.org/docs/install/\n' >&2
	exit 1
fi

cat >"$INPUT_PATH" <<'CSV'
timestamp,service,region,status,latency_ms,bytes
2026-06-11T10:00:00Z,checkout,eu-west,200,48,912
2026-06-11T10:00:01Z,checkout,eu-west,500,380,311
2026-06-11T10:00:02Z,users,us-east,200,27,1402
2026-06-11T10:00:03Z,checkout,us-east,502,441,288
2026-06-11T10:00:04Z,users,eu-west,200,31,1320
2026-06-11T10:00:05Z,search,us-east,200,92,2048
CSV

cd "$ROOT_DIR"
printf '==> Building SnoutDB\n'
odin build ./cmd/snout -out:"$SNOUT_BIN" -o:speed

printf '\n==> Profiling an unfamiliar CSV\n\n'
"$SNOUT_BIN" sniff -f "$INPUT_PATH" --top 3 --suggestions 2

printf '\n==> Finding slow or failing requests by region\n\n'
"$SNOUT_BIN" -f "$INPUT_PATH" group=region -- \
	avg=latency_ms p95=latency_ms count=rows \
	--where status ge 500 \
	--sort p95=latency_ms desc

printf '\n==> Creating and reopening a typed .snout snapshot\n\n'
"$SNOUT_BIN" csv-import "$INPUT_PATH" "$SNOUT_PATH"
"$SNOUT_BIN" info "$SNOUT_PATH"

printf '\nQuickstart completed successfully.\n'
