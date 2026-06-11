package merge

import "base:runtime"
import "core:fmt"
import "core:mem"
import "core:strings"
import snout_core "../core"

// Merged_Column_Schema is the resolved descriptor for one output column after
// aligning all input tables. name is a slice into a source table's column name
// and is NOT owned by this struct.
Merged_Column_Schema :: struct {
	name:     string,
	kind:     snout_core.Column_Type,
	nullable: bool,
}

// append_tables concatenates base and all extras into a single Table.
// Schema is aligned: missing columns become null-padded; types are promoted.
// The caller owns the returned Table and must call snout_core.free_table.
append_tables :: proc(
	base: ^snout_core.Table,
	extras: []^snout_core.Table,
	allocator := context.allocator,
) -> (snout_core.Table, snout_core.Error) {
	all := make([]^snout_core.Table, 1 + len(extras), context.temp_allocator)
	defer delete(all, context.temp_allocator)
	all[0] = base
	for extra, i in extras {
		all[1 + i] = extra
	}
	return merge_sources(all, base.name, allocator)
}

// compact_table returns a fresh copy of table with identical schema and values.
// Today this is a deep copy; future tasks may apply encoding optimisations.
// The caller owns the returned Table and must call snout_core.free_table.
compact_table :: proc(
	table: ^snout_core.Table,
	allocator := context.allocator,
) -> (snout_core.Table, snout_core.Error) {
	sources := []^snout_core.Table{table}
	return merge_sources(sources, table.name, allocator)
}

// promote_merge_type returns the wider of two already-typed Column_Types.
// Mirrors the CSV/JSONL ingest promotion rules.
promote_merge_type :: proc(a, b: snout_core.Column_Type) -> snout_core.Column_Type {
	if a == b || b == .Unknown {return a}
	if a == .Unknown {return b}
	if (a == .Int64 && b == .Float64) || (a == .Float64 && b == .Int64) {return .Float64}
	return .String
}

// ---- internal ---------------------------------------------------------------

merge_sources :: proc(
	sources: []^snout_core.Table,
	output_name: string,
	allocator: runtime.Allocator,
) -> (snout_core.Table, snout_core.Error) {
	if len(sources) == 0 {
		return {}, .Empty_Input
	}

	// Compute total row count (checked for overflow)
	total_rows := 0
	for src in sources {
		if src.row_count > max(int) - total_rows {
			return {}, .Out_Of_Memory
		}
		total_rows += src.row_count
	}

	// Compute merged schema in temp memory
	schema, schema_err := compute_merged_schema(sources, context.temp_allocator)
	if schema_err != .None {
		return {}, schema_err
	}
	defer delete(schema, context.temp_allocator)

	// Allocate output table
	out: snout_core.Table
	out.allocator = allocator
	out.row_count = total_rows
	failed := true
	defer if failed {snout_core.free_table(&out)}

	out.name = strings.clone(output_name, allocator)
	out.columns, _ = make([]snout_core.Column, len(schema), allocator)
	if len(schema) > 0 && out.columns == nil {
		return {}, .Out_Of_Memory
	}

	for &col_schema, col_idx in schema {
		col := &out.columns[col_idx]
		col.name = strings.clone(col_schema.name, allocator)
		col.kind = col_schema.kind
		col.nullable = col_schema.nullable

		// null_mask must be row_count long for the storage writer to accept it
		col.null_mask, _ = make([]bool, total_rows, allocator)
		if total_rows > 0 && col.null_mask == nil {
			return {}, .Out_Of_Memory
		}

		if alloc_err := alloc_column_data(col, total_rows, allocator); alloc_err != .None {
			return {}, alloc_err
		}
	}

	// Copy rows from each source
	row_offset := 0
	for src in sources {
		for &col_schema, col_idx in schema {
			out_col := &out.columns[col_idx]
			src_col, found := snout_core.get_column(src, col_schema.name)

			if !found {
				// Column absent from this source: null-pad its rows
				for row in 0 ..< src.row_count {
					out_col.null_mask[row_offset + row] = true
				}
				zero_column_range(out_col, row_offset, src.row_count)
			} else {
				copy_err := copy_column_range(
					out_col,
					row_offset,
					src.row_count,
					src_col,
					col_schema.kind,
					allocator,
				)
				if copy_err != .None {
					return {}, copy_err
				}
			}
		}
		row_offset += src.row_count
	}

	failed = false
	return out, .None
}

