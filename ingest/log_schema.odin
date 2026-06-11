package ingest

import "base:runtime"
import "core:strings"
import snout_core "../core"

Log_Format :: enum {
	CLF,
	Combined,
	Logfmt,
	Syslog,
	Regex,
}

Log_Read_Options :: struct {
	format:     Log_Format,
	pattern:    string,
	strict:     bool,
	has_format: bool, // false → auto-detect on first use
}

Log_Column_Schema :: struct {
	name:     string,
	kind:     snout_core.Column_Type,
	nullable: bool,
}

Log_File_Schema :: struct {
	table_name:     string,
	row_count:      int,
	parse_errors:   int,
	format:         Log_Format, // resolved format (after auto-detect)
	columns:        []Log_Column_Schema,
	column_indexes: map[string]int,
	allocator:      runtime.Allocator,
}

free_log_file_schema :: proc(schema: ^Log_File_Schema) {
	if schema.table_name != "" {
		delete(schema.table_name, schema.allocator)
	}
	for col in schema.columns {
		delete(col.name, schema.allocator)
	}
	if schema.columns != nil {
		delete(schema.columns, schema.allocator)
	}
	delete(schema.column_indexes)
	schema^ = {}
}

// clone_log_schema_cols allocates an owned copy of a static column slice.
clone_log_schema_cols :: proc(
	cols: []Log_Column_Schema,
	allocator: runtime.Allocator,
) -> ([]Log_Column_Schema, snout_core.Error) {
	result, alloc_err := make([]Log_Column_Schema, len(cols), allocator)
	if alloc_err != nil {
		return nil, .Out_Of_Memory
	}
	for col, i in cols {
		name, name_err := strings.clone(col.name, allocator)
		if name_err != nil {
			for j in 0 ..< i {
				delete(result[j].name, allocator)
			}
			delete(result, allocator)
			return nil, .Out_Of_Memory
		}
		result[i] = Log_Column_Schema{name = name, kind = col.kind, nullable = col.nullable}
	}
	return result, .None
}
