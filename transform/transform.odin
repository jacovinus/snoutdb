package transform

import "base:runtime"
import "core:fmt"
import "core:strconv"
import "core:strings"
import "core:text/regex"
import snout_core "../core"

// apply_transforms applies ops left-to-right on table, returning a new Table.
// Intermediate tables are allocated with context.allocator and freed before
// the next step. The caller owns the returned Table and must call
// snout_core.free_table.
apply_transforms :: proc(
	table: ^snout_core.Table,
	ops: []Transform_Op,
	allocator := context.allocator,
) -> (snout_core.Table, snout_core.Error) {
	if len(ops) == 0 {
		return clone_table(table, allocator)
	}

	current: snout_core.Table
	current_owned := false

	for op, i in ops {
		src := table if !current_owned else &current
		is_last := i == len(ops) - 1
		step_alloc := allocator if is_last else context.allocator

		next, err := apply_transform(src, op, step_alloc)
		if err != .None {
			if current_owned {snout_core.free_table(&current)}
			return {}, err
		}
		if current_owned {snout_core.free_table(&current)}
		current = next
		current_owned = true
	}

	return current, .None
}

// apply_transform applies a single Transform_Op and returns a new Table.
apply_transform :: proc(
	table: ^snout_core.Table,
	op: Transform_Op,
	allocator := context.allocator,
) -> (snout_core.Table, snout_core.Error) {
	switch v in op {
	case Rename_Op:        return apply_rename(table, v, allocator)
	case Drop_Op:          return apply_drop(table, v, allocator)
	case Cast_Op:          return apply_cast(table, v, allocator)
	case Derive_Op:        return apply_derive(table, v, allocator)
	case Bucket_Op:        return apply_bucket(table, v, allocator)
	case Date_Trunc_Op:    return apply_date_trunc(table, v, allocator)
	case Regex_Extract_Op: return apply_regex_extract(table, v, allocator)
	case Json_Extract_Op:  return apply_json_extract(table, v, allocator)
	}
	return {}, .Malformed_Query_Arguments
}

// ---- rename ----------------------------------------------------------------

@(private = "file")
apply_rename :: proc(
	table: ^snout_core.Table,
	op: Rename_Op,
	allocator: runtime.Allocator,
) -> (snout_core.Table, snout_core.Error) {
	_, found := snout_core.get_column(table, op.from)
	if !found {
		return {}, .Column_Not_Found
	}

	out, err := clone_table(table, allocator)
	if err != .None {
		return {}, err
	}
	for &col in out.columns {
		if col.name == op.from {
			delete(col.name, allocator)
			col.name = strings.clone(op.to, allocator)
			break
		}
	}
	return out, .None
}

// ---- drop ------------------------------------------------------------------

@(private = "file")
apply_drop :: proc(
	table: ^snout_core.Table,
	op: Drop_Op,
	allocator: runtime.Allocator,
) -> (snout_core.Table, snout_core.Error) {
	drop_idx := -1
	for col, i in table.columns {
		if col.name == op.column {
			drop_idx = i
			break
		}
	}
	if drop_idx < 0 {
		return {}, .Column_Not_Found
	}

	out: snout_core.Table
	out.allocator = allocator
	out.row_count = table.row_count
	out.name = strings.clone(table.name, allocator)

	failed := true
	defer if failed {snout_core.free_table(&out)}

	alloc_err: runtime.Allocator_Error
	out.columns, alloc_err = make([]snout_core.Column, len(table.columns) - 1, allocator)
	if alloc_err != nil {
		return {}, .Out_Of_Memory
	}

	dst_idx := 0
	for &src_col, i in table.columns {
		if i == drop_idx {continue}
		col_err := clone_column_into(&out.columns[dst_idx], &src_col, table.row_count, allocator)
		if col_err != .None {
			return {}, col_err
		}
		dst_idx += 1
	}

	failed = false
	return out, .None
}

// ---- cast ------------------------------------------------------------------

