/*
 * cabi/cabi.odin — SnoutDB C ABI implementation.
 *
 * Build as a shared library:
 *   odin build ./cabi -build-mode:shared -out:libsnout
 *
 * Exports every function declared in include/snoutdb.h.
 * All public identifiers use the "c" calling convention.
 */
package cabi

import "base:runtime"
import "core:c"
import "core:strings"
import snout_core "../core"
import ingest "../ingest"
import storage "../storage"
import snout_merge "../merge"
import "core:fmt"
import query "../query"

// ---- Internal handle types -------------------------------------------------

// Both SnoutTable and SnoutResult are exposed as the same opaque wrapper.
// The caller never sees the Odin struct layout.
Handle :: struct {
	table:     snout_core.Table,
	allocator: runtime.Allocator,
}

// ---- Thread-local error buffer ---------------------------------------------

@(thread_local)
_err_buf: [4096]u8

@(thread_local)
_str_buf: [256 * 1024]u8 // 256 KB scratch for returned strings

@(thread_local)
_str_pos: int

_set_error :: proc(msg: string) {
	n := copy(_err_buf[:], msg)
	if n < len(_err_buf) {
		_err_buf[n] = 0
	} else {
		_err_buf[len(_err_buf)-1] = 0
	}
}

_set_snout_error :: proc(err: snout_core.Error) {
	_set_error(snout_core.error_message(err))
}

_clear_error :: proc() {
	_err_buf[0] = 0
}

// _cstr writes s into the thread-local scratch buffer and returns a C string
// pointer. The pointer is valid until the buffer wraps (next ~256K of calls).
_cstr :: proc(s: string) -> cstring {
	needed := len(s) + 1
	if _str_pos + needed > len(_str_buf) {
		_str_pos = 0
	}
	start := _str_pos
	copy(_str_buf[start:], s)
	_str_buf[start + len(s)] = 0
	_str_pos = start + needed
	return cstring(&_str_buf[start])
}

// ---- Handle helpers --------------------------------------------------------

_new_handle :: proc(table: snout_core.Table) -> ^Handle {
	alloc := runtime.heap_allocator()
	owned_table := table
	h, err := new(Handle, alloc)
	if err != nil {
		snout_core.free_table(&owned_table)
		_set_error("out of memory allocating handle")
		return nil
	}
	h.table     = owned_table
	h.allocator = alloc
	return h
}

_free_handle :: proc(h: ^Handle) {
	if h == nil { return }
	snout_core.free_table(&h.table)
	free(h, h.allocator)
}

// ---- Parsing helpers (reuse query package) ---------------------------------

_parse_aggregates :: proc(
	text: string,
	alloc: runtime.Allocator,
) -> (specs: []query.Aggregate_Spec, ok: bool) {
	parts := strings.split(text, " ", alloc)
	defer delete(parts, alloc)

	result := make([dynamic]query.Aggregate_Spec, 0, alloc)
	for raw_part in parts {
		part := strings.trim_space(raw_part)
		if part == "" { continue }
		sep := strings.index_byte(part, '=')
		if sep <= 0 || sep == len(part)-1 {
			_set_error(fmt.tprintf("invalid aggregate %q", part))
			delete(result)
			return nil, false
		}
		fn_text  := part[:sep]
		col_name := part[sep+1:]
		spec, spec_ok := query.parse_aggregate_spec_kind(fn_text)
		if !spec_ok {
			_set_error(fmt.tprintf("unknown aggregate function %q", fn_text))
			delete(result)
			return nil, false
		}
		spec.column_name = col_name
		if spec.kind == .Count && col_name == "rows" {
			spec.column_name = "*"
		}
		append(&result, spec)
	}
	if len(result) == 0 {
		_set_error("at least one aggregate is required")
		delete(result)
		return nil, false
	}
	return result[:], true
}

_parse_groups :: proc(text: string, alloc: runtime.Allocator) -> []string {
	parts := strings.split(text, ",", alloc)
	defer delete(parts, alloc)
	result := make([dynamic]string, 0, alloc)
	for raw_part in parts {
		part := strings.trim_space(raw_part)
		if part != "" { append(&result, part) }
	}
	return result[:]
}

