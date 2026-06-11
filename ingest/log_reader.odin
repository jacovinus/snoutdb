package ingest

import "base:runtime"
import "core:mem"
import "core:strconv"
import "core:strings"
import "core:text/regex"
import snout_core "../core"

// inspect_log_file streams the file once and returns the exact schema and row count.
// For CLF, Combined, and Syslog the column layout is fixed. For Logfmt and Regex
// the schema is derived by scanning all lines.
inspect_log_file :: proc(
	path, table_name: string,
	opts: Log_Read_Options,
	allocator := context.allocator,
) -> (schema: Log_File_Schema, err: snout_core.Error) {
	resolved := opts
	if !opts.has_format && opts.pattern == "" {
		resolved.format, err = detect_log_format(path, context.temp_allocator)
		if err != .None {
			return {}, err
		}
		resolved.has_format = true
	}
	switch resolved.format {
	case .CLF:
		schema, err = inspect_fixed_log(path, table_name, clf_schema_template(), parse_clf_tokens, 9, resolved, allocator)
	case .Combined:
		schema, err = inspect_fixed_log(path, table_name, combined_schema_template(), parse_clf_tokens, 11, resolved, allocator)
	case .Syslog:
		schema, err = inspect_fixed_log(path, table_name, syslog_schema_template(), parse_syslog_line, 5, resolved, allocator)
	case .Logfmt:
		schema, err = inspect_logfmt_log(path, table_name, resolved, allocator)
	case .Regex:
		schema, err = inspect_regex_log(path, table_name, resolved, allocator)
	case:
		return {}, .Unsupported_Input_Format
	}
	if err == .None {
		schema.format = resolved.format
	}
	return
}

// populate_log_table re-reads the file and fills typed column slices from schema.
// Malformed lines are null-padded (non-strict) or returned as Log_Parse_Error (strict).
populate_log_table :: proc(
	path: string,
	schema: ^Log_File_Schema,
	opts: Log_Read_Options,
	allocator := context.allocator,
) -> (table: snout_core.Table, err: snout_core.Error) {
	// Use schema.format (set during inspect, after auto-detect) instead of opts.format.
	switch schema.format {
	case .CLF, .Combined:
		return populate_fixed_log(path, schema, parse_clf_tokens, opts, allocator)
	case .Syslog:
		return populate_fixed_log(path, schema, parse_syslog_line, opts, allocator)
	case .Logfmt:
		return populate_logfmt_log(path, schema, opts, allocator)
	case .Regex:
		return populate_regex_log(path, schema, opts, allocator)
	}
	return {}, .Unsupported_Input_Format
}

// read_log_table is the convenience single-call API (inspect + populate).
read_log_table :: proc(
	path, table_name: string,
	opts: Log_Read_Options,
	allocator := context.allocator,
) -> (snout_core.Table, snout_core.Error) {
	schema, inspect_err := inspect_log_file(path, table_name, opts, allocator)
	if inspect_err != .None {
		return {}, inspect_err
	}
	defer free_log_file_schema(&schema)
	return populate_log_table(path, &schema, opts, allocator)
}

// ---- Fixed-format inspection (CLF, Combined, Syslog) -----------------------

@(private = "file")
inspect_fixed_log :: proc(
	path, table_name: string,
	template: []Log_Column_Schema,
	parse_fn: proc(string, runtime.Allocator) -> ([]Log_Field, bool),
	expected_fields: int,
	opts: Log_Read_Options,
	allocator: runtime.Allocator,
) -> (schema: Log_File_Schema, err: snout_core.Error) {
	scanner, scan_err := open_jsonl_scanner(path, allocator = allocator)
	if scan_err != .None {
		return {}, scan_err
	}
	defer close_jsonl_scanner(&scanner)

	row_count := 0
	parse_errors := 0

	for {
		line, done, line_err := next_jsonl_line(&scanner)
		if line_err != .None {
			return {}, line_err
		}
		if done {
			break
		}

		fields, ok := parse_fn(line, context.temp_allocator)
		if !ok || len(fields) < expected_fields {
			if opts.strict {
				return {}, .Log_Parse_Error
			}
			parse_errors += 1
		}
		free_all(context.temp_allocator)
		row_count += 1
	}

	if row_count == 0 {
		return {}, .Empty_Input
	}

	cols, col_err := clone_log_schema_cols(template, allocator)
	if col_err != .None {
		return {}, col_err
	}

	col_indexes := make(map[string]int, allocator = allocator)
	for col, i in cols {
		col_indexes[col.name] = i
	}

	owned_name, name_err := strings.clone(table_name, allocator)
	if name_err != nil {
		for col in cols {
			delete(col.name, allocator)
		}
		delete(cols, allocator)
		delete(col_indexes)
		return {}, .Out_Of_Memory
	}

	return Log_File_Schema {
		table_name   = owned_name,
		row_count    = row_count,
		parse_errors = parse_errors,
		columns      = cols,
		column_indexes = col_indexes,
		allocator    = allocator,
	}, .None
}