@(private = "file")
apply_cast :: proc(
	table: ^snout_core.Table,
	op: Cast_Op,
	allocator: runtime.Allocator,
) -> (snout_core.Table, snout_core.Error) {
	src_col, found := snout_core.get_column(table, op.column)
	if !found {
		return {}, .Column_Not_Found
	}
	if src_col.kind == op.to {
		return clone_table(table, allocator)
	}

	out: snout_core.Table
	out.allocator = allocator
	out.row_count = table.row_count
	out.name = strings.clone(table.name, allocator)

	failed := true
	defer if failed {snout_core.free_table(&out)}

	alloc_err: runtime.Allocator_Error
	out.columns, alloc_err = make([]snout_core.Column, len(table.columns), allocator)
	if alloc_err != nil {
		return {}, .Out_Of_Memory
	}

	for &src, i in table.columns {
		dst := &out.columns[i]
		if src.name != op.column {
			if col_err := clone_column_into(dst, &src, table.row_count, allocator);
			   col_err != .None {
				return {}, col_err
			}
			continue
		}

		dst.name = strings.clone(src.name, allocator)
		dst.kind = op.to

		// Casts from String may fail; always mark nullable.
		dst.nullable = src.nullable || src.kind == .String
		dst.null_mask, _ = make([]bool, table.row_count, allocator)
		copy(dst.null_mask, src.null_mask)

		if col_err := cast_column_data(dst, &src, table.row_count, op.to, allocator);
		   col_err != .None {
			return {}, col_err
		}
	}

	failed = false
	return out, .None
}

@(private = "file")
cast_column_data :: proc(
	dst, src: ^snout_core.Column,
	row_count: int,
	to: snout_core.Column_Type,
	allocator: runtime.Allocator,
) -> snout_core.Error {
	alloc_err: runtime.Allocator_Error
	switch to {
	case .Int64:
		dst.int64s, alloc_err = make([]i64, row_count, allocator)
		if row_count > 0 && alloc_err != nil {return .Out_Of_Memory}
		for i in 0 ..< row_count {
			if src.null_mask[i] {continue}
			switch src.kind {
			case .Float64:
				dst.int64s[i] = i64(src.float64s[i])
			case .Bool:
				dst.int64s[i] = 1 if src.bools[i] else 0
			case .String, .Timestamp:
				v, ok := strconv.parse_i64(src.strings[i])
				if !ok {
					dst.null_mask[i] = true
					dst.nullable = true
				} else {
					dst.int64s[i] = v
				}
			case .Int64, .Unknown:
			}
		}
	case .Float64:
		dst.float64s, alloc_err = make([]f64, row_count, allocator)
		if row_count > 0 && alloc_err != nil {return .Out_Of_Memory}
		for i in 0 ..< row_count {
			if src.null_mask[i] {continue}
			switch src.kind {
			case .Int64:
				dst.float64s[i] = f64(src.int64s[i])
			case .Bool:
				dst.float64s[i] = 1.0 if src.bools[i] else 0.0
			case .String, .Timestamp:
				v, ok := strconv.parse_f64(src.strings[i])
				if !ok {
					dst.null_mask[i] = true
					dst.nullable = true
				} else {
					dst.float64s[i] = v
				}
			case .Float64, .Unknown:
			}
		}
	case .Bool:
		dst.bools, alloc_err = make([]bool, row_count, allocator)
		if row_count > 0 && alloc_err != nil {return .Out_Of_Memory}
		for i in 0 ..< row_count {
			if src.null_mask[i] {continue}
			switch src.kind {
			case .Int64:
				dst.bools[i] = src.int64s[i] != 0
			case .Float64:
				dst.bools[i] = src.float64s[i] != 0
			case .String, .Timestamp:
				s := src.strings[i]
				switch s {
				case "true", "1", "yes":
					dst.bools[i] = true
				case "false", "0", "no":
					dst.bools[i] = false
				case:
					dst.null_mask[i] = true
					dst.nullable = true
				}
			case .Bool, .Unknown:
			}
		}
	case .String, .Timestamp:
		dst.strings, alloc_err = make([]string, row_count, allocator)
		if row_count > 0 && alloc_err != nil {return .Out_Of_Memory}
		for i in 0 ..< row_count {
			if src.null_mask[i] {continue}
			switch src.kind {
			case .Int64:
				dst.strings[i] = fmt.aprintf("%d", src.int64s[i], allocator = allocator)
			case .Float64:
				dst.strings[i] = fmt.aprintf("%g", src.float64s[i], allocator = allocator)
			case .Bool:
				dst.strings[i] = strings.clone(
					"true" if src.bools[i] else "false",
					allocator,
				)
			case .String, .Timestamp:
				dst.strings[i] = strings.clone(src.strings[i], allocator)
			case .Unknown:
			}
		}
	case .Unknown:
		return .Invalid_Type
	}
	return .None
}

// ---- derive ----------------------------------------------------------------

@(private = "file")
Operand :: union {
	string, // column name
	f64,    // numeric literal
}

