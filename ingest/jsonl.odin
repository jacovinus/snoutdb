package ingest

import "base:runtime"
import "core:encoding/json"
import "core:fmt"
import "core:math"
import "core:mem"
import "core:strconv"
import "core:strings"
import snout_core "../core"

JSONL_MAX_LINE_SIZE :: 16 * 1024 * 1024
JSONL_MAX_COLUMN_NAME :: 1 << 20
JSONL_MAX_COLUMNS :: 65_535

Jsonl_Read_Error :: struct {
	code: snout_core.Error,
	line: int,
}

Json_Scalar_Kind :: enum {
	Null,
	String,
	Int64,
	Float64,
	Bool,
}

Json_Scalar :: struct {
	kind:        Json_Scalar_Kind,
	string_value: string,
	int_value:    i64,
	float_value:  f64,
	bool_value:   bool,
}

Json_Field :: struct {
	name:  string,
	value: Json_Scalar,
}

Json_Record :: [dynamic]Json_Field
Json_Records :: [dynamic]Json_Record

Json_Schema_Column :: struct {
	name:     string,
	kind:     snout_core.Column_Type,
	nullable: bool,
}

read_jsonl_table :: proc(
	path, table_name: string,
	allocator := context.allocator,
) -> (snout_core.Table, snout_core.Error) {
	table, detail := read_jsonl_table_detailed(path, table_name, allocator)
	return table, detail.code
}

read_jsonl_table_detailed :: proc(
	path, table_name: string,
	allocator := context.allocator,
) -> (snout_core.Table, Jsonl_Read_Error) {
	schema, schema_err := inspect_jsonl_file(path, table_name, allocator = allocator)
	if schema_err != .None {
		return {}, Jsonl_Read_Error{code = schema_err}
	}
	defer free_jsonl_file_schema(&schema)
	table, table_err := populate_jsonl_table(path, &schema, allocator)
	return table, Jsonl_Read_Error{code = table_err}
}

// populate_jsonl_table is pass 2: given a schema from inspect_jsonl_file it
// opens the file again, parses each record, and fills pre-allocated typed
// columns directly without building intermediate Json_Records in memory.
// If the file was modified between passes the function returns Input_Changed_During_Read.
populate_jsonl_table :: proc(
	path: string,
	schema: ^Jsonl_File_Schema,
	allocator: runtime.Allocator,
) -> (table: snout_core.Table, err: snout_core.Error) {
	table.allocator = allocator
	defer if err != .None {
		snout_core.free_table(&table)
		table = {}
	}

	table.name, _ = strings.clone(schema.table_name, allocator)
	if table.name == "" && schema.table_name != "" {
		return table, .Out_Of_Memory
	}

	table.row_count = schema.row_count
	col_count := len(schema.columns)
	table.columns, _ = make([]snout_core.Column, col_count, allocator)
	if col_count > 0 && table.columns == nil {
		return table, .Out_Of_Memory
	}

	// Allocate typed arrays for each column and initialize null_masks to true.
	for schema_col, idx in schema.columns {
		col := &table.columns[idx]
		col.name, _ = strings.clone(schema_col.name, allocator)
		if col.name == "" && schema_col.name != "" {
			return table, .Out_Of_Memory
		}
		col.kind = schema_col.kind
		col.nullable = schema_col.nullable
		if schema.row_count > 0 {
			col.null_mask, _ = make([]bool, schema.row_count, allocator)
			if col.null_mask == nil {
				return table, .Out_Of_Memory
			}
			mem.set(raw_data(col.null_mask), 1, schema.row_count)
		}
		alloc_err := allocate_json_column(col, schema.row_count, allocator)
		if alloc_err != .None {
			return table, alloc_err
		}
	}

	scanner, open_err := open_jsonl_scanner(path, allocator = allocator)
	if open_err != .None {
		return table, open_err
	}
	defer close_jsonl_scanner(&scanner)

	record_arena: mem.Dynamic_Arena
	mem.dynamic_arena_init(&record_arena, allocator, allocator, alignment = 64)
	defer mem.dynamic_arena_destroy(&record_arena)
	record_alloc := mem.dynamic_arena_allocator(&record_arena)

	row_index := 0
	for {
		line, done, line_err := next_jsonl_line(&scanner)
		if line_err != .None {
			return table, line_err
		}
		if done {
			break
		}
		if row_index >= schema.row_count {
			return table, .Input_Changed_During_Read
		}

		record, parse_err := parse_json_object_line(line, record_alloc)
		if parse_err != .None {
			return table, parse_err
		}

		for field in record {
			col_idx, found := schema.column_indexes[field.name]
			if !found {
				return table, .Input_Changed_During_Read
			}
			if field.value.kind == .Null {
				// null_mask already true
				continue
			}
			col := &table.columns[col_idx]
			col.null_mask[row_index] = false
			set_err := set_json_column_value(col, row_index, field.value, allocator)
			if set_err != .None {
				return table, .Input_Changed_During_Read
			}
		}

		mem.dynamic_arena_free_all(&record_arena)
		row_index += 1
	}

	if row_index != schema.row_count {
		return table, .Input_Changed_During_Read
	}

	return table, .None
}