// ---- Logfmt inspection ------------------------------------------------------

@(private = "file")
inspect_logfmt_log :: proc(
	path, table_name: string,
	opts: Log_Read_Options,
	allocator: runtime.Allocator,
) -> (schema: Log_File_Schema, err: snout_core.Error) {
	scanner, scan_err := open_jsonl_scanner(path, allocator = allocator)
	if scan_err != .None {
		return {}, scan_err
	}
	defer close_jsonl_scanner(&scanner)

	cols_dyn := make([dynamic]Log_Column_Schema, 0, allocator = allocator)
	col_indexes := make(map[string]int, allocator = allocator)

	failed := false
	cloned_count := 0
	defer if failed {
		for col in cols_dyn[:cloned_count] {
			delete(col.name, allocator)
		}
		delete(cols_dyn)
		delete(col_indexes)
	}

	row_count := 0
	parse_errors := 0

	for {
		line, done, line_err := next_jsonl_line(&scanner)
		if line_err != .None {
			failed = true
			return {}, line_err
		}
		if done {
			break
		}

		fields, ok := parse_logfmt_line(line, context.temp_allocator)
		if !ok {
			if opts.strict {
				failed = true
				return {}, .Log_Parse_Error
			}
			parse_errors += 1
			free_all(context.temp_allocator)
			row_count += 1
			continue
		}

		seen := make(map[string]bool, allocator = context.temp_allocator)
		for field in fields {
			seen[field.name] = true
			incoming := logfmt_infer_type(field.name, field.value)
			if field.null {
				incoming = .Unknown
			}

			if col_idx, found := col_indexes[field.name]; found {
				new_kind := promote_log_type(cols_dyn[col_idx].kind, incoming)
				cols_dyn[col_idx].kind = new_kind
				if field.null {
					cols_dyn[col_idx].nullable = true
				}
			} else {
				name, name_err := strings.clone(field.name, allocator)
				if name_err != nil {
					failed = true
					return {}, .Out_Of_Memory
				}
				new_col := Log_Column_Schema {
					name     = name,
					kind     = incoming,
					nullable = row_count > 0 || field.null,
				}
				append(&cols_dyn, new_col)
				cloned_count += 1
				col_indexes[name] = len(cols_dyn) - 1
			}
		}

		for &col in cols_dyn {
			if col.name not_in seen {
				col.nullable = true
			}
		}

		free_all(context.temp_allocator)
		row_count += 1
	}

	if row_count == 0 {
		failed = true
		return {}, .Empty_Input
	}

	// All-Unknown columns → String nullable
	for &col in cols_dyn {
		if col.kind == .Unknown {
			col.kind = .String
			col.nullable = true
		}
	}

	cols_slice, slice_err := make([]Log_Column_Schema, len(cols_dyn), allocator)
	if slice_err != nil {
		failed = true
		return {}, .Out_Of_Memory
	}
	copy(cols_slice, cols_dyn[:])
	delete(cols_dyn)
	// Rebuild indexes pointing into the slice (same string pointers).
	clear(&col_indexes)
	for col, i in cols_slice {
		col_indexes[col.name] = i
	}

	owned_name, name_err := strings.clone(table_name, allocator)
	if name_err != nil {
		for col in cols_slice {
			delete(col.name, allocator)
		}
		delete(cols_slice, allocator)
		delete(col_indexes)
		failed = true
		return {}, .Out_Of_Memory
	}

	return Log_File_Schema {
		table_name   = owned_name,
		row_count    = row_count,
		parse_errors = parse_errors,
		columns      = cols_slice,
		column_indexes = col_indexes,
		allocator    = allocator,
	}, .None
}

// ---- Regex inspection -------------------------------------------------------

