#!/usr/bin/env bash
# TASK-0015 benchmark: log ingestion and direct sniff profiling.
# Usage: ./scripts/benchmark-task-0015.sh [row-count]
# Default row count is 50,000. Generates all four fixtures when missing.
set -euo pipefail

cd "$(dirname "$0")/.."

ROW_COUNT="${1:-50000}"
CLF_FIXTURE="tests/fixtures/access_log_${ROW_COUNT}.log"
COMBINED_FIXTURE="tests/fixtures/combined_log_${ROW_COUNT}.log"
LOGFMT_FIXTURE="tests/fixtures/app_log_${ROW_COUNT}.log"
SYSLOG_FIXTURE="tests/fixtures/syslog_${ROW_COUNT}.log"

if [[ ! -f "$CLF_FIXTURE" ]]; then
  echo "Generating log fixtures (${ROW_COUNT} rows each)..." >&2
  node tools/generate_logs.mjs "$ROW_COUNT"
fi

echo "== Building release binary (-o:speed) ==" >&2
odin build ./cmd/snout -out:snout -o:speed

echo
echo "== CLI gates (time + peak memory) =="

echo "-- log-info CLF (${ROW_COUNT} rows)"
/usr/bin/time -l ./snout log-info "$CLF_FIXTURE" > /dev/null 2> /tmp/snout_bench_log_clf_info.txt || true
grep "Elapsed" /tmp/snout_bench_log_clf_info.txt || true
grep -E "real|maximum resident" /tmp/snout_bench_log_clf_info.txt

echo "-- log-info Combined (${ROW_COUNT} rows)"
/usr/bin/time -l ./snout log-info "$COMBINED_FIXTURE" > /dev/null 2> /tmp/snout_bench_log_combined_info.txt || true
grep "Elapsed" /tmp/snout_bench_log_combined_info.txt || true
grep -E "real|maximum resident" /tmp/snout_bench_log_combined_info.txt

echo "-- log-info Logfmt (${ROW_COUNT} rows)"
/usr/bin/time -l ./snout log-info "$LOGFMT_FIXTURE" --format logfmt > /dev/null 2> /tmp/snout_bench_log_logfmt_info.txt || true
grep "Elapsed" /tmp/snout_bench_log_logfmt_info.txt || true
grep -E "real|maximum resident" /tmp/snout_bench_log_logfmt_info.txt

echo "-- log-info Syslog (${ROW_COUNT} rows)"
/usr/bin/time -l ./snout log-info "$SYSLOG_FIXTURE" --format syslog > /dev/null 2> /tmp/snout_bench_log_syslog_info.txt || true
grep "Elapsed" /tmp/snout_bench_log_syslog_info.txt || true
grep -E "real|maximum resident" /tmp/snout_bench_log_syslog_info.txt

echo
echo "== Sniff gates =="

echo "-- sniff CLF (auto-detect + profile)"
/usr/bin/time -l ./snout sniff -f "$CLF_FIXTURE" --format json > /dev/null 2> /tmp/snout_bench_sniff_clf.txt || true
grep "Elapsed" /tmp/snout_bench_sniff_clf.txt || true
grep -E "real|maximum resident" /tmp/snout_bench_sniff_clf.txt

echo "-- sniff Combined"
/usr/bin/time -l ./snout sniff -f "$COMBINED_FIXTURE" --format json > /dev/null 2> /tmp/snout_bench_sniff_combined.txt || true
grep "Elapsed" /tmp/snout_bench_sniff_combined.txt || true
grep -E "real|maximum resident" /tmp/snout_bench_sniff_combined.txt

echo "-- sniff Logfmt"
/usr/bin/time -l ./snout sniff -f "$LOGFMT_FIXTURE" --logformat logfmt --format json > /dev/null 2> /tmp/snout_bench_sniff_logfmt.txt || true
grep "Elapsed" /tmp/snout_bench_sniff_logfmt.txt || true
grep -E "real|maximum resident" /tmp/snout_bench_sniff_logfmt.txt

echo "-- sniff Syslog"
/usr/bin/time -l ./snout sniff -f "$SYSLOG_FIXTURE" --logformat syslog --format json > /dev/null 2> /tmp/snout_bench_sniff_syslog.txt || true
grep "Elapsed" /tmp/snout_bench_sniff_syslog.txt || true
grep -E "real|maximum resident" /tmp/snout_bench_sniff_syslog.txt

echo
echo "== Import gates =="

TMP_CLF="/tmp/snout_bench_clf_${ROW_COUNT}.snout"
TMP_LOGFMT="/tmp/snout_bench_logfmt_${ROW_COUNT}.snout"

echo "-- log-import CLF → .snout"
/usr/bin/time -l ./snout log-import "$CLF_FIXTURE" "$TMP_CLF" > /dev/null 2> /tmp/snout_bench_log_import_clf.txt || true
grep "Elapsed" /tmp/snout_bench_log_import_clf.txt || true
grep -E "real|maximum resident" /tmp/snout_bench_log_import_clf.txt

echo "-- log-import Logfmt → .snout"
/usr/bin/time -l ./snout log-import "$LOGFMT_FIXTURE" "$TMP_LOGFMT" --format logfmt > /dev/null 2> /tmp/snout_bench_log_import_logfmt.txt || true
grep "Elapsed" /tmp/snout_bench_log_import_logfmt.txt || true
grep -E "real|maximum resident" /tmp/snout_bench_log_import_logfmt.txt

rm -f "$TMP_CLF" "$TMP_LOGFMT"
