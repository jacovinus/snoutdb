package ingest

import "base:runtime"
import "core:strings"
import snout_core "../core"

Csv_Column_Schema :: struct {
	name:     string,
	kind:     snout_core.Column_Type,
	nullable: bool,
}

Csv_File_Schema :: struct {
	table_name: string,
	row_count:  int,
	columns:    []Csv_Column_Schema,
	allocator:  runtime.Allocator,
}

// inspect_csv_file scans the whole file once and returns the exact schema:
// header names, promoted column types, nullability, and row count. Inference
// rules are identical to read_csv_string (infer_value_type + promote_types).
inspect_csv_file :: proc(
	path, table_name: string,
	buffer_size := CSV_SCANNER_BUFFER_SIZE,
	allocator := context.allocator,
) -> (schema: Csv_File_Schema, err: snout_core.Error) {
	scanner, open_err := open_csv_scanner(path, buffer_size, allocator)
	if open_err != .None {
		return {}, open_err
	}
	defer close_csv_scanner(&scanner)

	header, header_done, header_err := next_csv_record(&scanner)
	if header_err != .None {
		return {}, header_err
	}
	if header_done || len(header.fields) == 0 {
		return {}, .Empty_Input
	}

	column_count := len(header.fields)
	owned_name, alloc_err := strings.clone(table_name, allocator)
	if alloc_err != nil {
		return {}, .Out_Of_Memory
	}

	columns: []Csv_Column_Schema
	columns, alloc_err = make([]Csv_Column_Schema, column_count, allocator)
	if alloc_err != nil {
		delete(owned_name, allocator)
		return {}, .Out_Of_Memory
	}

	cloned_columns := 0
	failed := false
	defer if failed {
		for column in columns[:cloned_columns] {
			delete(column.name, allocator)
		}
		delete(columns, allocator)
		delete(owned_name, allocator)
	}

	for field, index in header.fields {
		columns[index].name, alloc_err = strings.clone(field, allocator)
		if alloc_err != nil {
			failed = true
			return {}, .Out_Of_Memory
		}
		columns[index].kind = .Unknown
		cloned_columns += 1
	}

	row_count := 0
	for {
		record, done, record_err := next_csv_record(&scanner)
		if record_err != .None {
			failed = true
			return {}, record_err
		}
		if done {
			break
		}
		if len(record.fields) != column_count {
			failed = true
			return {}, .Column_Count_Mismatch
		}
		if row_count == max(int) {
			failed = true
			return {}, .Too_Many_Records
		}
		row_count += 1
		for field, index in record.fields {
			if field == "" {
				columns[index].nullable = true
				continue
			}
			columns[index].kind = promote_types(
				columns[index].kind,
				infer_value_type(field),
			)
		}
	}

	for &column in columns {
		if column.kind == .Unknown {
			column.kind = .String
		}
	}
	schema.table_name = owned_name
	schema.row_count = row_count
	schema.columns = columns
	schema.allocator = allocator
	return schema, .None
}

free_csv_file_schema :: proc(schema: ^Csv_File_Schema) {
	if schema.table_name != "" {
		delete(schema.table_name, schema.allocator)
	}
	for column in schema.columns {
		delete(column.name, schema.allocator)
	}
	delete(schema.columns, schema.allocator)
	schema^ = {}
}