read_jsonl_string :: proc(
	input, table_name: string,
	allocator := context.allocator,
) -> (snout_core.Table, snout_core.Error) {
	table, detail := read_jsonl_string_detailed(input, table_name, allocator)
	return table, detail.code
}

read_jsonl_string_detailed :: proc(
	input, table_name: string,
	allocator := context.allocator,
) -> (snout_core.Table, Jsonl_Read_Error) {
	return read_jsonl_string_with_limit(input, table_name, JSONL_MAX_LINE_SIZE, allocator)
}

read_jsonl_string_with_limit :: proc(
	input, table_name: string,
	max_line_size: int,
	allocator := context.allocator,
) -> (snout_core.Table, Jsonl_Read_Error) {
	arena: mem.Dynamic_Arena
	mem.dynamic_arena_init(&arena, allocator, allocator, alignment=64)
	defer mem.dynamic_arena_destroy(&arena)
	temp_allocator := mem.dynamic_arena_allocator(&arena)

	records := make(Json_Records, 0, allocator=temp_allocator)
	line_number := 1
	start := 0
	for start <= len(input) {
		end := start
		for end < len(input) && input[end] != '\n' {
			end += 1
		}
		line := input[start:end]
		if len(line) > 0 && line[len(line)-1] == '\r' {
			line = line[:len(line)-1]
		}
		if len(line) > max_line_size {
			return {}, Jsonl_Read_Error{code = .Line_Too_Large, line = line_number}
		}
		line = strings.trim_space(line)
		if line != "" {
			record, parse_err := parse_json_object_line(line, temp_allocator)
			if parse_err != .None {
				return {}, Jsonl_Read_Error{code = parse_err, line = line_number}
			}
			if len(records) == max(int) {
				return {}, Jsonl_Read_Error{code = .Too_Many_Records, line = line_number}
			}
			append(&records, record)
		}

		if end == len(input) {
			break
		}
		start = end + 1
		line_number += 1
	}

	if len(records) == 0 {
		return {}, Jsonl_Read_Error{code = .Empty_Input}
	}

	table, build_err := build_jsonl_table(records[:], table_name, allocator, temp_allocator)
	return table, Jsonl_Read_Error{code = build_err}
}

parse_json_object_line :: proc(
	line: string,
	allocator: runtime.Allocator,
) -> (record: Json_Record, err: snout_core.Error) {
	tokenizer := json.make_tokenizer(line, .JSON, true)
	token, json_err := json.get_token(&tokenizer)
	if json_err != nil || token.kind != .Open_Brace {
		return nil, .Expected_JSON_Object
	}

	record = make(Json_Record, 0, allocator=allocator)
	seen := make(map[string]bool, allocator=allocator)

	token, json_err = json.get_token(&tokenizer)
	if json_err != nil {
		return nil, .Malformed_JSON
	}
	if token.kind == .Close_Brace {
		end_token, end_err := json.get_token(&tokenizer)
		if end_err != .EOF || end_token.kind != .EOF {
			return nil, .Malformed_JSON
		}
		return record, .None
	}

	for {
		if token.kind != .String {
			return nil, .Malformed_JSON
		}
		key, unquote_err := json.unquote_string(token, .JSON, allocator)
		if unquote_err != nil {
			return nil, .Malformed_JSON
		}
		if len(key) > JSONL_MAX_COLUMN_NAME {
			return nil, .Value_Too_Large
		}
		if key in seen {
			return nil, .Duplicate_JSON_Key
		}
		seen[key] = true

		colon, colon_err := json.get_token(&tokenizer)
		if colon_err != nil || colon.kind != .Colon {
			return nil, .Malformed_JSON
		}
		value_token, value_err := json.get_token(&tokenizer)
		if value_err != nil {
			return nil, .Malformed_JSON
		}
		value, scalar_err := scalar_from_token(value_token, allocator)
		if scalar_err != .None {
			return nil, scalar_err
		}
		append(&record, Json_Field{name = key, value = value})

		separator, separator_err := json.get_token(&tokenizer)
		if separator_err != nil {
			return nil, .Malformed_JSON
		}
		if separator.kind == .Close_Brace {
			break
		}
		if separator.kind != .Comma {
			return nil, .Malformed_JSON
		}
		token, json_err = json.get_token(&tokenizer)
		if json_err != nil {
			return nil, .Malformed_JSON
		}
	}

	end_token, end_err := json.get_token(&tokenizer)
	if end_err != .EOF || end_token.kind != .EOF {
		return nil, .Malformed_JSON
	}
	return record, .None
}

