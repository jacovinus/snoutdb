package ingest

import "base:runtime"
import "core:strconv"
import "core:strings"
import snout_core "../core"

Raw_Record :: [dynamic]string
Raw_Records :: [dynamic]Raw_Record

// read_csv_table loads a CSV file with the streaming two-pass path: pass 1
// infers the exact schema and row count, pass 2 fills the final typed columns
// directly. Whole-file materialization and Raw_Records are never created.
read_csv_table :: proc(
	path, table_name: string,
	allocator := context.allocator,
) -> (snout_core.Table, snout_core.Error) {
	schema, schema_err := inspect_csv_file(path, table_name, allocator = allocator)
	if schema_err != .None {
		return {}, schema_err
	}
	defer free_csv_file_schema(&schema)
	return populate_csv_table(path, &schema, allocator)
}

// populate_csv_table runs pass 2 against a schema produced by
// inspect_csv_file. It returns Input_Changed_During_Read when the file no
// longer matches the schema.
populate_csv_table :: proc(
	path: string,
	schema: ^Csv_File_Schema,
	allocator: runtime.Allocator,
) -> (table: snout_core.Table, err: snout_core.Error) {
	scanner, open_err := open_csv_scanner(path, allocator = allocator)
	if open_err != .None {
		return table, open_err
	}
	defer close_csv_scanner(&scanner)

	header, header_done, header_err := next_csv_record(&scanner)
	if header_err != .None {
		return table, header_err
	}
	if header_done || len(header.fields) != len(schema.columns) {
		return table, .Input_Changed_During_Read
	}
	for field, index in header.fields {
		if field != schema.columns[index].name {
			return table, .Input_Changed_During_Read
		}
	}

	failed := false
	defer if failed {
		snout_core.free_table(&table)
		table = {}
	}

	table.allocator = allocator
	cloned_name, alloc_err := strings.clone(schema.table_name, allocator)
	if alloc_err != nil {
		return table, .Out_Of_Memory
	}
	table.name = cloned_name
	table.row_count = schema.row_count

	columns: []snout_core.Column
	columns, alloc_err = make([]snout_core.Column, len(schema.columns), allocator)
	if alloc_err != nil {
		failed = true
		return table, .Out_Of_Memory
	}
	table.columns = columns

	for column_schema, index in schema.columns {
		column := &table.columns[index]
		column.name, alloc_err = strings.clone(column_schema.name, allocator)
		if alloc_err != nil {
			failed = true
			return table, .Out_Of_Memory
		}
		column.kind = column_schema.kind
		column.nullable = column_schema.nullable
		column.null_mask, alloc_err = make([]bool, table.row_count, allocator)
		if alloc_err != nil {
			failed = true
			return table, .Out_Of_Memory
		}
		switch column_schema.kind {
		case .String, .Timestamp:
			column.strings, alloc_err = make([]string, table.row_count, allocator)
		case .Int64:
			column.int64s, alloc_err = make([]i64, table.row_count, allocator)
		case .Float64:
			column.float64s, alloc_err = make([]f64, table.row_count, allocator)
		case .Bool:
			column.bools, alloc_err = make([]bool, table.row_count, allocator)
		case .Unknown:
			failed = true
			return table, .Invalid_Value
		}
		if alloc_err != nil {
			failed = true
			return table, .Out_Of_Memory
		}
	}

	row_index := 0
	for {
		record, done, record_err := next_csv_record(&scanner)
		if record_err != .None {
			failed = true
			return table, record_err
		}
		if done {
			break
		}
		if row_index >= table.row_count || len(record.fields) != len(table.columns) {
			failed = true
			return table, .Input_Changed_During_Read
		}
		for field, column_index in record.fields {
			column := &table.columns[column_index]
			if field == "" {
				column.null_mask[row_index] = true
				if column.kind == .String || column.kind == .Timestamp {
					column.strings[row_index], alloc_err = strings.clone("", allocator)
					if alloc_err != nil {
						failed = true
						return table, .Out_Of_Memory
					}
				}
				continue
			}
			switch column.kind {
			case .String, .Timestamp:
				column.strings[row_index], alloc_err = strings.clone(field, allocator)
				if alloc_err != nil {
					failed = true
					return table, .Out_Of_Memory
				}
			case .Int64:
				parsed, ok := strconv.parse_i64(field)
				if !ok {
					failed = true
					return table, .Input_Changed_During_Read
				}
				column.int64s[row_index] = parsed
			case .Float64:
				parsed, ok := strconv.parse_f64(field)
				if !ok {
					failed = true
					return table, .Input_Changed_During_Read
				}
				column.float64s[row_index] = parsed
			case .Bool:
				switch field {
				case "true":
					column.bools[row_index] = true
				case "false":
					column.bools[row_index] = false
				case:
					failed = true
					return table, .Input_Changed_During_Read
				}
			case .Unknown:
				failed = true
				return table, .Invalid_Value
			}
		}
		row_index += 1
	}
	if row_index != table.row_count {
		failed = true
		return table, .Input_Changed_During_Read
	}
	return table, .None
}

