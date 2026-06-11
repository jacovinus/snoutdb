/**
 * SnoutDB Node.js example — uses koffi to call libsnout.
 *
 * Run from the repo root:
 *   cd examples/nodejs && pnpm install && node snout_example.mjs
 */

import koffi from "koffi";
import path from "node:path";
import { fileURLToPath } from "node:url";

// ── Resolve library path ──────────────────────────────────────────────────────
const __dir = path.dirname(fileURLToPath(import.meta.url));
const repoRoot = path.resolve(__dir, "..", "..");
const libName = {
  darwin: "libsnout.dylib",
  linux: "libsnout.so",
  win32: "libsnout.dll",
}[process.platform];
if (!libName) throw new Error(`unsupported platform: ${process.platform}`);
const libPath = path.join(repoRoot, libName);

const lib = koffi.load(libPath);

// ── Type constants ────────────────────────────────────────────────────────────
const SNOUT_TYPE = { STRING: 0, INT64: 1, FLOAT64: 2, BOOL: 3, TIMESTAMP: 4 };
const TYPE_NAMES = { 0: "String", 1: "Int64", 2: "Float64", 3: "Bool", 4: "Timestamp" };

// ── Opaque pointer types ──────────────────────────────────────────────────────
const SnoutTable  = koffi.opaque("SnoutTable");
const SnoutResult = koffi.opaque("SnoutResult");

// ── Bind functions ────────────────────────────────────────────────────────────
const snout_last_error       = lib.func("const char* snout_last_error()");
const snout_import_csv       = lib.func("SnoutTable* snout_import_csv(const char* path)");
const snout_close            = lib.func("void snout_close(SnoutTable* t)");
const snout_row_count        = lib.func("int64 snout_row_count(SnoutTable* t)");
const snout_column_count     = lib.func("int snout_column_count(SnoutTable* t)");
const snout_column_name      = lib.func("const char* snout_column_name(SnoutTable* t, int col)");
const snout_column_type      = lib.func("int snout_column_type(SnoutTable* t, int col)");
const snout_is_null          = lib.func("int snout_is_null(SnoutTable* t, int64 row, int col)");
const snout_get_string       = lib.func("const char* snout_get_string(SnoutTable* t, int64 row, int col)");
const snout_get_int64        = lib.func("int64 snout_get_int64(SnoutTable* t, int64 row, int col)");
const snout_get_float64      = lib.func("double snout_get_float64(SnoutTable* t, int64 row, int col)");

const snout_query            = lib.func("SnoutResult* snout_query(SnoutTable* t, const char* groups, const char* aggregates, const char** where_exprs, int filter_count, const char* sort, int limit)");
const snout_result_free      = lib.func("void snout_result_free(SnoutResult* r)");
const snout_result_row_count = lib.func("int snout_result_row_count(SnoutResult* r)");
const snout_result_col_count = lib.func("int snout_result_col_count(SnoutResult* r)");
const snout_result_col_name  = lib.func("const char* snout_result_col_name(SnoutResult* r, int col)");
const snout_result_col_type  = lib.func("int snout_result_col_type(SnoutResult* r, int col)");
const snout_result_is_null   = lib.func("int snout_result_is_null(SnoutResult* r, int row, int col)");
const snout_result_get_string  = lib.func("const char* snout_result_get_string(SnoutResult* r, int row, int col)");
const snout_result_get_int64   = lib.func("int64 snout_result_get_int64(SnoutResult* r, int row, int col)");
const snout_result_get_float64 = lib.func("double snout_result_get_float64(SnoutResult* r, int row, int col)");

// ── Helpers ───────────────────────────────────────────────────────────────────
function check(ptr, label) {
  if (!ptr) {
    const msg = snout_last_error();
    throw new Error(`${label}: ${msg}`);
  }
  return ptr;
}

function tableValue(t, row, col, type) {
  if (snout_is_null(t, row, col)) return null;
  if (type === SNOUT_TYPE.INT64)   return Number(snout_get_int64(t, row, col));
  if (type === SNOUT_TYPE.FLOAT64) return snout_get_float64(t, row, col);
  return snout_get_string(t, row, col);
}