@(private = "file")
apply_derive :: proc(
	table: ^snout_core.Table,
	op: Derive_Op,
	allocator: runtime.Allocator,
) -> (snout_core.Table, snout_core.Error) {
	left_str, op_char, right_str, parsed := parse_derive_expr(op.expr)
	if !parsed {
		return {}, .Malformed_Query_Arguments
	}

	left_op := resolve_operand(left_str, table)
	right_op := resolve_operand(right_str, table)
	if left_op == nil || right_op == nil {
		return {}, .Column_Not_Found
	}

	// Determine output type.
	is_float: bool = op_char == '/'
	if !is_float {
		if v, ok := left_op.(f64); ok && f64(i64(v)) != v {is_float = true}
		if v, ok := right_op.(f64); ok && f64(i64(v)) != v {is_float = true}
		if col_name, ok := left_op.(string); ok {
			if c, found := snout_core.get_column(table, col_name); found {
				if c.kind == .Float64 {is_float = true}
			}
		}
		if col_name, ok := right_op.(string); ok {
			if c, found := snout_core.get_column(table, col_name); found {
				if c.kind == .Float64 {is_float = true}
			}
		}
	}

	// Build output table with one extra column.
	out, err := clone_table_with_extra(table, allocator)
	if err != .None {
		return {}, err
	}
	failed := true
	defer if failed {snout_core.free_table(&out)}

	new_col := &out.columns[len(table.columns)]
	new_col.name = strings.clone(op.out_name, allocator)
	new_col.kind = .Float64 if is_float else .Int64
	new_col.nullable = false
	new_col.null_mask, _ = make([]bool, table.row_count, allocator)

	if is_float {
		new_col.float64s, _ = make([]f64, table.row_count, allocator)
	} else {
		new_col.int64s, _ = make([]i64, table.row_count, allocator)
	}

	for i in 0 ..< table.row_count {
		lv, l_null := get_operand_float(left_op, table, i)
		rv, r_null := get_operand_float(right_op, table, i)

		if l_null || r_null || (op_char == '/' && rv == 0) {
			new_col.null_mask[i] = true
			new_col.nullable = true
			continue
		}

		result: f64
		switch op_char {
		case '+': result = lv + rv
		case '-': result = lv - rv
		case '*': result = lv * rv
		case '/': result = lv / rv
		}

		if is_float {
			new_col.float64s[i] = result
		} else {
			new_col.int64s[i] = i64(result)
		}
	}

	failed = false
	return out, .None
}

@(private = "file")
parse_derive_expr :: proc(expr: string) -> (left: string, op_char: u8, right: string, ok: bool) {
	for i in 1 ..< len(expr) {
		ch := expr[i]
		if ch == '+' || ch == '-' || ch == '*' || ch == '/' {
			l := strings.trim_space(expr[:i])
			r := strings.trim_space(expr[i + 1:])
			if len(l) == 0 || len(r) == 0 {
				return "", 0, "", false
			}
			return l, ch, r, true
		}
	}
	return "", 0, "", false
}

@(private = "file")
resolve_operand :: proc(s: string, table: ^snout_core.Table) -> Operand {
	if v, ok := strconv.parse_f64(s); ok {
		return v
	}
	if _, found := snout_core.get_column(table, s); found {
		return s
	}
	return nil
}

@(private = "file")
get_operand_float :: proc(
	op: Operand,
	table: ^snout_core.Table,
	row: int,
) -> (value: f64, is_null: bool) {
	switch v in op {
	case f64:
		return v, false
	case string:
		col, _ := snout_core.get_column(table, v)
		if col.null_mask[row] {
			return 0, true
		}
		switch col.kind {
		case .Int64:
			return f64(col.int64s[row]), false
		case .Float64:
			return col.float64s[row], false
		case .String, .Timestamp, .Bool, .Unknown:
			return 0, true
		}
	}
	return 0, true
}

// ---- bucket ----------------------------------------------------------------

