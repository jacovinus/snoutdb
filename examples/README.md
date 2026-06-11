# SnoutDB — Language Examples

SnoutDB exposes a C shared library (`libsnout`) so you can query data files from any language with C FFI. These examples load the same CSV fixture, inspect its schema, read individual rows, and run two group-by queries — one plain, one with a filter — using the identical C API in each language.

## Contents

- [Build the library](#build-the-library)
- [Python](#python)
- [Go](#go)
- [Node.js](#nodejs)
- [API concepts](#api-concepts)

---

## Build the library

All three examples load the platform library from the repo root:
`libsnout.dylib` on macOS, `libsnout.so` on Linux, or `libsnout.dll` on
Windows. Build it once before running any example:

```bash
./scripts/build-cabi.sh
```

This produces `libsnout.dylib` (macOS) or `libsnout.so` (Linux). The full header is at [`include/snoutdb.h`](../include/snoutdb.h).

---

## Python

**File:** [`python/snout_example.py`](python/snout_example.py)  
**Binding:** `ctypes` (stdlib — no install required)

```bash
python3 examples/python/snout_example.py
```

The example binds all 25 library functions manually via `ctypes`, then:

1. Imports `tests/fixtures/complex_metrics_500.csv` with `snout_import_csv`
2. Prints the full schema (column names and types)
3. Reads the first 3 rows cell by cell
4. Queries `avg(jitter_ms) + count(*)` grouped by `region`, sorted descending, limit 6
5. Queries `p95(jitter_ms) + count(*)` grouped by `codec` with `WHERE result = 'completed'`

**Key patterns:**

```python
import ctypes

lib = ctypes.CDLL("libsnout.dylib")  # use .so on Linux or .dll on Windows
lib.snout_import_csv.restype  = ctypes.POINTER(SnoutTable)
lib.snout_import_csv.argtypes = [ctypes.c_char_p]

t = lib.snout_import_csv(b"data.csv")
rows = lib.snout_row_count(t)

# WHERE filter: list of flat triplets [col, op, val, ...]
where = (ctypes.c_char_p * 3)(b"result", b"eq", b"completed")
r = lib.snout_query(t, b"region", b"avg=jitter_ms count=rows",
                    where, 3, b"avg=jitter_ms desc", 0)
lib.snout_result_free(r)
lib.snout_close(t)
```

---

## Go

**File:** [`go/main.go`](go/main.go)  
**Binding:** `cgo` (built-in)

```bash
cd examples/go && go run main.go
```

Uses `cgo` with `CFLAGS` and `LDFLAGS` directives pointing at `../../include`
and `../../` (the repo root where the platform `libsnout` library lives). No
extra dependencies.

The example demonstrates the same four operations as the Python one:

1. Schema inspection
2. Row-by-row cell access
3. `avg(mos) + avg(jitter_ms) + count(*)` by `carrier`
4. `p95(jitter_ms) + count(*)` by `region` where `result = 'failed'`

**Key patterns:**

```go
/*
#cgo CFLAGS:  -I../../include
#cgo LDFLAGS: -L../../ -lsnout -Wl,-rpath,../../
#include "snoutdb.h"
#include <stdlib.h>
*/
import "C"
import "unsafe"

t := C.snout_import_csv(C.CString(csvPath))
defer C.snout_close(t)

// WHERE filter: C array of *char
where := []*C.char{C.CString("result"), C.CString("eq"), C.CString("failed")}
r := C.snout_query(t, C.CString("region"), C.CString("p95=jitter_ms count=rows"),
    (**C.char)(unsafe.Pointer(&where[0])), 3,
    C.CString("p95=jitter_ms desc"), 0)
defer C.snout_result_free(r)
```

---

## Node.js

**File:** [`nodejs/snout_example.mjs`](nodejs/snout_example.mjs)  
**Binding:** [`koffi`](https://koffi.dev) — modern FFI for Node.js

```bash
cd examples/nodejs && pnpm install && node snout_example.mjs
```

Declares each function with `koffi`'s string-based type DSL, which keeps the binding code concise. Uses `koffi.opaque()` for the two handle types (`SnoutTable`, `SnoutResult`).

The example covers the same four operations as the other two:

1. Schema
2. First 3 rows
3. `avg(mos) + avg(jitter_ms) + count(*)` by `carrier`
4. `p95(jitter_ms) + count(*)` by `region` where `result = 'failed'`

**Key patterns:**

```js
import koffi from "koffi";

const lib = koffi.load(process.platform === "darwin" ? "libsnout.dylib" : "libsnout.so");
const SnoutTable  = koffi.opaque("SnoutTable");
const SnoutResult = koffi.opaque("SnoutResult");

const snout_import_csv = lib.func("SnoutTable* snout_import_csv(const char* path)");
const snout_query      = lib.func(
  "SnoutResult* snout_query(SnoutTable* t, const char* groups, const char* aggregates," +
  " const char** where_exprs, int filter_count, const char* sort, int limit)"
);

const t = snout_import_csv(csvPath);
// WHERE filter: plain JS array of strings
const where = ["result", "eq", "failed"];
const r = snout_query(t, "region", "p95=jitter_ms count=rows",
                      where, where.length, "p95=jitter_ms desc", 0);
```

---

## API concepts

All three examples use the same three-step pattern:

**1. Open a table**

```
snout_import_csv(path)    → SnoutTable*
snout_import_jsonl(path)  → SnoutTable*
snout_open(path)          → SnoutTable*   (.snout files)
```

**2. Query it**

```
snout_query(table, groups, aggregates, where_exprs, filter_count, sort, limit)
  → SnoutResult*
```

- `groups` — comma-separated column names: `"region,carrier"`
- `aggregates` — space-separated `fn=col` expressions: `"avg=jitter_ms count=rows p95=mos"`
- `where_exprs` — flat array of triplets: `["col", "op", "val", ...]`
  - operators: `eq`, `ne`, `lt`, `le`, `gt`, `ge`, `is-null`, `not-null`
- `sort` — `"agg=col asc|desc"`, e.g. `"avg=jitter_ms desc"`
- `limit` — `0` means no limit

Aggregate column names in results follow the pattern `fn_col` (e.g. `avg_jitter_ms`, `p95_mos`), except `count=rows` which produces `count`.

**3. Read results and free**

```
snout_result_row_count(r)           → int
snout_result_col_count(r)           → int
snout_result_col_name(r, col)       → const char*
snout_result_col_type(r, col)       → int   (SNOUT_TYPE_* constant)
snout_result_get_string(r, row, col)
snout_result_get_int64(r, row, col)
snout_result_get_float64(r, row, col)
snout_result_free(r)
snout_close(t)
```

String pointers returned by get/name functions are valid until the next `snout_get_string` or `snout_result_get_string` call on the same thread. Copy if you need them to outlive the next call.

On error, table/result functions return `NULL`. Call `snout_last_error()` to get a description.
