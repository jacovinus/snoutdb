package tests

import "core:fmt"
import "core:os"
import "core:testing"
import snout_core "../core"
import ingest "../ingest"

@(private = "file")
write_streaming_jsonl :: proc(t: ^testing.T, name, content: string) -> string {
	path := fmt.aprintf("tests/fixtures/.tmp_jsonl_streaming_%s.jsonl", name)
	err := os.write_entire_file(path, transmute([]byte)content)
	testing.expect(t, err == nil, "could not write temp jsonl streaming fixture")
	return path
}

@(private = "file")
remove_streaming_jsonl :: proc(path: string) {
	os.remove(path)
	delete(path)
}

// --- Schema inference parity tests ------------------------------------------

// expect_jsonl_schema_matches_string_reader checks that inspect_jsonl_file
// produces the same schema (column names, kinds, nullability, row count) as
// read_jsonl_string on the same content.
@(private = "file")
expect_jsonl_schema_matches_string_reader :: proc(
	t: ^testing.T,
	path, content, label: string,
) {
	schema, schema_err := ingest.inspect_jsonl_file(path, label)
	testing.expect_value(t, schema_err, snout_core.Error.None)
	if schema_err != .None {
		return
	}
	defer ingest.free_jsonl_file_schema(&schema)

	table, table_err := ingest.read_jsonl_string(content, label)
	testing.expect_value(t, table_err, snout_core.Error.None)
	if table_err != .None {
		return
	}
	defer snout_core.free_table(&table)

	testing.expect_value(t, schema.row_count, table.row_count)
	testing.expect_value(t, len(schema.columns), len(table.columns))
	for col, index in table.columns {
		testing.expect_value(t, schema.columns[index].name, col.name)
		testing.expect_value(t, schema.columns[index].kind, col.kind)
		testing.expect_value(t, schema.columns[index].nullable, col.nullable)
	}
}

@(test)
jsonl_schema_row_count_and_column_names :: proc(t: ^testing.T) {
	content := "{\"a\":1,\"b\":\"x\"}\n{\"a\":2,\"b\":\"y\"}\n{\"a\":3,\"b\":\"z\"}\n"
	path := write_streaming_jsonl(t, "names", content)
	defer remove_streaming_jsonl(path)

	schema, err := ingest.inspect_jsonl_file(path, "names")
	testing.expect_value(t, err, snout_core.Error.None)
	defer ingest.free_jsonl_file_schema(&schema)
	if err != .None {
		return
	}

	testing.expect_value(t, schema.row_count, 3)
	testing.expect_value(t, len(schema.columns), 2)
	testing.expect_value(t, schema.columns[0].name, "a")
	testing.expect_value(t, schema.columns[1].name, "b")
	testing.expect_value(t, schema.table_name, "names")
}

@(test)
jsonl_schema_type_inference_all_kinds :: proc(t: ^testing.T) {
	content :=
		"{\"ts\":\"2026-06-08T10:00:00Z\",\"name\":\"pig\",\"count\":10,\"ratio\":1.5,\"flag\":true}\n"
	path := write_streaming_jsonl(t, "kinds", content)
	defer remove_streaming_jsonl(path)

	schema, err := ingest.inspect_jsonl_file(path, "kinds")
	testing.expect_value(t, err, snout_core.Error.None)
	defer ingest.free_jsonl_file_schema(&schema)
	if err != .None {
		return
	}

	testing.expect_value(t, schema.columns[0].kind, snout_core.Column_Type.Timestamp)
	testing.expect_value(t, schema.columns[1].kind, snout_core.Column_Type.String)
	testing.expect_value(t, schema.columns[2].kind, snout_core.Column_Type.Int64)
	testing.expect_value(t, schema.columns[3].kind, snout_core.Column_Type.Float64)
	testing.expect_value(t, schema.columns[4].kind, snout_core.Column_Type.Bool)
}

@(test)
jsonl_schema_int_float_promotion :: proc(t: ^testing.T) {
	// Int64 in row 1 promoted to Float64 in row 2 — late promotion.
	content := "{\"value\":10}\n{\"value\":12.5}\n"
	path := write_streaming_jsonl(t, "int_float", content)
	defer remove_streaming_jsonl(path)
	expect_jsonl_schema_matches_string_reader(t, path, content, "int_float")
}

@(test)
jsonl_schema_late_field_is_nullable :: proc(t: ^testing.T) {
	// Column "c" appears only in row 2 — must be nullable.
	content := "{\"a\":1,\"b\":2}\n{\"b\":3,\"c\":4}\n"
	path := write_streaming_jsonl(t, "late_field", content)
	defer remove_streaming_jsonl(path)
	expect_jsonl_schema_matches_string_reader(t, path, content, "late_field")
}