@(private = "file")
apply_bucket :: proc(
	table: ^snout_core.Table,
	op: Bucket_Op,
	allocator: runtime.Allocator,
) -> (snout_core.Table, snout_core.Error) {
	src_col, found := snout_core.get_column(table, op.column)
	if !found {
		return {}, .Column_Not_Found
	}
	if src_col.kind != .Int64 && src_col.kind != .Float64 {
		return {}, .Wrong_Column_Type
	}
	if len(op.edges) < 2 || len(op.labels) != len(op.edges) - 1 {
		return {}, .Malformed_Query_Arguments
	}

	out, err := clone_table_with_extra(table, allocator)
	if err != .None {
		return {}, err
	}
	failed := true
	defer if failed {snout_core.free_table(&out)}

	new_col := &out.columns[len(table.columns)]
	new_col.name = strings.clone(op.out_column, allocator)
	new_col.kind = .String
	new_col.nullable = true
	new_col.null_mask, _ = make([]bool, table.row_count, allocator)
	new_col.strings, _ = make([]string, table.row_count, allocator)

	for i in 0 ..< table.row_count {
		if src_col.null_mask[i] {
			new_col.null_mask[i] = true
			continue
		}
		v: f64
		#partial switch src_col.kind {
		case .Int64:   v = f64(src_col.int64s[i])
		case .Float64: v = src_col.float64s[i]
		}
		label, in_range := bucket_label(v, op.edges, op.labels)
		if !in_range {
			new_col.null_mask[i] = true
		} else {
			new_col.strings[i] = strings.clone(label, allocator)
		}
	}

	failed = false
	return out, .None
}

@(private = "file")
bucket_label :: proc(v: f64, edges: []f64, labels: []string) -> (label: string, ok: bool) {
	for i in 0 ..< len(edges) - 1 {
		if v >= edges[i] && v < edges[i + 1] {
			return labels[i], true
		}
	}
	return "", false
}

// ---- date_trunc ------------------------------------------------------------

@(private = "file")
apply_date_trunc :: proc(
	table: ^snout_core.Table,
	op: Date_Trunc_Op,
	allocator: runtime.Allocator,
) -> (snout_core.Table, snout_core.Error) {
	src_col, found := snout_core.get_column(table, op.column)
	if !found {
		return {}, .Column_Not_Found
	}
	if src_col.kind != .Timestamp && src_col.kind != .String {
		return {}, .Wrong_Column_Type
	}

	in_place := op.out_column == op.column
	base_cols := len(table.columns)
	extra := 0 if in_place else 1

	out: snout_core.Table
	if extra == 0 {
		var_err: snout_core.Error
		out, var_err = clone_table(table, allocator)
		if var_err != .None {
			return {}, var_err
		}
	} else {
		var_err: snout_core.Error
		out, var_err = clone_table_with_extra(table, allocator)
		if var_err != .None {
			return {}, var_err
		}
	}
	failed := true
	defer if failed {snout_core.free_table(&out)}

	dst_col: ^snout_core.Column
	if in_place {
		for &col in out.columns {
			if col.name == op.column {
				dst_col = &col
				break
			}
		}
		// Re-allocate strings in-place (already cloned from clone_table, re-derive).
		for i in 0 ..< table.row_count {
			if dst_col.null_mask[i] {continue}
			old := dst_col.strings[i]
			truncated, valid := trunc_iso8601(old, op.unit)
			if !valid {
				dst_col.null_mask[i] = true
				dst_col.nullable = true
				delete(old, allocator)
				dst_col.strings[i] = ""
			} else if truncated != old {
				delete(old, allocator)
				dst_col.strings[i] = strings.clone(truncated, allocator)
			}
		}
	} else {
		dst_col = &out.columns[base_cols]
		dst_col.name = strings.clone(op.out_column, allocator)
		dst_col.kind = .Timestamp
		dst_col.nullable = src_col.nullable
		dst_col.null_mask, _ = make([]bool, table.row_count, allocator)
		copy(dst_col.null_mask, src_col.null_mask)
		dst_col.strings, _ = make([]string, table.row_count, allocator)
		for i in 0 ..< table.row_count {
			if src_col.null_mask[i] {continue}
			truncated, valid := trunc_iso8601(src_col.strings[i], op.unit)
			if !valid {
				dst_col.null_mask[i] = true
				dst_col.nullable = true
			} else {
				dst_col.strings[i] = strings.clone(truncated, allocator)
			}
		}
	}

	failed = false
	return out, .None
}