function resultValue(r, row, col, type) {
  if (snout_result_is_null(r, row, col)) return null;
  if (type === SNOUT_TYPE.INT64)   return Number(snout_result_get_int64(r, row, col));
  if (type === SNOUT_TYPE.FLOAT64) return snout_result_get_float64(r, row, col);
  return snout_result_get_string(r, row, col);
}

function printResultTable(r) {
  const ncols = snout_result_col_count(r);
  const nrows = snout_result_row_count(r);
  const names = Array.from({ length: ncols }, (_, c) => snout_result_col_name(r, c));
  const types = Array.from({ length: ncols }, (_, c) => snout_result_col_type(r, c));

  console.log("   " + names.map(n => n.padEnd(22)).join("  "));
  for (let row = 0; row < nrows; row++) {
    const vals = types.map((type, col) => {
      const v = resultValue(r, row, col, type);
      if (v === null) return "NULL";
      if (typeof v === "number" && !Number.isInteger(v)) return v.toFixed(6);
      return String(v);
    });
    console.log("   " + vals.map(v => v.padEnd(22)).join("  "));
  }
}

// ── Main ──────────────────────────────────────────────────────────────────────
const csvPath = path.join(repoRoot, "tests/fixtures/complex_metrics_500.csv");

console.log("═".repeat(56));
console.log("Node.js → SnoutDB via C ABI");
console.log("═".repeat(56));

// 1. Import CSV
const t = check(snout_import_csv(csvPath), "snout_import_csv");
try {
  const rows  = Number(snout_row_count(t));
  const ncols = snout_column_count(t);

  console.log(`\n1. Schema  (${rows} rows, ${ncols} columns)`);
  console.log(`   ${"column".padEnd(22)} type`);
  console.log(`   ${"─".repeat(22)} ${"─".repeat(10)}`);
  for (let c = 0; c < ncols; c++) {
    const name = snout_column_name(t, c);
    const type = TYPE_NAMES[snout_column_type(t, c)] ?? "?";
    console.log(`   ${name.padEnd(22)} ${type}`);
  }

  // 2. First 3 rows
  console.log("\n2. First 3 rows (call_id, region, mos, result)");
  const interesting = ["call_id", "region", "mos", "result"];
  const colMap = {};
  for (let c = 0; c < ncols; c++) {
    const name = snout_column_name(t, c);
    if (interesting.includes(name)) {
      colMap[name] = { idx: c, type: snout_column_type(t, c) };
    }
  }
  console.log("   " + interesting.map(n => n.padEnd(20)).join("  "));
  for (let row = 0; row < 3; row++) {
    const vals = interesting.map(name => {
      const { idx, type } = colMap[name];
      const v = tableValue(t, row, idx, type);
      if (v === null) return "NULL";
      if (typeof v === "number" && !Number.isInteger(v)) return v.toFixed(2);
      return String(v);
    });
    console.log("   " + vals.map(v => v.padEnd(20)).join("  "));
  }

  // 3. Group query: avg(mos) + avg(jitter_ms) + count by carrier, sorted desc
  console.log("\n3. Query: avg(mos), avg(jitter_ms), count(*) by carrier");
  const r = check(
    snout_query(t, "carrier", "avg=mos avg=jitter_ms count=rows", null, 0, "avg=mos desc", 0),
    "snout_query",
  );
  try { printResultTable(r); } finally { snout_result_free(r); }

  // 4. Filtered query: p95(jitter_ms) by region, only failed calls
  console.log("\n4. Query: p95(jitter_ms) by region  [where result eq failed]");
  const where = ["result", "eq", "failed"];
  const r2 = check(
    snout_query(t, "region", "p95=jitter_ms count=rows", where, where.length, "p95=jitter_ms desc", 0),
    "snout_query with filter",
  );
  try { printResultTable(r2); } finally { snout_result_free(r2); }

} finally {
  snout_close(t);
}

console.log("\n✓ Done\n");