scalar_from_token :: proc(
	token: json.Token,
	allocator: runtime.Allocator,
) -> (Json_Scalar, snout_core.Error) {
	#partial switch token.kind {
	case .Null:
		return Json_Scalar{kind = .Null}, .None
	case .True:
		return Json_Scalar{kind = .Bool, bool_value = true}, .None
	case .False:
		return Json_Scalar{kind = .Bool, bool_value = false}, .None
	case .String:
		value, err := json.unquote_string(token, .JSON, allocator)
		if err != nil {
			return {}, .Malformed_JSON
		}
		return Json_Scalar{kind = .String, string_value = value}, .None
	case .Integer:
		value, ok := parse_json_i64(token.text)
		if !ok {
			return {}, .Number_Out_Of_Range
		}
		return Json_Scalar{kind = .Int64, int_value = value}, .None
	case .Float:
		value, ok := strconv.parse_f64(token.text)
		if !ok || math.is_inf(value) || math.is_nan(value) {
			return {}, .Number_Out_Of_Range
		}
		return Json_Scalar{kind = .Float64, float_value = value}, .None
	case .Open_Brace, .Open_Bracket:
		return {}, .Unsupported_JSON_Value
	}
	return {}, .Malformed_JSON
}

parse_json_i64 :: proc(text: string) -> (i64, bool) {
	if text == "" {
		return 0, false
	}
	negative := text[0] == '-'
	start := 1 if negative else 0
	if start == len(text) {
		return 0, false
	}

	limit := u64(max(i64))
	if negative {
		limit += 1
	}
	magnitude: u64
	for character in text[start:] {
		if character < '0' || character > '9' {
			return 0, false
		}
		digit := u64(character - '0')
		if magnitude > (limit-digit)/10 {
			return 0, false
		}
		magnitude = magnitude*10 + digit
	}

	if negative {
		if magnitude == u64(max(i64))+1 {
			return min(i64), true
		}
		return -i64(magnitude), true
	}
	return i64(magnitude), true
}

build_jsonl_table :: proc(
	records: []Json_Record,
	table_name: string,
	allocator, temp_allocator: runtime.Allocator,
) -> (snout_core.Table, snout_core.Error) {
	schema := make([dynamic]Json_Schema_Column, 0, allocator=temp_allocator)
	column_indexes := make(map[string]int, allocator=temp_allocator)

	for record, row_index in records {
		seen_in_record := make(map[string]bool, allocator=temp_allocator)
		for field in record {
			seen_in_record[field.name] = true
			if column_index, found := column_indexes[field.name]; found {
				next_kind, promote_err := promote_json_type(
					schema[column_index].kind,
					json_scalar_column_type(field.value),
				)
				if promote_err != .None {
					return {}, promote_err
				}
				schema[column_index].kind = next_kind
				if field.value.kind == .Null {
					schema[column_index].nullable = true
				}
			} else {
				if len(schema) >= JSONL_MAX_COLUMNS {
					return {}, .Too_Many_Columns
				}
				kind := json_scalar_column_type(field.value)
				append(&schema, Json_Schema_Column{
					name = field.name,
					kind = kind,
					nullable = row_index > 0 || field.value.kind == .Null,
				})
				column_indexes[field.name] = len(schema) - 1
			}
		}
		for &column in schema {
			if column.name not_in seen_in_record {
				column.nullable = true
			}
		}
	}

	for &column in schema {
		if column.kind == .Unknown {
			column.kind = .String
		}
	}

	table: snout_core.Table
	table.allocator = allocator
	table.name, _ = strings.clone(table_name, allocator)
	if table.name == "" && table_name != "" {
		return {}, .Out_Of_Memory
	}
	defer snout_core.free_table(&table)
	table.row_count = len(records)
	table.columns, _ = make([]snout_core.Column, len(schema), allocator)
	if len(schema) > 0 && table.columns == nil {
		return {}, .Out_Of_Memory
	}

	for schema_column, column_index in schema {
		column := &table.columns[column_index]
		column.name, _ = strings.clone(schema_column.name, allocator)
		if column.name == "" && schema_column.name != "" {
			return {}, .Out_Of_Memory
		}
		column.kind = schema_column.kind
		column.nullable = schema_column.nullable
		column.null_mask, _ = make([]bool, len(records), allocator)
		if len(records) > 0 && column.null_mask == nil {
			return {}, .Out_Of_Memory
		}
		if allocate_json_column(column, len(records), allocator) != .None {
			return {}, .Out_Of_Memory
		}

		for record, row_index in records {
			field, found := find_json_field(record, column.name)
			if !found || field.value.kind == .Null {
				column.null_mask[row_index] = true
				continue
			}
			if set_json_column_value(column, row_index, field.value, allocator) != .None {
				return {}, .Out_Of_Memory
			}
		}
	}
	result := table
	table = {}
	return result, .None
}