read_csv_string :: proc(
	input, table_name: string,
	allocator := context.allocator,
) -> (table: snout_core.Table, err: snout_core.Error) {
	records, parse_err := parse_csv(input, allocator)
	if parse_err != .None {
		return {}, parse_err
	}
	defer free_records(&records, allocator)

	if len(records) == 0 || len(records[0]) == 0 {
		return {}, .Empty_Input
	}

	column_count := len(records[0])
	for row in records[1:] {
		if len(row) != column_count {
			return {}, .Column_Count_Mismatch
		}
	}

	table.allocator = allocator
	cloned_name, alloc_err := strings.clone(table_name, allocator)
	if alloc_err != nil {
		return {}, .Out_Of_Memory
	}
	table.name = cloned_name
	table.row_count = len(records) - 1
	columns: []snout_core.Column
	columns, alloc_err = make([]snout_core.Column, column_count, allocator)
	if alloc_err != nil {
		delete(table.name, allocator)
		return {}, .Out_Of_Memory
	}
	table.columns = columns

	for column_index in 0..<column_count {
		values := make([]string, table.row_count, context.temp_allocator)
		for row_index in 0..<table.row_count {
			values[row_index] = records[row_index+1][column_index]
		}

		kind, nullable := infer_column_type(values)
		column := &table.columns[column_index]
		column.name, alloc_err = strings.clone(records[0][column_index], allocator)
		if alloc_err != nil {
			snout_core.free_table(&table)
			return {}, .Out_Of_Memory
		}
		column.kind = kind
		column.nullable = nullable
		column.null_mask, alloc_err = make([]bool, table.row_count, allocator)
		if alloc_err != nil {
			snout_core.free_table(&table)
			return {}, .Out_Of_Memory
		}

		convert_err := convert_column(column, values, allocator)
		if convert_err != .None {
			snout_core.free_table(&table)
			return {}, convert_err
		}
	}

	return table, .None
}

convert_column :: proc(
	column: ^snout_core.Column,
	values: []string,
	allocator: runtime.Allocator,
) -> snout_core.Error {
	switch column.kind {
	case .String, .Timestamp:
		data, alloc_err := make([]string, len(values), allocator)
		if alloc_err != nil {
			return .Out_Of_Memory
		}
		column.strings = data
		for value, index in values {
			if value == "" {
				column.null_mask[index] = true
			}
			column.strings[index], alloc_err = strings.clone(value, allocator)
			if alloc_err != nil {
				return .Out_Of_Memory
			}
		}
	case .Int64:
		data, alloc_err := make([]i64, len(values), allocator)
		if alloc_err != nil {
			return .Out_Of_Memory
		}
		column.int64s = data
		for value, index in values {
			if value == "" {
				column.null_mask[index] = true
				continue
			}
			parsed, ok := strconv.parse_i64(value)
			if !ok {
				return .Invalid_Value
			}
			column.int64s[index] = parsed
		}
	case .Float64:
		data, alloc_err := make([]f64, len(values), allocator)
		if alloc_err != nil {
			return .Out_Of_Memory
		}
		column.float64s = data
		for value, index in values {
			if value == "" {
				column.null_mask[index] = true
				continue
			}
			parsed, ok := strconv.parse_f64(value)
			if !ok {
				return .Invalid_Value
			}
			column.float64s[index] = parsed
		}
	case .Bool:
		data, alloc_err := make([]bool, len(values), allocator)
		if alloc_err != nil {
			return .Out_Of_Memory
		}
		column.bools = data
		for value, index in values {
			if value == "" {
				column.null_mask[index] = true
				continue
			}
			switch value {
			case "true":
				column.bools[index] = true
			case "false":
				column.bools[index] = false
			case:
				return .Invalid_Value
			}
		}
	case .Unknown:
		return .Invalid_Value
	}
	return .None
}