@(private = "file")
inspect_regex_log :: proc(
	path, table_name: string,
	opts: Log_Read_Options,
	allocator: runtime.Allocator,
) -> (schema: Log_File_Schema, err: snout_core.Error) {
	group_names, modified_pattern, names_ok := parse_named_groups(opts.pattern, context.temp_allocator)
	if !names_ok || len(group_names) == 0 {
		return {}, .Log_Parse_Error
	}

	re, re_err := regex.create(modified_pattern, {}, context.temp_allocator)
	if re_err != nil {
		return {}, .Log_Parse_Error
	}
	defer regex.destroy_regex(re, context.temp_allocator)

	scanner, scan_err := open_jsonl_scanner(path, allocator = allocator)
	if scan_err != .None {
		return {}, scan_err
	}
	defer close_jsonl_scanner(&scanner)

	// Column types: inferred from first match; promoted on subsequent lines.
	kinds := make([]snout_core.Column_Type, len(group_names), context.temp_allocator)
	nullables := make([]bool, len(group_names), context.temp_allocator)

	row_count := 0
	parse_errors := 0

	for {
		line, done, line_err := next_jsonl_line(&scanner)
		if line_err != .None {
			return {}, line_err
		}
		if done {
			break
		}

		cap, matched := regex.match_and_allocate_capture(re, line, context.temp_allocator)
		if !matched {
			if opts.strict {
				return {}, .Log_Parse_Error
			}
			parse_errors += 1
			free_all(context.temp_allocator)
			row_count += 1
			continue
		}

		for name, i in group_names {
			cap_idx := i + 1
			if cap_idx >= len(cap.groups) || cap.groups[cap_idx] == "" {
				nullables[i] = true
				continue
			}
			val := cap.groups[cap_idx]
			incoming := logfmt_infer_type(name, val)
			kinds[i] = promote_log_type(kinds[i], incoming)
		}

		free_all(context.temp_allocator)
		row_count += 1
	}

	if row_count == 0 {
		return {}, .Empty_Input
	}

	// Build owned schema from group names and inferred types.
	cols, col_err := make([]Log_Column_Schema, len(group_names), allocator)
	if col_err != nil {
		return {}, .Out_Of_Memory
	}
	for gname, i in group_names {
		name, name_err := strings.clone(gname, allocator)
		if name_err != nil {
			for j in 0 ..< i {
				delete(cols[j].name, allocator)
			}
			delete(cols, allocator)
			return {}, .Out_Of_Memory
		}
		kind := kinds[i]
		if kind == .Unknown {
			kind = .String
		}
		cols[i] = Log_Column_Schema{name = name, kind = kind, nullable = nullables[i] || parse_errors > 0}
	}

	col_indexes := make(map[string]int, allocator = allocator)
	for col, i in cols {
		col_indexes[col.name] = i
	}

	owned_name, name_err := strings.clone(table_name, allocator)
	if name_err != nil {
		for col in cols {
			delete(col.name, allocator)
		}
		delete(cols, allocator)
		delete(col_indexes)
		return {}, .Out_Of_Memory
	}

	return Log_File_Schema {
		table_name   = owned_name,
		row_count    = row_count,
		parse_errors = parse_errors,
		columns      = cols,
		column_indexes = col_indexes,
		allocator    = allocator,
	}, .None
}

// ---- Fixed-format populate (CLF, Combined, Syslog) -------------------------

@(private = "file")
populate_fixed_log :: proc(
	path: string,
	schema: ^Log_File_Schema,
	parse_fn: proc(string, runtime.Allocator) -> ([]Log_Field, bool),
	opts: Log_Read_Options,
	allocator: runtime.Allocator,
) -> (table: snout_core.Table, err: snout_core.Error) {
	alloc_err: snout_core.Error
	table, alloc_err = alloc_log_table(schema, allocator)
	if alloc_err != .None {
		return {}, alloc_err
	}

	failed := true
	defer if failed {snout_core.free_table(&table)}

	scanner, scan_err := open_jsonl_scanner(path, allocator = allocator)
	if scan_err != .None {
		return {}, scan_err
	}
	defer close_jsonl_scanner(&scanner)

	row := 0
	for {
		line, done, line_err := next_jsonl_line(&scanner)
		if line_err != .None {
			return {}, line_err
		}
		if done {
			break
		}
		if row >= schema.row_count {
			return {}, .Input_Changed_During_Read
		}

		fields, ok := parse_fn(line, context.temp_allocator)
		if !ok {
			if opts.strict {
				return {}, .Log_Parse_Error
			}
			null_pad_row(&table, row)
			schema.parse_errors += 1
			free_all(context.temp_allocator)
			row += 1
			continue
		}

		for field in fields {
			col_idx, col_found := schema.column_indexes[field.name]
			if !col_found {
				continue
			}
			col := &table.columns[col_idx]
			if field.null {
				col.null_mask[row] = true
				continue
			}
			set_log_value(col, row, field.value, allocator)
		}

		free_all(context.temp_allocator)
		row += 1
	}
	if row != schema.row_count {
		return {}, .Input_Changed_During_Read
	}

	failed = false
	return table, .None
}