@(test)
jsonl_schema_null_value_makes_nullable :: proc(t: ^testing.T) {
	content := "{\"a\":1}\n{\"a\":null}\n"
	path := write_streaming_jsonl(t, "null_nullable", content)
	defer remove_streaming_jsonl(path)
	expect_jsonl_schema_matches_string_reader(t, path, content, "null_nullable")
}

@(test)
jsonl_schema_all_null_column_is_string :: proc(t: ^testing.T) {
	content := "{\"a\":null}\n{\"a\":null}\n"
	path := write_streaming_jsonl(t, "all_null", content)
	defer remove_streaming_jsonl(path)

	schema, err := ingest.inspect_jsonl_file(path, "all_null")
	testing.expect_value(t, err, snout_core.Error.None)
	defer ingest.free_jsonl_file_schema(&schema)
	if err != .None {
		return
	}

	testing.expect_value(t, schema.columns[0].kind, snout_core.Column_Type.String)
	testing.expect_value(t, schema.columns[0].nullable, true)
}

@(test)
jsonl_schema_missing_field_marks_nullable :: proc(t: ^testing.T) {
	// "b" is missing from row 2.
	content := "{\"a\":1,\"b\":2}\n{\"a\":3}\n"
	path := write_streaming_jsonl(t, "missing_field", content)
	defer remove_streaming_jsonl(path)
	expect_jsonl_schema_matches_string_reader(t, path, content, "missing_field")
}

@(test)
jsonl_schema_parity_with_simple_events :: proc(t: ^testing.T) {
	path := "tests/fixtures/simple_events.jsonl"
	data, ok := os.read_entire_file_from_path(path, context.allocator)
	if !testing.expect(t, ok == nil, "could not read fixture") {
		return
	}
	defer delete(data, context.allocator)
	expect_jsonl_schema_matches_string_reader(t, path, string(data), "simple_events")
}

@(test)
jsonl_schema_parity_with_complex_calls :: proc(t: ^testing.T) {
	path := "tests/fixtures/complex_calls.jsonl"
	data, read_err := os.read_entire_file_from_path(path, context.allocator)
	if !testing.expect(t, read_err == nil, "could not read complex_calls.jsonl") {
		return
	}
	defer delete(data, context.allocator)
	expect_jsonl_schema_matches_string_reader(t, path, string(data), "complex_calls")
}

@(test)
jsonl_schema_empty_file_returns_empty_input :: proc(t: ^testing.T) {
	path := write_streaming_jsonl(t, "empty_schema", "")
	defer remove_streaming_jsonl(path)

	_, err := ingest.inspect_jsonl_file(path, "empty")
	testing.expect_value(t, err, snout_core.Error.Empty_Input)
}

@(test)
jsonl_schema_missing_file :: proc(t: ^testing.T) {
	_, err := ingest.inspect_jsonl_file("/nonexistent/path.jsonl", "x")
	testing.expect_value(t, err, snout_core.Error.Io)
}

@(test)
jsonl_schema_column_indexes_map_populated :: proc(t: ^testing.T) {
	content := "{\"x\":1,\"y\":2,\"z\":3}\n"
	path := write_streaming_jsonl(t, "col_idx", content)
	defer remove_streaming_jsonl(path)

	schema, err := ingest.inspect_jsonl_file(path, "col_idx")
	testing.expect_value(t, err, snout_core.Error.None)
	defer ingest.free_jsonl_file_schema(&schema)
	if err != .None {
		return
	}

	xi, x_found := schema.column_indexes["x"]
	yi, y_found := schema.column_indexes["y"]
	zi, z_found := schema.column_indexes["z"]
	testing.expect(t, x_found)
	testing.expect(t, y_found)
	testing.expect(t, z_found)
	testing.expect_value(t, xi, 0)
	testing.expect_value(t, yi, 1)
	testing.expect_value(t, zi, 2)
}

// --- Populate / table parity tests ------------------------------------------

// expect_jsonl_table_matches_string_reader checks that read_jsonl_table
// (streaming path) produces a table identical to read_jsonl_string for the
// same content.
@(private = "file")
expect_jsonl_table_matches_string_reader :: proc(
	t: ^testing.T,
	path, content, label: string,
) {
	streamed, stream_err := ingest.read_jsonl_table(path, label)
	testing.expect_value(t, stream_err, snout_core.Error.None)
	if stream_err != .None {
		return
	}
	defer snout_core.free_table(&streamed)

	reference, ref_err := ingest.read_jsonl_string(content, label)
	testing.expect_value(t, ref_err, snout_core.Error.None)
	if ref_err != .None {
		return
	}
	defer snout_core.free_table(&reference)

	testing.expect_value(t, streamed.row_count, reference.row_count)
	testing.expect_value(t, len(streamed.columns), len(reference.columns))
	for col, ci in reference.columns {
		sc := streamed.columns[ci]
		testing.expect_value(t, sc.name, col.name)
		testing.expect_value(t, sc.kind, col.kind)
		testing.expect_value(t, sc.nullable, col.nullable)
		for ri in 0 ..< reference.row_count {
			ref_null := col.null_mask != nil && col.null_mask[ri]
			s_null := sc.null_mask != nil && sc.null_mask[ri]
			testing.expect_value(t, s_null, ref_null)
			if ref_null {
				continue
			}
			switch col.kind {
			case .String, .Timestamp:
				testing.expect_value(t, sc.strings[ri], col.strings[ri])
			case .Int64:
				testing.expect_value(t, sc.int64s[ri], col.int64s[ri])
			case .Float64:
				testing.expect_value(t, sc.float64s[ri], col.float64s[ri])
			case .Bool:
				testing.expect_value(t, sc.bools[ri], col.bools[ri])
			case .Unknown:
			}
		}
	}
}

