package ingest

import "base:runtime"
import "core:mem"
import "core:strings"
import snout_core "../core"

Jsonl_Column_Schema :: struct {
	name:     string,
	kind:     snout_core.Column_Type,
	nullable: bool,
}

Jsonl_File_Schema :: struct {
	table_name:     string,
	row_count:      int,
	columns:        []Jsonl_Column_Schema,
	column_indexes: map[string]int, // keys are slices of columns[i].name
	allocator:      runtime.Allocator,
}

// inspect_jsonl_file streams the file once and returns the exact schema:
// column names (first-seen order), promoted types, nullability, and row count.
// Type inference rules are identical to build_jsonl_table (promote_json_type +
// json_scalar_column_type). Returns Empty_Input when the file has no records.
inspect_jsonl_file :: proc(
	path, table_name: string,
	buffer_size := JSONL_SCANNER_BUFFER_SIZE,
	allocator := context.allocator,
) -> (schema: Jsonl_File_Schema, err: snout_core.Error) {
	scanner, open_err := open_jsonl_scanner(path, buffer_size, allocator)
	if open_err != .None {
		return {}, open_err
	}
	defer close_jsonl_scanner(&scanner)

	owned_name, clone_err := strings.clone(table_name, allocator)
	if clone_err != nil {
		return {}, .Out_Of_Memory
	}

	columns_dyn := make([dynamic]Jsonl_Column_Schema, 0, allocator = allocator)
	column_indexes := make(map[string]int, allocator = allocator)

	failed := false
	cloned_count := 0
	defer if failed {
		for col in columns_dyn[:cloned_count] {
			delete(col.name, allocator)
		}
		delete(columns_dyn)
		delete(column_indexes)
		delete(owned_name, allocator)
	}

	// Per-record arena: reused for each parsed line, reset after processing.
	record_arena: mem.Dynamic_Arena
	mem.dynamic_arena_init(&record_arena, allocator, allocator, alignment = 64)
	defer mem.dynamic_arena_destroy(&record_arena)
	record_alloc := mem.dynamic_arena_allocator(&record_arena)

	row_count := 0
	for {
		line, done, line_err := next_jsonl_line(&scanner)
		if line_err != .None {
			failed = true
			return {}, line_err
		}
		if done {
			break
		}

		record, parse_err := parse_json_object_line(line, record_alloc)
		if parse_err != .None {
			failed = true
			return {}, parse_err
		}

		seen_in_record := make(map[string]bool, allocator = record_alloc)
		for field in record {
			seen_in_record[field.name] = true
			incoming := json_scalar_column_type(field.value)

			if col_idx, found := column_indexes[field.name]; found {
				new_kind, promote_err := promote_json_type(columns_dyn[col_idx].kind, incoming)
				if promote_err != .None {
					failed = true
					return {}, promote_err
				}
				columns_dyn[col_idx].kind = new_kind
				if field.value.kind == .Null {
					columns_dyn[col_idx].nullable = true
				}
			} else {
				if len(columns_dyn) >= JSONL_MAX_COLUMNS {
					failed = true
					return {}, .Too_Many_Columns
				}
				col_name, name_err := strings.clone(field.name, allocator)
				if name_err != nil {
					failed = true
					return {}, .Out_Of_Memory
				}
				new_col := Jsonl_Column_Schema{
					name     = col_name,
					kind     = incoming,
					nullable = row_count > 0 || field.value.kind == .Null,
				}
				append(&columns_dyn, new_col)
				cloned_count += 1
				column_indexes[col_name] = len(columns_dyn) - 1
			}
		}

		// Columns absent from this record are nullable.
		for &col in columns_dyn {
			if col.name not_in seen_in_record {
				col.nullable = true
			}
		}

		mem.dynamic_arena_free_all(&record_arena)

		if row_count == max(int) {
			failed = true
			return {}, .Too_Many_Records
		}
		row_count += 1
	}

	if row_count == 0 {
		failed = true
		return {}, .Empty_Input
	}

	for &col in columns_dyn {
		if col.kind == .Unknown {
			col.kind = .String
			col.nullable = true
		}
	}

	columns_slice, slice_err := make([]Jsonl_Column_Schema, len(columns_dyn), allocator)
	if slice_err != nil {
		failed = true
		return {}, .Out_Of_Memory
	}
	copy(columns_slice, columns_dyn[:])
	delete(columns_dyn)

	// Rebuild column_indexes to point into the final slice (same string pointers).
	clear(&column_indexes)
	for col, index in columns_slice {
		column_indexes[col.name] = index
	}

	schema.table_name = owned_name
	schema.row_count = row_count
	schema.columns = columns_slice
	schema.column_indexes = column_indexes
	schema.allocator = allocator
	return schema, .None
}

free_jsonl_file_schema :: proc(schema: ^Jsonl_File_Schema) {
	if schema.table_name != "" {
		delete(schema.table_name, schema.allocator)
	}
	for col in schema.columns {
		delete(col.name, schema.allocator)
	}
	delete(schema.columns, schema.allocator)
	// Keys are slices of column names, already freed above; just delete the map.
	delete(schema.column_indexes)
	schema^ = {}
}
