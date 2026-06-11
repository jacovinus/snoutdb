"""
SnoutDB Python example — uses ctypes to call libsnout directly.

Run from the repo root:
  python3 examples/python/snout_example.py
"""

import ctypes
import os
import sys

# ── Load library ──────────────────────────────────────────────────────────────

_root = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
if sys.platform == "darwin":
    _lib_name = "libsnout.dylib"
elif sys.platform == "win32":
    _lib_name = "libsnout.dll"
else:
    _lib_name = "libsnout.so"
_lib_path = os.path.join(_root, _lib_name)

try:
    lib = ctypes.CDLL(_lib_path)
except OSError as e:
    print(f"error: could not load {_lib_path}: {e}", file=sys.stderr)
    sys.exit(1)

# ── Type declarations ─────────────────────────────────────────────────────────

class SnoutTable(ctypes.Structure):
    pass

class SnoutResult(ctypes.Structure):
    pass

SnoutTablePtr  = ctypes.POINTER(SnoutTable)
SnoutResultPtr = ctypes.POINTER(SnoutResult)

SNOUT_TYPE_STRING    = 0
SNOUT_TYPE_INT64     = 1
SNOUT_TYPE_FLOAT64   = 2
SNOUT_TYPE_BOOL      = 3
SNOUT_TYPE_TIMESTAMP = 4

TYPE_NAMES = {
    SNOUT_TYPE_STRING:    "String",
    SNOUT_TYPE_INT64:     "Int64",
    SNOUT_TYPE_FLOAT64:   "Float64",
    SNOUT_TYPE_BOOL:      "Bool",
    SNOUT_TYPE_TIMESTAMP: "Timestamp",
}

# ── Bind functions ────────────────────────────────────────────────────────────

lib.snout_last_error.restype  = ctypes.c_char_p
lib.snout_last_error.argtypes = []

lib.snout_open.restype        = SnoutTablePtr
lib.snout_open.argtypes       = [ctypes.c_char_p]

lib.snout_import_csv.restype  = SnoutTablePtr
lib.snout_import_csv.argtypes = [ctypes.c_char_p]

lib.snout_close.restype       = None
lib.snout_close.argtypes      = [SnoutTablePtr]

lib.snout_row_count.restype   = ctypes.c_int64
lib.snout_row_count.argtypes  = [SnoutTablePtr]

lib.snout_column_count.restype  = ctypes.c_int
lib.snout_column_count.argtypes = [SnoutTablePtr]

lib.snout_column_name.restype   = ctypes.c_char_p
lib.snout_column_name.argtypes  = [SnoutTablePtr, ctypes.c_int]

lib.snout_column_type.restype   = ctypes.c_int
lib.snout_column_type.argtypes  = [SnoutTablePtr, ctypes.c_int]

lib.snout_is_null.restype     = ctypes.c_int
lib.snout_is_null.argtypes    = [SnoutTablePtr, ctypes.c_int64, ctypes.c_int]

lib.snout_get_string.restype  = ctypes.c_char_p
lib.snout_get_string.argtypes = [SnoutTablePtr, ctypes.c_int64, ctypes.c_int]

lib.snout_get_int64.restype   = ctypes.c_int64
lib.snout_get_int64.argtypes  = [SnoutTablePtr, ctypes.c_int64, ctypes.c_int]

lib.snout_get_float64.restype  = ctypes.c_double
lib.snout_get_float64.argtypes = [SnoutTablePtr, ctypes.c_int64, ctypes.c_int]

lib.snout_query.restype   = SnoutResultPtr
lib.snout_query.argtypes  = [
    SnoutTablePtr,         # table
    ctypes.c_char_p,       # groups
    ctypes.c_char_p,       # aggregates
    ctypes.POINTER(ctypes.c_char_p),  # where_exprs
    ctypes.c_int,          # filter_count
    ctypes.c_char_p,       # sort
    ctypes.c_int,          # limit
]

lib.snout_result_free.restype  = None
lib.snout_result_free.argtypes = [SnoutResultPtr]

lib.snout_result_row_count.restype   = ctypes.c_int
lib.snout_result_row_count.argtypes  = [SnoutResultPtr]

lib.snout_result_col_count.restype   = ctypes.c_int
lib.snout_result_col_count.argtypes  = [SnoutResultPtr]

lib.snout_result_col_name.restype    = ctypes.c_char_p
lib.snout_result_col_name.argtypes   = [SnoutResultPtr, ctypes.c_int]

lib.snout_result_col_type.restype    = ctypes.c_int
lib.snout_result_col_type.argtypes   = [SnoutResultPtr, ctypes.c_int]

lib.snout_result_is_null.restype     = ctypes.c_int
lib.snout_result_is_null.argtypes    = [SnoutResultPtr, ctypes.c_int, ctypes.c_int]

lib.snout_result_get_string.restype  = ctypes.c_char_p
lib.snout_result_get_string.argtypes = [SnoutResultPtr, ctypes.c_int, ctypes.c_int]

lib.snout_result_get_int64.restype   = ctypes.c_int64
lib.snout_result_get_int64.argtypes  = [SnoutResultPtr, ctypes.c_int, ctypes.c_int]

lib.snout_result_get_float64.restype  = ctypes.c_double
lib.snout_result_get_float64.argtypes = [SnoutResultPtr, ctypes.c_int, ctypes.c_int]