@(test)
jsonl_streaming_table_matches_string_simple_events :: proc(t: ^testing.T) {
	path := "tests/fixtures/simple_events.jsonl"
	data, read_err := os.read_entire_file_from_path(path, context.allocator)
	if !testing.expect(t, read_err == nil, "could not read simple_events.jsonl") {
		return
	}
	defer delete(data, context.allocator)
	expect_jsonl_table_matches_string_reader(t, path, string(data), "simple_events")
}

@(test)
jsonl_streaming_table_matches_string_complex_calls :: proc(t: ^testing.T) {
	path := "tests/fixtures/complex_calls.jsonl"
	data, read_err := os.read_entire_file_from_path(path, context.allocator)
	if !testing.expect(t, read_err == nil, "could not read complex_calls.jsonl") {
		return
	}
	defer delete(data, context.allocator)
	expect_jsonl_table_matches_string_reader(t, path, string(data), "complex_calls")
}

@(test)
jsonl_streaming_table_int_float_promotion_values :: proc(t: ^testing.T) {
	// Float column stores both int-promoted and float values correctly.
	content := "{\"value\":10}\n{\"value\":12.5}\n"
	path := write_streaming_jsonl(t, "pop_int_float", content)
	defer remove_streaming_jsonl(path)
	expect_jsonl_table_matches_string_reader(t, path, content, "pop_int_float")
}

@(test)
jsonl_streaming_table_null_masks_correct :: proc(t: ^testing.T) {
	content := "{\"a\":1,\"b\":2}\n{\"a\":3}\n{\"a\":5,\"b\":null}\n"
	path := write_streaming_jsonl(t, "pop_null_mask", content)
	defer remove_streaming_jsonl(path)
	expect_jsonl_table_matches_string_reader(t, path, content, "pop_null_mask")
}

@(test)
jsonl_streaming_table_string_values_correct :: proc(t: ^testing.T) {
	content := "{\"note\":\"hello\"}\n{\"note\":\"world\"}\n"
	path := write_streaming_jsonl(t, "pop_strings", content)
	defer remove_streaming_jsonl(path)
	expect_jsonl_table_matches_string_reader(t, path, content, "pop_strings")
}

@(test)
jsonl_streaming_table_row_added_returns_error :: proc(t: ^testing.T) {
	// Pass 1 sees 2 rows; a third row is appended before pass 2.
	path := write_streaming_jsonl(t, "pop_row_added", "{\"a\":1}\n{\"a\":2}\n")
	defer remove_streaming_jsonl(path)

	schema, schema_err := ingest.inspect_jsonl_file(path, "pop_row_added")
	testing.expect_value(t, schema_err, snout_core.Error.None)
	if schema_err != .None {
		return
	}
	defer ingest.free_jsonl_file_schema(&schema)

	// Append a row between passes.
	f, f_err := os.open(path, os.O_WRONLY | os.O_APPEND)
	if !testing.expect(t, f_err == nil, "could not open file for append") {
		return
	}
	os.write_string(f, "{\"a\":3}\n")
	os.close(f)

	_, pop_err := ingest.populate_jsonl_table(path, &schema, context.allocator)
	testing.expect_value(t, pop_err, snout_core.Error.Input_Changed_During_Read)
}

@(test)
jsonl_streaming_table_row_removed_returns_error :: proc(t: ^testing.T) {
	// Pass 1 sees 3 rows; file is truncated to 2 rows before pass 2.
	original := "{\"a\":1}\n{\"a\":2}\n{\"a\":3}\n"
	path := write_streaming_jsonl(t, "pop_row_removed", original)
	defer remove_streaming_jsonl(path)

	schema, schema_err := ingest.inspect_jsonl_file(path, "pop_row_removed")
	testing.expect_value(t, schema_err, snout_core.Error.None)
	if schema_err != .None {
		return
	}
	defer ingest.free_jsonl_file_schema(&schema)

	truncated := "{\"a\":1}\n{\"a\":2}\n"
	_ = os.write_entire_file(path, transmute([]byte)truncated)

	_, pop_err := ingest.populate_jsonl_table(path, &schema, context.allocator)
	testing.expect_value(t, pop_err, snout_core.Error.Input_Changed_During_Read)
}