json_scalar_column_type :: proc(value: Json_Scalar) -> snout_core.Column_Type {
	switch value.kind {
	case .Null:
		return .Unknown
	case .String:
		return .Timestamp if is_timestamp(value.string_value) else .String
	case .Int64:
		return .Int64
	case .Float64:
		return .Float64
	case .Bool:
		return .Bool
	}
	return .Unknown
}

promote_json_type :: proc(
	current, incoming: snout_core.Column_Type,
) -> (snout_core.Column_Type, snout_core.Error) {
	if incoming == .Unknown {
		return current, .None
	}
	if current == .Unknown || current == incoming {
		return incoming, .None
	}
	if (current == .Int64 && incoming == .Float64) ||
	   (current == .Float64 && incoming == .Int64) {
		return .Float64, .None
	}
	if current == .String || incoming == .String {
		return .String, .None
	}
	if current == .Timestamp && incoming == .String ||
	   current == .String && incoming == .Timestamp {
		return .String, .None
	}
	return .Unknown, .Incompatible_JSON_Types
}

allocate_json_column :: proc(
	column: ^snout_core.Column,
	row_count: int,
	allocator: runtime.Allocator,
) -> snout_core.Error {
	switch column.kind {
	case .String, .Timestamp:
		column.strings, _ = make([]string, row_count, allocator)
		if row_count > 0 && column.strings == nil {
			return .Out_Of_Memory
		}
	case .Int64:
		column.int64s, _ = make([]i64, row_count, allocator)
		if row_count > 0 && column.int64s == nil {
			return .Out_Of_Memory
		}
	case .Float64:
		column.float64s, _ = make([]f64, row_count, allocator)
		if row_count > 0 && column.float64s == nil {
			return .Out_Of_Memory
		}
	case .Bool:
		column.bools, _ = make([]bool, row_count, allocator)
		if row_count > 0 && column.bools == nil {
			return .Out_Of_Memory
		}
	case .Unknown:
		return .Invalid_Type
	}
	return .None
}

set_json_column_value :: proc(
	column: ^snout_core.Column,
	row_index: int,
	value: Json_Scalar,
	allocator: runtime.Allocator,
) -> snout_core.Error {
	switch column.kind {
	case .String:
		text := json_scalar_to_string(value, allocator)
		if text == "" && value.kind != .String {
			return .Out_Of_Memory
		}
		column.strings[row_index] = text
	case .Timestamp:
		if value.kind != .String {
			return .Invalid_Value
		}
		column.strings[row_index], _ = strings.clone(value.string_value, allocator)
	case .Int64:
		column.int64s[row_index] = value.int_value
	case .Float64:
		if value.kind == .Int64 {
			column.float64s[row_index] = f64(value.int_value)
		} else {
			column.float64s[row_index] = value.float_value
		}
	case .Bool:
		column.bools[row_index] = value.bool_value
	case .Unknown:
		return .Invalid_Type
	}
	return .None
}

json_scalar_to_string :: proc(
	value: Json_Scalar,
	allocator: runtime.Allocator,
) -> string {
	switch value.kind {
	case .String:
		result, _ := strings.clone(value.string_value, allocator)
		return result
	case .Int64:
		return fmt.aprintf("%d", value.int_value, allocator=allocator)
	case .Float64:
		return fmt.aprintf("%.17g", value.float_value, allocator=allocator)
	case .Bool:
		result, _ := strings.clone("true" if value.bool_value else "false", allocator)
		return result
	case .Null:
		result, _ := strings.clone("", allocator)
		return result
	}
	return ""
}

find_json_field :: proc(record: Json_Record, name: string) -> (^Json_Field, bool) {
	for &field in record {
		if field.name == name {
			return &field, true
		}
	}
	return nil, false
}