// trunc_iso8601 truncates an ISO-8601 string (YYYY-MM-DDTHH:MM:SSZ) to the
// requested unit and returns the result.  Returns ok=false if the input
// is too short or malformed.
@(private = "file")
trunc_iso8601 :: proc(s: string, unit: Date_Trunc_Unit) -> (result: string, ok: bool) {
	// Minimum required lengths per unit (indices into the string):
	// Year   → need 4 chars  "YYYY"
	// Month  → need 7 chars  "YYYY-MM"
	// Day    → need 10 chars "YYYY-MM-DD"
	// Hour   → need 13 chars "YYYY-MM-DDTHH"
	// Minute → need 16 chars "YYYY-MM-DDTHH:MM"
	switch unit {
	case .Year:
		if len(s) < 4 {return "", false}
		return fmt.tprintf("%s-01-01T00:00:00Z", s[:4]), true
	case .Month:
		if len(s) < 7 {return "", false}
		return fmt.tprintf("%s-01T00:00:00Z", s[:7]), true
	case .Day:
		if len(s) < 10 {return "", false}
		return fmt.tprintf("%sT00:00:00Z", s[:10]), true
	case .Hour:
		if len(s) < 13 {return "", false}
		return fmt.tprintf("%s:00:00Z", s[:13]), true
	case .Minute:
		if len(s) < 16 {return "", false}
		return fmt.tprintf("%s:00Z", s[:16]), true
	}
	return "", false
}

// ---- regex_extract ---------------------------------------------------------

@(private = "file")
apply_regex_extract :: proc(
	table: ^snout_core.Table,
	op: Regex_Extract_Op,
	allocator: runtime.Allocator,
) -> (snout_core.Table, snout_core.Error) {
	src_col, found := snout_core.get_column(table, op.column)
	if !found {
		return {}, .Column_Not_Found
	}
	if src_col.kind != .String && src_col.kind != .Timestamp {
		return {}, .Wrong_Column_Type
	}

	re, re_err := regex.create(op.pattern, {}, context.temp_allocator)
	if re_err != nil {
		return {}, .Malformed_Query_Arguments
	}
	defer regex.destroy_regex(re, context.temp_allocator)

	out, err := clone_table_with_extra(table, allocator)
	if err != .None {
		return {}, err
	}
	failed := true
	defer if failed {snout_core.free_table(&out)}

	new_col := &out.columns[len(table.columns)]
	new_col.name = strings.clone(op.out_column, allocator)
	new_col.kind = .String
	new_col.nullable = true
	new_col.null_mask, _ = make([]bool, table.row_count, allocator)
	new_col.strings, _ = make([]string, table.row_count, allocator)

	for i in 0 ..< table.row_count {
		if src_col.null_mask[i] {
			new_col.null_mask[i] = true
			continue
		}
		cap, matched := regex.match_and_allocate_capture(
			re,
			src_col.strings[i],
			context.temp_allocator,
		)
		if !matched || op.capture >= len(cap.groups) {
			new_col.null_mask[i] = true
			continue
		}
		new_col.strings[i] = strings.clone(cap.groups[op.capture], allocator)
	}

	failed = false
	return out, .None
}

// ---- json_extract ----------------------------------------------------------

@(private = "file")
apply_json_extract :: proc(
	table: ^snout_core.Table,
	op: Json_Extract_Op,
	allocator: runtime.Allocator,
) -> (snout_core.Table, snout_core.Error) {
	src_col, found := snout_core.get_column(table, op.column)
	if !found {
		return {}, .Column_Not_Found
	}
	if src_col.kind != .String {
		return {}, .Wrong_Column_Type
	}

	out, err := clone_table_with_extra(table, allocator)
	if err != .None {
		return {}, err
	}
	failed := true
	defer if failed {snout_core.free_table(&out)}

	new_col := &out.columns[len(table.columns)]
	new_col.name = strings.clone(op.out_column, allocator)
	new_col.kind = .String
	new_col.nullable = true
	new_col.null_mask, _ = make([]bool, table.row_count, allocator)
	new_col.strings, _ = make([]string, table.row_count, allocator)

	for i in 0 ..< table.row_count {
		if src_col.null_mask[i] {
			new_col.null_mask[i] = true
			continue
		}
		val, ok := json_extract_key(src_col.strings[i], op.key)
		if !ok {
			new_col.null_mask[i] = true
		} else {
			new_col.strings[i] = strings.clone(val, allocator)
		}
	}

	failed = false
	return out, .None
}