# ── Helpers ───────────────────────────────────────────────────────────────────

def _check(ptr, label):
    if not ptr:
        err = lib.snout_last_error()
        msg = err.decode() if err else "unknown error"
        raise RuntimeError(f"{label}: {msg}")
    return ptr

def _result_value(r, row, col, col_type):
    if lib.snout_result_is_null(r, row, col):
        return None
    if col_type == SNOUT_TYPE_INT64:
        return lib.snout_result_get_int64(r, row, col)
    if col_type == SNOUT_TYPE_FLOAT64:
        return lib.snout_result_get_float64(r, row, col)
    raw = lib.snout_result_get_string(r, row, col)
    return raw.decode() if raw else None

def _table_value(t, row, col, col_type):
    if lib.snout_is_null(t, row, col):
        return None
    if col_type == SNOUT_TYPE_INT64:
        return lib.snout_get_int64(t, row, col)
    if col_type == SNOUT_TYPE_FLOAT64:
        return lib.snout_get_float64(t, row, col)
    raw = lib.snout_get_string(t, row, col)
    return raw.decode() if raw else None

def _make_where(filters):
    """filters: list of (col, op, val) tuples. is-null/not-null: (col, op)."""
    strs = []
    for f in filters:
        strs.extend(f)
    arr_type = ctypes.c_char_p * len(strs)
    arr = arr_type(*[s.encode() for s in strs])
    return arr, len(strs)

# ── Main ──────────────────────────────────────────────────────────────────────

def main():
    csv_path = os.path.join(_root, "tests/fixtures/complex_metrics_500.csv")

    print("═" * 56)
    print("Python → SnoutDB via C ABI")
    print("═" * 56)

    # 1. Import CSV
    t = _check(lib.snout_import_csv(csv_path.encode()), "snout_import_csv")
    try:
        rows = lib.snout_row_count(t)
        ncols = lib.snout_column_count(t)
        print(f"\n1. Schema  ({rows} rows, {ncols} columns)")
        print(f"   {'column':<22} {'type'}")
        print(f"   {'-'*22} {'-'*10}")
        for c in range(ncols):
            name = lib.snout_column_name(t, c).decode()
            typ  = TYPE_NAMES.get(lib.snout_column_type(t, c), "?")
            print(f"   {name:<22} {typ}")

        # 2. Read first 3 rows
        print(f"\n2. First 3 rows (call_id, region, jitter_ms, result)")
        cols_of_interest = ["call_id", "region", "jitter_ms", "result"]
        col_map = {}
        for c in range(ncols):
            name = lib.snout_column_name(t, c).decode()
            if name in cols_of_interest:
                col_map[name] = (c, lib.snout_column_type(t, c))
        header = "   " + "  ".join(f"{n:<20}" for n in cols_of_interest)
        print(header)
        for row in range(3):
            vals = []
            for name in cols_of_interest:
                c, ctype = col_map[name]
                v = _table_value(t, row, c, ctype)
                vals.append(str(v) if v is not None else "NULL")
            print("   " + "  ".join(f"{v:<20}" for v in vals))

        # 3. Query: avg jitter + count, grouped by region, sorted desc, limit 6
        print("\n3. Query: avg(jitter_ms) + count(*) by region  [sorted desc, limit 6]")
        r = _check(
            lib.snout_query(
                t,
                b"region",
                b"avg=jitter_ms count=rows",
                None, 0,
                b"avg=jitter_ms desc",
                6,
            ),
            "snout_query",
        )
        try:
            rcols = lib.snout_result_col_count(r)
            rrows = lib.snout_result_row_count(r)
            col_names = [lib.snout_result_col_name(r, c).decode() for c in range(rcols)]
            col_types = [lib.snout_result_col_type(r, c) for c in range(rcols)]
            header = "   " + "  ".join(f"{n:<20}" for n in col_names)
            print(header)
            for row in range(rrows):
                vals = [str(_result_value(r, row, c, col_types[c])) for c in range(rcols)]
                print("   " + "  ".join(f"{v:<20}" for v in vals))
        finally:
            lib.snout_result_free(r)

        # 4. Query with filter: only completed calls
        print("\n4. Query: p95(jitter_ms) by codec  [where result eq completed]")
        where, wcount = _make_where([("result", "eq", "completed")])
        r2 = _check(
            lib.snout_query(
                t,
                b"codec",
                b"p95=jitter_ms count=rows",
                where, wcount,
                b"p95=jitter_ms desc",
                0,
            ),
            "snout_query with filter",
        )
        try:
            rcols = lib.snout_result_col_count(r2)
            rrows = lib.snout_result_row_count(r2)
            col_names = [lib.snout_result_col_name(r2, c).decode() for c in range(rcols)]
            col_types = [lib.snout_result_col_type(r2, c) for c in range(rcols)]
            header = "   " + "  ".join(f"{n:<20}" for n in col_names)
            print(header)
            for row in range(rrows):
                vals = [str(_result_value(r2, row, c, col_types[c])) for c in range(rcols)]
                print("   " + "  ".join(f"{v:<20}" for v in vals))
        finally:
            lib.snout_result_free(r2)

    finally:
        lib.snout_close(t)

    print("\n✓ Done\n")

if __name__ == "__main__":
    main()
