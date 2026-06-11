#!/usr/bin/env python3

import ctypes
import os
import sys


ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))


def library_name():
    if sys.platform == "darwin":
        return "libsnout.dylib"
    if sys.platform == "win32":
        return "libsnout.dll"
    return "libsnout.so"


lib = ctypes.CDLL(os.path.join(ROOT, library_name()))

lib.snout_last_error.restype = ctypes.c_char_p
lib.snout_import_csv.restype = ctypes.c_void_p
lib.snout_import_csv.argtypes = [ctypes.c_char_p]
lib.snout_close.argtypes = [ctypes.c_void_p]
lib.snout_query.restype = ctypes.c_void_p
lib.snout_query.argtypes = [
    ctypes.c_void_p,
    ctypes.c_char_p,
    ctypes.c_char_p,
    ctypes.POINTER(ctypes.c_char_p),
    ctypes.c_int,
    ctypes.c_char_p,
    ctypes.c_int,
]
lib.snout_result_free.argtypes = [ctypes.c_void_p]
lib.snout_result_row_count.restype = ctypes.c_int
lib.snout_result_row_count.argtypes = [ctypes.c_void_p]
lib.snout_result_is_null.restype = ctypes.c_int
lib.snout_result_is_null.argtypes = [ctypes.c_void_p, ctypes.c_int, ctypes.c_int]
lib.snout_result_get_string.restype = ctypes.c_char_p
lib.snout_result_get_string.argtypes = [ctypes.c_void_p, ctypes.c_int, ctypes.c_int]


def last_error():
    raw = lib.snout_last_error()
    return raw.decode() if raw else "unknown error"


fixture = os.path.join(ROOT, "tests", "fixtures", "simple_metrics.csv")
table = lib.snout_import_csv(fixture.encode())
if not table:
    raise RuntimeError(f"snout_import_csv: {last_error()}")

try:
    result = lib.snout_query(
        table,
        b"endpoint",
        b"count=rows",
        None,
        0,
        b"count=rows desc",
        1,
    )
    if not result:
        raise RuntimeError(f"snout_query: {last_error()}")
    try:
        assert lib.snout_result_row_count(result) == 1
        assert lib.snout_result_is_null(result, 1, 0) == 1
        assert lib.snout_result_get_string(result, 1, 0) is None
    finally:
        lib.snout_result_free(result)

    invalid = lib.snout_query(
        table,
        b"endpoint",
        b"count=rows",
        None,
        0,
        None,
        -1,
    )
    assert not invalid
    assert last_error() == "invalid result limit"
finally:
    lib.snout_close(table)

print("C ABI smoke test passed.")