_parse_filters :: proc(
	exprs: [^]cstring,
	count: c.int,
	table: ^snout_core.Table,
	alloc: runtime.Allocator,
) -> (preds: []query.Filter_Predicate, ok: bool) {
	if count == 0 || exprs == nil { return nil, true }

	result := make([dynamic]query.Filter_Predicate, 0, alloc)
	i := 0
	for i < int(count) {
		col := strings.clone(string(exprs[i]), alloc)
		if i + 1 >= int(count) {
			_set_error(fmt.tprintf("incomplete filter at %q", col))
			delete(result)
			return nil, false
		}
		op_str := string(exprs[i+1])
		op, op_ok := query.parse_filter_operator(op_str)
		if !op_ok {
			_set_error(fmt.tprintf("unknown filter operator %q", op_str))
			delete(result)
			return nil, false
		}
		val_str := ""
		advance := 2
		if op != .Is_Null && op != .Is_Not_Null {
			if i + 2 >= int(count) {
				_set_error(fmt.tprintf("missing value for filter on %q", col))
				delete(result)
				return nil, false
			}
			val_str = string(exprs[i+2])
			advance = 3
		}
		pred, pred_err := query.make_filter_predicate(table, col, op, val_str)
		if pred_err != .None {
			_set_snout_error(pred_err)
			delete(result)
			return nil, false
		}
		append(&result, pred)
		i += advance
	}
	return result[:], true
}

_parse_sort :: proc(
	sort_str: string,
	group_cols: []string,
	agg_specs: []query.Aggregate_Spec,
	result_set: ^query.Group_Result_Set,
	alloc: runtime.Allocator,
) -> (terms: []query.Sort_Term, ok: bool) {
	if sort_str == "" { return nil, true }

	parts := strings.split(sort_str, " ", alloc)
	defer delete(parts, alloc)

	tokens := make([dynamic]string, 0, alloc)
	defer delete(tokens)
	for raw_part in parts {
		part := strings.trim_space(raw_part)
		if part != "" { append(&tokens, part) }
	}

	if len(tokens) == 0 { return nil, true }

	sep := strings.index_byte(tokens[0], '=')
	if sep <= 0 || sep == len(tokens[0])-1 {
		_set_error(fmt.tprintf("invalid sort expression %q", tokens[0]))
		return nil, false
	}
	fn_text  := tokens[0][:sep]
	col_name := tokens[0][sep+1:]

	direction := query.Sort_Direction.Ascending
	if len(tokens) >= 2 {
		dir_str := tokens[1]
		if dir_str == "desc" || dir_str == "DESC" {
			direction = .Descending
		}
	}

	// Match against group columns first
	for gcol, gi in result_set.group_columns {
		if gcol == col_name && fn_text == gcol {
			out, _ := make([]query.Sort_Term, 1, alloc)
			out[0] = query.Sort_Term{target_kind = .Group_Column, result_index = gi, direction = direction}
			return out, true
		}
	}

	// Match against aggregates
	spec, spec_ok := query.parse_aggregate_spec_kind(fn_text)
	if !spec_ok {
		_set_error(fmt.tprintf("unknown sort function %q", fn_text))
		return nil, false
	}
	spec.column_name = col_name
	if spec.kind == .Count && col_name == "rows" {
		spec.column_name = "*"
	}

	for agg, ai in result_set.aggregates {
		if agg.kind == spec.kind && agg.column_name == spec.column_name &&
		   agg.percentile == spec.percentile {
			out, _ := make([]query.Sort_Term, 1, alloc)
			out[0] = query.Sort_Term{target_kind = .Aggregate, result_index = ai, direction = direction}
			return out, true
		}
	}

	_set_error(fmt.tprintf("sort target %q not found in result", tokens[0]))
	return nil, false
}

// ---- Column value helpers --------------------------------------------------

_col_is_null :: proc(col: ^snout_core.Column, row: int) -> bool {
	if !col.nullable { return false }
	if row < 0 || row >= len(col.null_mask) { return true }
	return col.null_mask[row]
}

_col_get_string :: proc(col: ^snout_core.Column, row: int) -> cstring {
	if _col_is_null(col, row) { return nil }
	switch col.kind {
	case .String, .Timestamp:
		if row >= 0 && row < len(col.strings) {
			return _cstr(col.strings[row])
		}
	case .Int64:
		if row >= 0 && row < len(col.int64s) {
			return _cstr(fmt.tprintf("%d", col.int64s[row]))
		}
	case .Float64:
		if row >= 0 && row < len(col.float64s) {
			return _cstr(fmt.tprintf("%g", col.float64s[row]))
		}
	case .Bool:
		if row >= 0 && row < len(col.bools) {
			return _cstr("true" if col.bools[row] else "false")
		}
	case .Unknown:
	}
	return nil
}

// ============================================================================
// EXPORTED FUNCTIONS
// ============================================================================

// ---- Error -----------------------------------------------------------------

@(export)
snout_last_error :: proc "c" () -> cstring {
	return cstring(&_err_buf[0])
}

// ---- Table lifecycle -------------------------------------------------------

@(export)
snout_open :: proc "c" (path: cstring) -> ^Handle {
	context = runtime.default_context()
	_clear_error()
	p := string(path)
	alloc := runtime.heap_allocator()
	table, err := storage.read_snout_file(p, alloc)
	if err != .None {
		_set_snout_error(err)
		return nil
	}
	return _new_handle(table)
}