// ---- Logfmt populate --------------------------------------------------------

@(private = "file")
populate_logfmt_log :: proc(
	path: string,
	schema: ^Log_File_Schema,
	opts: Log_Read_Options,
	allocator: runtime.Allocator,
) -> (table: snout_core.Table, err: snout_core.Error) {
	alloc_err: snout_core.Error
	table, alloc_err = alloc_log_table(schema, allocator)
	if alloc_err != .None {
		return {}, alloc_err
	}

	failed := true
	defer if failed {snout_core.free_table(&table)}

	scanner, scan_err := open_jsonl_scanner(path, allocator = allocator)
	if scan_err != .None {
		return {}, scan_err
	}
	defer close_jsonl_scanner(&scanner)

	row := 0
	for {
		line, done, line_err := next_jsonl_line(&scanner)
		if line_err != .None {
			return {}, line_err
		}
		if done {
			break
		}
		if row >= schema.row_count {
			return {}, .Input_Changed_During_Read
		}

		fields, ok := parse_logfmt_line(line, context.temp_allocator)
		if !ok {
			if opts.strict {
				return {}, .Log_Parse_Error
			}
			null_pad_row(&table, row)
			schema.parse_errors += 1
			free_all(context.temp_allocator)
			row += 1
			continue
		}

		for field in fields {
			col_idx, col_found := schema.column_indexes[field.name]
			if !col_found {
				continue
			}
			col := &table.columns[col_idx]
			if field.null {
				col.null_mask[row] = true
				continue
			}
			set_log_value(col, row, field.value, allocator)
		}

		free_all(context.temp_allocator)
		row += 1
	}
	if row != schema.row_count {
		return {}, .Input_Changed_During_Read
	}

	failed = false
	return table, .None
}

// ---- Regex populate ---------------------------------------------------------

@(private = "file")
populate_regex_log :: proc(
	path: string,
	schema: ^Log_File_Schema,
	opts: Log_Read_Options,
	allocator: runtime.Allocator,
) -> (table: snout_core.Table, err: snout_core.Error) {
	group_names, modified_pattern, names_ok := parse_named_groups(opts.pattern, context.temp_allocator)
	if !names_ok {
		return {}, .Log_Parse_Error
	}

	re, re_err := regex.create(modified_pattern, {}, context.temp_allocator)
	if re_err != nil {
		return {}, .Log_Parse_Error
	}
	defer regex.destroy_regex(re, context.temp_allocator)

	alloc_err: snout_core.Error
	table, alloc_err = alloc_log_table(schema, allocator)
	if alloc_err != .None {
		return {}, alloc_err
	}

	failed := true
	defer if failed {snout_core.free_table(&table)}

	scanner, scan_err := open_jsonl_scanner(path, allocator = allocator)
	if scan_err != .None {
		return {}, scan_err
	}
	defer close_jsonl_scanner(&scanner)

	row := 0
	for {
		line, done, line_err := next_jsonl_line(&scanner)
		if line_err != .None {
			return {}, line_err
		}
		if done {
			break
		}
		if row >= schema.row_count {
			return {}, .Input_Changed_During_Read
		}

		cap, matched := regex.match_and_allocate_capture(re, line, context.temp_allocator)
		if !matched {
			if opts.strict {
				return {}, .Log_Parse_Error
			}
			null_pad_row(&table, row)
			schema.parse_errors += 1
			free_all(context.temp_allocator)
			row += 1
			continue
		}

		for gname, i in group_names {
			col_idx, col_found := schema.column_indexes[gname]
			if !col_found {
				continue
			}
			col := &table.columns[col_idx]
			cap_idx := i + 1
			if cap_idx >= len(cap.groups) || cap.groups[cap_idx] == "" {
				col.null_mask[row] = true
				continue
			}
			set_log_value(col, row, cap.groups[cap_idx], allocator)
		}

		free_all(context.temp_allocator)
		row += 1
	}
	if row != schema.row_count {
		return {}, .Input_Changed_During_Read
	}

	failed = false
	return table, .None
}

