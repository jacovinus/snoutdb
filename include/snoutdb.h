/*
 * snoutdb.h — SnoutDB C API
 *
 * This ABI is experimental in SnoutDB v0.1.0 and may change before v1.0.0.
 *
 * All functions are thread-safe for independent handles. Do not share a single
 * SnoutTable* or SnoutResult* across threads without external synchronisation.
 *
 * Memory ownership:
 *   - SnoutTable*  is owned by the caller; free with snout_close().
 *   - SnoutResult* is owned by the caller; free with snout_result_free().
 *   - const char*  returned by get/name/error functions is valid until the
 *     next call to any snout_* function on the SAME thread. Copy if needed.
 */

#ifndef SNOUTDB_H
#define SNOUTDB_H

#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

/* ---- Opaque handles ------------------------------------------------------- */
typedef struct SnoutTable_  SnoutTable;
typedef struct SnoutResult_ SnoutResult;

/* ---- Column type constants ------------------------------------------------ */
#define SNOUT_TYPE_STRING    0
#define SNOUT_TYPE_INT64     1
#define SNOUT_TYPE_FLOAT64   2
#define SNOUT_TYPE_BOOL      3
#define SNOUT_TYPE_TIMESTAMP 4  /* stored as ISO-8601 string */
#define SNOUT_TYPE_UNKNOWN   5

/* ---- Table lifecycle ------------------------------------------------------ */

/* Open an existing .snout file. Returns NULL on error; call snout_last_error(). */
SnoutTable* snout_open(const char* path);

/* Import a CSV file into an in-memory table. Returns NULL on error. */
SnoutTable* snout_import_csv(const char* path);

/* Import a JSONL / NDJSON file into an in-memory table. Returns NULL on error. */
SnoutTable* snout_import_jsonl(const char* path);

/* Free all memory associated with a table. Passing NULL is a no-op. */
void snout_close(SnoutTable* t);

/* ---- Schema -------------------------------------------------------------- */

/* Number of data rows in the table. */
int64_t snout_row_count(SnoutTable* t);

/* Number of columns. */
int snout_column_count(SnoutTable* t);

/* Name of column at zero-based index col. Returns NULL if out of range. */
const char* snout_column_name(SnoutTable* t, int col);

/* Type of column at zero-based index col. Returns SNOUT_TYPE_UNKNOWN if out of range. */
int snout_column_type(SnoutTable* t, int col);

/* ---- Value access -------------------------------------------------------- */

/* Returns 1 if the cell is null, 0 otherwise. */
int snout_is_null(SnoutTable* t, int64_t row, int col);

/* String value at (row, col). Returns NULL if null or wrong type.
   The pointer is valid until the next snout_get_string / snout_result_get_string call. */
const char* snout_get_string(SnoutTable* t, int64_t row, int col);

/* Integer value at (row, col). Returns 0 if null or wrong type. */
int64_t snout_get_int64(SnoutTable* t, int64_t row, int col);

/* Float value at (row, col). Returns 0.0 if null or wrong type. */
double snout_get_float64(SnoutTable* t, int64_t row, int col);

/* Boolean value at (row, col). Returns 0 if null or wrong type. */
int snout_get_bool(SnoutTable* t, int64_t row, int col);

/* ---- Query --------------------------------------------------------------- */

/*
 * Execute a group-by aggregation and return a result table.
 *
 *   groups      — comma-separated group column names, e.g. "region,carrier"
 *   aggregates  — space-separated agg=col expressions, e.g. "avg=jitter_ms count=rows"
 *   where_exprs — array of filter token triplets: col, op, val (or col, op for is-null/not-null)
 *                 e.g. {"result","eq","completed","jitter_ms","gt","40"}
 *                 Pass NULL or filter_count=0 for no filters.
 *   filter_count— total number of strings in where_exprs (not triplet count)
 *   sort        — "agg=col asc|desc", e.g. "avg=jitter_ms desc". NULL for default order.
 *   limit       — maximum number of result rows. 0 = no limit.
 *                 Valid range: 0 through 1,000,000.
 *
 * Returns NULL on error. Free with snout_result_free().
 */
SnoutResult* snout_query(SnoutTable*   t,
                         const char*   groups,
                         const char*   aggregates,
                         const char**  where_exprs,
                         int           filter_count,
                         const char*   sort,
                         int           limit);

/* Free all memory associated with a result. Passing NULL is a no-op. */
void snout_result_free(SnoutResult* r);

/* ---- Result access ------------------------------------------------------- */

int         snout_result_row_count(SnoutResult* r);
int         snout_result_col_count(SnoutResult* r);
const char* snout_result_col_name(SnoutResult* r, int col);
int         snout_result_col_type(SnoutResult* r, int col);
int         snout_result_is_null(SnoutResult* r, int row, int col);

/* String value; valid until next snout_get_string / snout_result_get_string call. */
const char* snout_result_get_string(SnoutResult* r, int row, int col);
int64_t     snout_result_get_int64(SnoutResult* r, int row, int col);
double      snout_result_get_float64(SnoutResult* r, int row, int col);
int         snout_result_get_bool(SnoutResult* r, int row, int col);

/* ---- Error --------------------------------------------------------------- */

/*
 * Returns a human-readable description of the last error that occurred on
 * this thread. The pointer is valid until the next snout_* call on this thread.
 * Returns an empty string if no error has occurred.
 */
const char* snout_last_error(void);

#ifdef __cplusplus
}
#endif

#endif /* SNOUTDB_H */