@(export)
snout_import_csv :: proc "c" (path: cstring) -> ^Handle {
	context = runtime.default_context()
	_clear_error()
	p := string(path)
	alloc := runtime.heap_allocator()
	table_name := _table_name_from_path(p)
	table, err := ingest.read_csv_table(p, table_name, alloc)
	if err != .None {
		_set_snout_error(err)
		return nil
	}
	return _new_handle(table)
}

@(export)
snout_import_jsonl :: proc "c" (path: cstring) -> ^Handle {
	context = runtime.default_context()
	_clear_error()
	p := string(path)
	alloc := runtime.heap_allocator()
	table_name := _table_name_from_path(p)
	table, err := ingest.read_jsonl_table(p, table_name, alloc)
	if err != .None {
		_set_snout_error(err)
		return nil
	}
	return _new_handle(table)
}

@(export)
snout_close :: proc "c" (h: ^Handle) {
	context = runtime.default_context()
	_free_handle(h)
}

// ---- Schema ----------------------------------------------------------------

@(export)
snout_row_count :: proc "c" (h: ^Handle) -> i64 {
	if h == nil { return 0 }
	return i64(h.table.row_count)
}

@(export)
snout_column_count :: proc "c" (h: ^Handle) -> c.int {
	if h == nil { return 0 }
	return c.int(len(h.table.columns))
}

@(export)
snout_column_name :: proc "c" (h: ^Handle, col: c.int) -> cstring {
	context = runtime.default_context()
	if h == nil || int(col) < 0 || int(col) >= len(h.table.columns) { return nil }
	return _cstr(h.table.columns[col].name)
}

@(export)
snout_column_type :: proc "c" (h: ^Handle, col: c.int) -> c.int {
	if h == nil || int(col) < 0 || int(col) >= len(h.table.columns) { return 5 } // UNKNOWN
	switch h.table.columns[col].kind {
	case .String:    return 0
	case .Int64:     return 1
	case .Float64:   return 2
	case .Bool:      return 3
	case .Timestamp: return 4
	case .Unknown:   return 5
	}
	return 5
}

// ---- Value access ----------------------------------------------------------

@(export)
snout_is_null :: proc "c" (h: ^Handle, row: i64, col: c.int) -> c.int {
	context = runtime.default_context()
	if h == nil || int(col) < 0 || int(col) >= len(h.table.columns) { return 1 }
	if row < 0 || row >= i64(h.table.row_count) { return 1 }
	if _col_is_null(&h.table.columns[col], int(row)) { return 1 }
	return 0
}

@(export)
snout_get_string :: proc "c" (h: ^Handle, row: i64, col: c.int) -> cstring {
	context = runtime.default_context()
	if h == nil || int(col) < 0 || int(col) >= len(h.table.columns) { return nil }
	if row < 0 || row >= i64(h.table.row_count) { return nil }
	return _col_get_string(&h.table.columns[col], int(row))
}

@(export)
snout_get_int64 :: proc "c" (h: ^Handle, row: i64, col: c.int) -> i64 {
	if h == nil || int(col) < 0 || int(col) >= len(h.table.columns) { return 0 }
	c_ := &h.table.columns[col]
	context = runtime.default_context()
	if row < 0 || row >= i64(h.table.row_count) { return 0 }
	if _col_is_null(c_, int(row)) { return 0 }
	if int(row) < 0 || int(row) >= len(c_.int64s) { return 0 }
	return c_.int64s[row]
}

@(export)
snout_get_float64 :: proc "c" (h: ^Handle, row: i64, col: c.int) -> f64 {
	context = runtime.default_context()
	if h == nil || int(col) < 0 || int(col) >= len(h.table.columns) { return 0 }
	c_ := &h.table.columns[col]
	if row < 0 || row >= i64(h.table.row_count) { return 0 }
	if _col_is_null(c_, int(row)) { return 0 }
	if int(row) < 0 || int(row) >= len(c_.float64s) { return 0 }
	return c_.float64s[row]
}

@(export)
snout_get_bool :: proc "c" (h: ^Handle, row: i64, col: c.int) -> c.int {
	context = runtime.default_context()
	if h == nil || int(col) < 0 || int(col) >= len(h.table.columns) { return 0 }
	c_ := &h.table.columns[col]
	if row < 0 || row >= i64(h.table.row_count) { return 0 }
	if _col_is_null(c_, int(row)) { return 0 }
	if int(row) < 0 || int(row) >= len(c_.bools) { return 0 }
	return 1 if c_.bools[row] else 0
}

// ---- Query -----------------------------------------------------------------