// json_extract_key performs a minimal top-level key lookup in a JSON object
// string without a full parser. Finds `"key":value` and returns the value as
// a raw string slice (unquoted for string values, as-is for others).
@(private = "file")
json_extract_key :: proc(json_str, key: string) -> (value: string, ok: bool) {
	s := strings.trim_space(json_str)
	if len(s) < 2 || s[0] != '{' {
		return "", false
	}

	// Build the search pattern: `"key":` (with optional whitespace after colon).
	needle := fmt.tprintf("\"%s\":", key)
	idx := strings.index(s, needle)
	if idx < 0 {
		return "", false
	}

	rest := strings.trim_space(s[idx + len(needle):])
	if len(rest) == 0 {
		return "", false
	}

	if rest[0] == '"' {
		// String value: find closing quote, skipping \.
		end := 1
		for end < len(rest) {
			if rest[end] == '\\' {
				end += 2
				continue
			}
			if rest[end] == '"' {
				break
			}
			end += 1
		}
		if end >= len(rest) {
			return "", false
		}
		return rest[1:end], true
	}

	// Non-string value: read until `,`, `}`, or whitespace.
	end := 0
	for end < len(rest) {
		ch := rest[end]
		if ch == ',' || ch == '}' || ch == ' ' || ch == '\t' || ch == '\n' {
			break
		}
		end += 1
	}
	raw := rest[:end]
	if raw == "null" {
		return "", false
	}
	return raw, true
}

// ---- helpers ---------------------------------------------------------------

// clone_table deep-copies table into a new Table owned by allocator.
clone_table :: proc(
	table: ^snout_core.Table,
	allocator: runtime.Allocator,
) -> (snout_core.Table, snout_core.Error) {
	out: snout_core.Table
	out.allocator = allocator
	out.row_count = table.row_count
	out.name = strings.clone(table.name, allocator)

	failed := true
	defer if failed {snout_core.free_table(&out)}

	alloc_err: runtime.Allocator_Error
	out.columns, alloc_err = make([]snout_core.Column, len(table.columns), allocator)
	if alloc_err != nil {
		return {}, .Out_Of_Memory
	}

	for &src, i in table.columns {
		if err := clone_column_into(&out.columns[i], &src, table.row_count, allocator);
		   err != .None {
			return {}, err
		}
	}

	failed = false
	return out, .None
}

// clone_table_with_extra clones table and allocates one extra uninitialized
// column slot at the end.
@(private = "file")
clone_table_with_extra :: proc(
	table: ^snout_core.Table,
	allocator: runtime.Allocator,
) -> (snout_core.Table, snout_core.Error) {
	out: snout_core.Table
	out.allocator = allocator
	out.row_count = table.row_count
	out.name = strings.clone(table.name, allocator)

	failed := true
	defer if failed {snout_core.free_table(&out)}

	alloc_err: runtime.Allocator_Error
	out.columns, alloc_err = make([]snout_core.Column, len(table.columns) + 1, allocator)
	if alloc_err != nil {
		return {}, .Out_Of_Memory
	}

	for &src, i in table.columns {
		if err := clone_column_into(&out.columns[i], &src, table.row_count, allocator);
		   err != .None {
			return {}, err
		}
	}

	failed = false
	return out, .None
}

// clone_column_into deep-copies src into dst using allocator.
@(private = "file")
clone_column_into :: proc(
	dst, src: ^snout_core.Column,
	row_count: int,
	allocator: runtime.Allocator,
) -> snout_core.Error {
	dst.name = strings.clone(src.name, allocator)
	dst.kind = src.kind
	dst.nullable = src.nullable

	alloc_err: runtime.Allocator_Error
	dst.null_mask, alloc_err = make([]bool, row_count, allocator)
	if alloc_err != nil {
		return .Out_Of_Memory
	}
	copy(dst.null_mask, src.null_mask)

	switch src.kind {
	case .Int64:
		dst.int64s, alloc_err = make([]i64, row_count, allocator)
		if row_count > 0 && alloc_err != nil {return .Out_Of_Memory}
		copy(dst.int64s, src.int64s)
	case .Float64:
		dst.float64s, alloc_err = make([]f64, row_count, allocator)
		if row_count > 0 && alloc_err != nil {return .Out_Of_Memory}
		copy(dst.float64s, src.float64s)
	case .Bool:
		dst.bools, alloc_err = make([]bool, row_count, allocator)
		if row_count > 0 && alloc_err != nil {return .Out_Of_Memory}
		copy(dst.bools, src.bools)
	case .String, .Timestamp:
		dst.strings, alloc_err = make([]string, row_count, allocator)
		if row_count > 0 && alloc_err != nil {return .Out_Of_Memory}
		for i in 0 ..< row_count {
			if src.null_mask[i] {continue}
			dst.strings[i] = strings.clone(src.strings[i], allocator)
		}
	case .Unknown:
		return .Invalid_Type
	}
	return .None
}