// ---- Table allocation and value setting helpers ----------------------------

// alloc_log_table creates an empty table with all columns nullable (null_mask all true).
@(private = "file")
alloc_log_table :: proc(
	schema: ^Log_File_Schema,
	allocator: runtime.Allocator,
) -> (table: snout_core.Table, err: snout_core.Error) {
	n := schema.row_count
	cols, alloc_err := make([]snout_core.Column, len(schema.columns), allocator)
	if alloc_err != nil {
		return {}, .Out_Of_Memory
	}

	failed := false
	allocated := 0
	defer if failed {
		for i in 0 ..< allocated {
			col := &cols[i]
			delete(col.name, allocator)
			if col.null_mask != nil {
				delete(col.null_mask, allocator)
			}
			switch col.kind {
			case .String, .Timestamp:
				if col.strings != nil {
					delete(col.strings, allocator)
				}
			case .Int64:
				if col.int64s != nil {
					delete(col.int64s, allocator)
				}
			case .Float64:
				if col.float64s != nil {
					delete(col.float64s, allocator)
				}
			case .Bool:
				if col.bools != nil {
					delete(col.bools, allocator)
				}
			case .Unknown:
			}
		}
		delete(cols, allocator)
	}

	for sch_col, i in schema.columns {
		col := &cols[i]
		name, name_err := strings.clone(sch_col.name, allocator)
		if name_err != nil {
			failed = true
			return {}, .Out_Of_Memory
		}
		col.name = name
		col.kind = sch_col.kind
		col.nullable = true

		null_mask, nm_err := make([]bool, n, allocator)
		if nm_err != nil {
			delete(name, allocator)
			failed = true
			return {}, .Out_Of_Memory
		}
		// All rows start as null; populate sets non-null entries.
		mem.set(raw_data(null_mask), 1, n)
		col.null_mask = null_mask

		switch sch_col.kind {
		case .String, .Timestamp:
			s, s_err := make([]string, n, allocator)
			if s_err != nil {
				failed = true
				return {}, .Out_Of_Memory
			}
			col.strings = s
		case .Int64:
			iv, iv_err := make([]i64, n, allocator)
			if iv_err != nil {
				failed = true
				return {}, .Out_Of_Memory
			}
			col.int64s = iv
		case .Float64:
			fv, fv_err := make([]f64, n, allocator)
			if fv_err != nil {
				failed = true
				return {}, .Out_Of_Memory
			}
			col.float64s = fv
		case .Bool:
			bv, bv_err := make([]bool, n, allocator)
			if bv_err != nil {
				failed = true
				return {}, .Out_Of_Memory
			}
			col.bools = bv
		case .Unknown:
		}
		allocated += 1
	}

	table_name, tn_err := strings.clone(schema.table_name, allocator)
	if tn_err != nil {
		failed = true
		return {}, .Out_Of_Memory
	}

	return snout_core.Table {
		name      = table_name,
		row_count = n,
		columns   = cols,
		allocator = allocator,
	}, .None
}

// null_pad_row sets every column's null_mask[row] = true (the alloc already does this,
// but this proc is called to be explicit when a line fails to parse).
@(private = "file")
null_pad_row :: proc(table: ^snout_core.Table, row: int) {
	for &col in table.columns {
		if col.null_mask != nil && row < len(col.null_mask) {
			col.null_mask[row] = true
		}
	}
}

// set_log_value writes a string value into the typed column at the given row
// and clears the null_mask. On type mismatch the row stays null.
@(private = "file")
set_log_value :: proc(col: ^snout_core.Column, row: int, value: string, allocator: runtime.Allocator) {
	switch col.kind {
	case .String, .Timestamp:
		cloned, err := strings.clone(value, allocator)
		if err != nil {
			return
		}
		col.strings[row] = cloned
		col.null_mask[row] = false
	case .Int64:
		v, ok := strconv.parse_i64(value)
		if !ok {
			return
		}
		col.int64s[row] = v
		col.null_mask[row] = false
	case .Float64:
		v, ok := strconv.parse_f64(value)
		if !ok {
			return
		}
		col.float64s[row] = v
		col.null_mask[row] = false
	case .Bool:
		switch value {
		case "true":
			col.bools[row] = true
			col.null_mask[row] = false
		case "false":
			col.bools[row] = false
			col.null_mask[row] = false
		}
	case .Unknown:
	}
}