@(export)
snout_query :: proc "c" (
	h:            ^Handle,
	groups:       cstring,
	aggregates:   cstring,
	where_exprs:  [^]cstring,
	filter_count: c.int,
	sort:         cstring,
	limit:        c.int,
) -> ^Handle {
	context = runtime.default_context()
	_clear_error()
	if h == nil {
		_set_error("null table handle")
		return nil
	}
	if limit < 0 || limit > query.MAX_RESULT_LIMIT {
		_set_error("invalid result limit")
		return nil
	}

	alloc := runtime.heap_allocator()
	temp  := context.temp_allocator

	// Groups
	group_str := string(groups)
	if group_str == "" {
		_set_error("groups must not be empty")
		return nil
	}
	group_cols := _parse_groups(group_str, temp)
	defer delete(group_cols, temp)
	if len(group_cols) == 0 {
		_set_error("no valid group columns")
		return nil
	}

	// Aggregates
	agg_specs, agg_ok := _parse_aggregates(string(aggregates), temp)
	defer if agg_ok { delete(agg_specs, temp) }
	if !agg_ok { return nil }

	// Build initial Group_Query (without filters — need result set for sort)
	gq := query.Group_Query{
		group_columns = group_cols,
		aggregates    = agg_specs,
	}

	// Filters
	preds, filter_ok := _parse_filters(where_exprs, filter_count, &h.table, temp)
	defer if filter_ok && preds != nil { delete(preds, temp) }
	if !filter_ok { return nil }
	gq.filters = preds

	// Execute
	result_set, query_err := query.execute_group_query(&h.table, gq, temp)
	if query_err != .None {
		_set_snout_error(query_err)
		return nil
	}
	defer query.free_group_result_set(&result_set)

	// Sort
	sort_str := string(sort)
	if sort_str != "" {
		sort_terms, sort_ok := _parse_sort(sort_str, group_cols, agg_specs, &result_set, temp)
		defer if sort_ok && sort_terms != nil { delete(sort_terms, temp) }
		if !sort_ok { return nil }
		if len(sort_terms) > 0 {
			sort_err := query.sort_group_results(&result_set, sort_terms)
			if sort_err != .None {
				_set_snout_error(sort_err)
				return nil
			}
		}
	}

	// Materialize as core.Table
	out_table, mat_err := snout_merge.result_to_table(&result_set, &h.table, h.table.name, alloc)
	if mat_err != .None {
		_set_snout_error(mat_err)
		return nil
	}

	// Trim to limit if needed
	if int(limit) > 0 && int(limit) < out_table.row_count {
		out_table.row_count = int(limit)
	}

	return _new_handle(out_table)
}

// ---- Result access (aliases to table access) --------------------------------

@(export)
snout_result_free :: proc "c" (r: ^Handle) {
	context = runtime.default_context()
	_free_handle(r)
}

@(export)
snout_result_row_count :: proc "c" (r: ^Handle) -> c.int {
	return c.int(snout_row_count(r))
}

@(export)
snout_result_col_count :: proc "c" (r: ^Handle) -> c.int {
	return snout_column_count(r)
}

@(export)
snout_result_col_name :: proc "c" (r: ^Handle, col: c.int) -> cstring {
	context = runtime.default_context()
	return snout_column_name(r, col)
}

@(export)
snout_result_col_type :: proc "c" (r: ^Handle, col: c.int) -> c.int {
	return snout_column_type(r, col)
}

@(export)
snout_result_is_null :: proc "c" (r: ^Handle, row: c.int, col: c.int) -> c.int {
	return snout_is_null(r, i64(row), col)
}

@(export)
snout_result_get_string :: proc "c" (r: ^Handle, row: c.int, col: c.int) -> cstring {
	context = runtime.default_context()
	return snout_get_string(r, i64(row), col)
}

@(export)
snout_result_get_int64 :: proc "c" (r: ^Handle, row: c.int, col: c.int) -> i64 {
	return snout_get_int64(r, i64(row), col)
}

@(export)
snout_result_get_float64 :: proc "c" (r: ^Handle, row: c.int, col: c.int) -> f64 {
	return snout_get_float64(r, i64(row), col)
}

@(export)
snout_result_get_bool :: proc "c" (r: ^Handle, row: c.int, col: c.int) -> c.int {
	return snout_get_bool(r, i64(row), col)
}

// ---- Private helpers -------------------------------------------------------

_table_name_from_path :: proc(path: string) -> string {
	start := 0
	for i := len(path) - 1; i >= 0; i -= 1 {
		if path[i] == '/' || path[i] == '\\' {
			start = i + 1
			break
		}
	}
	name := path[start:]
	for i := len(name) - 1; i >= 0; i -= 1 {
		if name[i] == '.' {
			name = name[:i]
			break
		}
	}
	return name
}