compute_merged_schema :: proc(
	sources: []^snout_core.Table,
	allocator: runtime.Allocator,
) -> ([]Merged_Column_Schema, snout_core.Error) {
	// Ordered list of column names (first-seen order)
	col_names := make([dynamic]string, allocator)
	defer delete(col_names)

	col_types := make(map[string]snout_core.Column_Type, allocator)
	defer delete(col_types)

	col_nullable := make(map[string]bool, allocator)
	defer delete(col_nullable)

	col_seen_count := make(map[string]int, allocator)
	defer delete(col_seen_count)

	for src in sources {
		for &col in src.columns {
			if col.name not_in col_types {
				append(&col_names, col.name)
				col_types[col.name] = col.kind
				col_nullable[col.name] = col.nullable
				col_seen_count[col.name] = 1
			} else {
				col_types[col.name] = promote_merge_type(col_types[col.name], col.kind)
				if col.nullable {
					col_nullable[col.name] = true
				}
				col_seen_count[col.name] += 1
			}
		}
	}

	// A column absent from any source means those rows are null
	for name in col_names {
		if col_seen_count[name] < len(sources) {
			col_nullable[name] = true
		}
	}

	schema, alloc_err := make([]Merged_Column_Schema, len(col_names), allocator)
	if alloc_err != nil {
		return nil, .Out_Of_Memory
	}
	for name, idx in col_names {
		schema[idx] = Merged_Column_Schema {
			name     = name,
			kind     = col_types[name],
			nullable = col_nullable[name],
		}
	}
	return schema, .None
}

alloc_column_data :: proc(
	col: ^snout_core.Column,
	row_count: int,
	allocator: runtime.Allocator,
) -> snout_core.Error {
	alloc_err: runtime.Allocator_Error
	switch col.kind {
	case .Int64:
		col.int64s, alloc_err = make([]i64, row_count, allocator)
		if row_count > 0 && alloc_err != nil {return .Out_Of_Memory}
	case .Float64:
		col.float64s, alloc_err = make([]f64, row_count, allocator)
		if row_count > 0 && alloc_err != nil {return .Out_Of_Memory}
	case .Bool:
		col.bools, alloc_err = make([]bool, row_count, allocator)
		if row_count > 0 && alloc_err != nil {return .Out_Of_Memory}
	case .String, .Timestamp:
		col.strings, alloc_err = make([]string, row_count, allocator)
		if row_count > 0 && alloc_err != nil {return .Out_Of_Memory}
	case .Unknown:
		return .Invalid_Column_Data
	}
	return .None
}

zero_column_range :: proc(col: ^snout_core.Column, offset, count: int) {
	switch col.kind {
	case .Int64:
		mem.zero_slice(col.int64s[offset:offset + count])
	case .Float64:
		mem.zero_slice(col.float64s[offset:offset + count])
	case .Bool:
		mem.zero_slice(col.bools[offset:offset + count])
	case .String, .Timestamp:
		for i in 0 ..< count {
			col.strings[offset + i] = ""
		}
	case .Unknown:
	}
}

// copy_column_range copies src rows [0, row_count) into dst at [offset, offset+row_count).
// dst_kind is the final merged type and may differ from src.kind (type promotion).
copy_column_range :: proc(
	dst: ^snout_core.Column,
	offset, row_count: int,
	src: ^snout_core.Column,
	dst_kind: snout_core.Column_Type,
	allocator: runtime.Allocator,
) -> snout_core.Error {
	// Propagate null mask from source only when source is nullable.
	// Non-nullable source rows stay false (not null) in the destination.
	if src.nullable {
		copy(dst.null_mask[offset:], src.null_mask[:row_count])
	}

	switch dst_kind {
	case .Int64:
		copy(dst.int64s[offset:], src.int64s[:row_count])

	case .Float64:
		if src.kind == .Int64 {
			for i in 0 ..< row_count {
				dst.float64s[offset + i] = 0 if src.null_mask[i] else f64(src.int64s[i])
			}
		} else {
			copy(dst.float64s[offset:], src.float64s[:row_count])
		}

	case .Bool:
		copy(dst.bools[offset:], src.bools[:row_count])

	case .String, .Timestamp:
		// Destination is String (or Timestamp when types matched exactly).
		// Source may be any promoted-from type.
		switch src.kind {
		case .String, .Timestamp:
			for i in 0 ..< row_count {
				if src.null_mask[i] {
					dst.strings[offset + i] = ""
				} else {
					dst.strings[offset + i] = strings.clone(src.strings[i], allocator)
				}
			}
		case .Int64:
			for i in 0 ..< row_count {
				if src.null_mask[i] {
					dst.strings[offset + i] = ""
				} else {
					dst.strings[offset + i] = fmt.aprintf("%d", src.int64s[i], allocator = allocator)
				}
			}
		case .Float64:
			for i in 0 ..< row_count {
				if src.null_mask[i] {
					dst.strings[offset + i] = ""
				} else {
					dst.strings[offset + i] = fmt.aprintf("%g", src.float64s[i], allocator = allocator)
				}
			}
		case .Bool:
			for i in 0 ..< row_count {
				if src.null_mask[i] {
					dst.strings[offset + i] = ""
				} else {
					dst.strings[offset + i] = strings.clone(
						"true" if src.bools[i] else "false",
						allocator,
					)
				}
			}
		case .Unknown:
			return .Invalid_Column_Data
		}

	case .Unknown:
		return .Invalid_Column_Data
	}
	return .None
}