parse_csv :: proc(
	input: string,
	allocator: runtime.Allocator,
) -> (records: Raw_Records, err: snout_core.Error) {
	records = make(Raw_Records, 0, allocator=allocator)
	row := make(Raw_Record, 0, allocator=allocator)
	field := make([dynamic]u8, 0, allocator=allocator)
	in_quotes := false
	field_quoted := false

	append_field :: proc(
		row: ^Raw_Record,
		field: ^[dynamic]u8,
		allocator: runtime.Allocator,
	) -> bool {
		value, alloc_err := strings.clone(string(field[:]), allocator)
		if alloc_err != nil {
			return false
		}
		append(row, value)
		clear(field)
		return true
	}

	append_row :: proc(
		records: ^Raw_Records,
		row: ^Raw_Record,
		allocator: runtime.Allocator,
	) {
		append(records, row^)
		row^ = make(Raw_Record, 0, allocator=allocator)
	}

	i := 0
	for i < len(input) {
		ch := input[i]
		if in_quotes {
			if ch == '"' {
				if i+1 < len(input) && input[i+1] == '"' {
					append(&field, byte('"'))
					i += 2
					continue
				}
				in_quotes = false
				i += 1
				continue
			}
			if ch == '\n' || ch == '\r' {
				free_partial_records(&records, &row, &field, allocator)
				return {}, .Multiline_Quoted_Field
			}
			append(&field, ch)
			i += 1
			continue
		}

		switch ch {
		case '"':
			if len(field) != 0 || field_quoted {
				free_partial_records(&records, &row, &field, allocator)
				return {}, .Parse
			}
			in_quotes = true
			field_quoted = true
		case ',':
			if !append_field(&row, &field, allocator) {
				free_partial_records(&records, &row, &field, allocator)
				return {}, .Parse
			}
			field_quoted = false
		case '\n':
			if !append_field(&row, &field, allocator) {
				free_partial_records(&records, &row, &field, allocator)
				return {}, .Parse
			}
			append_row(&records, &row, allocator)
			field_quoted = false
		case '\r':
			if i+1 >= len(input) || input[i+1] != '\n' {
				free_partial_records(&records, &row, &field, allocator)
				return {}, .Parse
			}
		case:
			if field_quoted {
				free_partial_records(&records, &row, &field, allocator)
				return {}, .Parse
			}
			append(&field, ch)
		}
		i += 1
	}

	if in_quotes {
		free_partial_records(&records, &row, &field, allocator)
		return {}, .Parse
	}
	if len(field) > 0 || len(row) > 0 || field_quoted {
		if !append_field(&row, &field, allocator) {
			free_partial_records(&records, &row, &field, allocator)
			return {}, .Parse
		}
		append_row(&records, &row, allocator)
	}
	delete(field)
	delete(row)
	return records, .None
}

free_records :: proc(records: ^Raw_Records, allocator: runtime.Allocator) {
	for &row in records {
		for value in row {
			delete(value, allocator)
		}
		delete(row)
	}
	delete(records^)
	records^ = nil
}

free_partial_records :: proc(
	records: ^Raw_Records,
	row: ^Raw_Record,
	field: ^[dynamic]u8,
	allocator: runtime.Allocator,
) {
	free_records(records, allocator)
	for value in row {
		delete(value, allocator)
	}
	delete(row^)
	delete(field^)
}
