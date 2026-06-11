package tests

import "core:fmt"
import "core:os"
import "core:testing"
import snout_core "../core"
import ingest "../ingest"

@(private = "file")
write_streaming_csv :: proc(t: ^testing.T, name, content: string) -> string {
	path := fmt.aprintf("tests/fixtures/.tmp_schema_%s.csv", name)
	err := os.write_entire_file(path, transmute([]byte)content)
	testing.expect(t, err == nil, "could not write temp fixture")
	return path
}

@(private = "file")
remove_streaming_csv :: proc(path: string) {
	os.remove(path)
	delete(path)
}

@(private = "file")
expect_schema_matches_string_reader :: proc(
	t: ^testing.T,
	path, content: string,
) {
	schema, schema_err := ingest.inspect_csv_file(path, "parity")
	testing.expect_value(t, schema_err, snout_core.Error.None)
	if schema_err != .None {
		return
	}
	defer ingest.free_csv_file_schema(&schema)

	table, table_err := ingest.read_csv_string(content, "parity")
	testing.expect_value(t, table_err, snout_core.Error.None)
	if table_err != .None {
		return
	}
	defer snout_core.free_table(&table)

	testing.expect_value(t, schema.row_count, table.row_count)
	testing.expect_value(t, len(schema.columns), len(table.columns))
	for column, index in table.columns {
		testing.expect_value(t, schema.columns[index].name, column.name)
		testing.expect_value(t, schema.columns[index].kind, column.kind)
		testing.expect_value(t, schema.columns[index].nullable, column.nullable)
	}
}

@(test)
schema_exact_row_count_and_header :: proc(t: ^testing.T) {
	content := "alpha,beta,gamma\n1,x,true\n2,y,false\n3,z,true\n"
	path := write_streaming_csv(t, "rows", content)
	defer remove_streaming_csv(path)

	schema, err := ingest.inspect_csv_file(path, "rows")
	testing.expect_value(t, err, snout_core.Error.None)
	defer ingest.free_csv_file_schema(&schema)

	testing.expect_value(t, schema.row_count, 3)
	testing.expect_value(t, len(schema.columns), 3)
	testing.expect_value(t, schema.columns[0].name, "alpha")
	testing.expect_value(t, schema.columns[1].name, "beta")
	testing.expect_value(t, schema.columns[2].name, "gamma")
	testing.expect_value(t, schema.table_name, "rows")
}

@(test)
schema_type_inference_per_kind :: proc(t: ^testing.T) {
	content := "ts,name,count,ratio,flag\n" +
		"2026-06-08T10:00:00Z,pig,10,1.5,true\n" +
		"2026-06-08T10:00:01Z,boar,20,2.5,false\n"
	path := write_streaming_csv(t, "kinds", content)
	defer remove_streaming_csv(path)

	schema, err := ingest.inspect_csv_file(path, "kinds")
	testing.expect_value(t, err, snout_core.Error.None)
	defer ingest.free_csv_file_schema(&schema)

	testing.expect_value(t, schema.columns[0].kind, snout_core.Column_Type.Timestamp)
	testing.expect_value(t, schema.columns[1].kind, snout_core.Column_Type.String)
	testing.expect_value(t, schema.columns[2].kind, snout_core.Column_Type.Int64)
	testing.expect_value(t, schema.columns[3].kind, snout_core.Column_Type.Float64)
	testing.expect_value(t, schema.columns[4].kind, snout_core.Column_Type.Bool)
}

@(test)
schema_all_null_column_is_string_nullable :: proc(t: ^testing.T) {
	content := "a,empty\n1,\n2,\n"
	path := write_streaming_csv(t, "all_null", content)
	defer remove_streaming_csv(path)

	schema, err := ingest.inspect_csv_file(path, "all_null")
	testing.expect_value(t, err, snout_core.Error.None)
	defer ingest.free_csv_file_schema(&schema)

	testing.expect_value(t, schema.columns[1].kind, snout_core.Column_Type.String)
	testing.expect_value(t, schema.columns[1].nullable, true)
	testing.expect_value(t, schema.columns[0].nullable, false)
}

@(test)
schema_int_promotes_to_float :: proc(t: ^testing.T) {
	content := "value\n1\n2\n3.5\n"
	path := write_streaming_csv(t, "promote_float", content)
	defer remove_streaming_csv(path)

	schema, err := ingest.inspect_csv_file(path, "promote_float")
	testing.expect_value(t, err, snout_core.Error.None)
	defer ingest.free_csv_file_schema(&schema)

	testing.expect_value(t, schema.columns[0].kind, snout_core.Column_Type.Float64)
}

@(test)
schema_late_promotion_on_final_row :: proc(t: ^testing.T) {
	content := "value\n1\n2\n3\nnot-a-number"
	path := write_streaming_csv(t, "late_promotion", content)
	defer remove_streaming_csv(path)

	schema, err := ingest.inspect_csv_file(path, "late_promotion")
	testing.expect_value(t, err, snout_core.Error.None)
	defer ingest.free_csv_file_schema(&schema)

	testing.expect_value(t, schema.columns[0].kind, snout_core.Column_Type.String)
}

@(test)
schema_nullability_from_any_row :: proc(t: ^testing.T) {
	content := "a,b\n1,x\n,y\n3,z\n"
	path := write_streaming_csv(t, "nullability", content)
	defer remove_streaming_csv(path)

	schema, err := ingest.inspect_csv_file(path, "nullability")
	testing.expect_value(t, err, snout_core.Error.None)
	defer ingest.free_csv_file_schema(&schema)

	testing.expect_value(t, schema.columns[0].nullable, true)
	testing.expect_value(t, schema.columns[0].kind, snout_core.Column_Type.Int64)
	testing.expect_value(t, schema.columns[1].nullable, false)
}

@(test)
schema_column_count_mismatch :: proc(t: ^testing.T) {
	content := "a,b\n1,2\n3\n"
	path := write_streaming_csv(t, "mismatch", content)
	defer remove_streaming_csv(path)

	_, err := ingest.inspect_csv_file(path, "mismatch")
	testing.expect_value(t, err, snout_core.Error.Column_Count_Mismatch)
}

@(test)
schema_empty_input :: proc(t: ^testing.T) {
	path := write_streaming_csv(t, "empty", "")
	defer remove_streaming_csv(path)

	_, err := ingest.inspect_csv_file(path, "empty")
	testing.expect_value(t, err, snout_core.Error.Empty_Input)
}

@(test)
schema_header_only :: proc(t: ^testing.T) {
	path := write_streaming_csv(t, "header_only", "a,b\n")
	defer remove_streaming_csv(path)

	schema, err := ingest.inspect_csv_file(path, "header_only")
	testing.expect_value(t, err, snout_core.Error.None)
	defer ingest.free_csv_file_schema(&schema)

	testing.expect_value(t, schema.row_count, 0)
	testing.expect_value(t, schema.columns[0].kind, snout_core.Column_Type.String)
	testing.expect_value(t, schema.columns[1].kind, snout_core.Column_Type.String)
}

@(test)
schema_parity_with_string_reader_simple :: proc(t: ^testing.T) {
	content := "timestamp,endpoint,status,latency_ms,bytes\n" +
		"2026-06-08T10:00:00Z,/login,200,42,1200\n" +
		"2026-06-08T10:00:01Z,/login,200,,1180\n" +
		"2026-06-08T10:00:02Z,\"/check,out\",500,91,900\n"
	path := write_streaming_csv(t, "parity_simple", content)
	defer remove_streaming_csv(path)
	expect_schema_matches_string_reader(t, path, content)
}

@(test)
schema_parity_with_fixture_500 :: proc(t: ^testing.T) {
	fixture_path :: "tests/fixtures/complex_metrics_500.csv"
	data, read_err := os.read_entire_file(fixture_path, context.allocator)
	testing.expect(t, read_err == nil, "fixture must be readable")
	if read_err != nil {
		return
	}
	defer delete(data)
	expect_schema_matches_string_reader(t, fixture_path, string(data))
}

@(test)
schema_ownership_survives_scanner_close :: proc(t: ^testing.T) {
	content := "name,value\npig,1\n"
	path := write_streaming_csv(t, "ownership", content)
	defer remove_streaming_csv(path)

	schema, err := ingest.inspect_csv_file(path, "ownership")
	testing.expect_value(t, err, snout_core.Error.None)

	os.remove(path)
	testing.expect_value(t, schema.columns[0].name, "name")
	testing.expect_value(t, schema.columns[1].name, "value")
	testing.expect_value(t, schema.table_name, "ownership")
	ingest.free_csv_file_schema(&schema)

	rewrite_err := os.write_entire_file(path, transmute([]byte)content)
	testing.expect(t, rewrite_err == nil)
}

@(private = "file")
expect_tables_equal :: proc(t: ^testing.T, actual, expected: ^snout_core.Table) {
	testing.expect_value(t, actual.row_count, expected.row_count)
	testing.expect_value(t, len(actual.columns), len(expected.columns))
	if len(actual.columns) != len(expected.columns) {
		return
	}
	for &expected_column, index in expected.columns {
		actual_column := &actual.columns[index]
		testing.expect_value(t, actual_column.name, expected_column.name)
		testing.expect_value(t, actual_column.kind, expected_column.kind)
		testing.expect_value(t, actual_column.nullable, expected_column.nullable)
		for row in 0 ..< expected.row_count {
			testing.expect_value(
				t,
				actual_column.null_mask[row],
				expected_column.null_mask[row],
			)
		}
		#partial switch expected_column.kind {
		case .String, .Timestamp:
			for row in 0 ..< expected.row_count {
				testing.expect_value(
					t,
					actual_column.strings[row],
					expected_column.strings[row],
				)
			}
		case .Int64:
			for row in 0 ..< expected.row_count {
				testing.expect_value(
					t,
					actual_column.int64s[row],
					expected_column.int64s[row],
				)
			}
		case .Float64:
			for row in 0 ..< expected.row_count {
				testing.expect_value(
					t,
					actual_column.float64s[row],
					expected_column.float64s[row],
				)
			}
		case .Bool:
			for row in 0 ..< expected.row_count {
				testing.expect_value(
					t,
					actual_column.bools[row],
					expected_column.bools[row],
				)
			}
		}
	}
}

@(test)
streaming_table_matches_string_reader_simple :: proc(t: ^testing.T) {
	fixture_path :: "tests/fixtures/simple_metrics.csv"
	data, read_err := os.read_entire_file(fixture_path, context.allocator)
	testing.expect(t, read_err == nil)
	if read_err != nil {
		return
	}
	defer delete(data)

	streamed, stream_err := ingest.read_csv_table(fixture_path, "simple_metrics")
	testing.expect_value(t, stream_err, snout_core.Error.None)
	defer snout_core.free_table(&streamed)

	in_memory, memory_err := ingest.read_csv_string(string(data), "simple_metrics")
	testing.expect_value(t, memory_err, snout_core.Error.None)
	defer snout_core.free_table(&in_memory)

	expect_tables_equal(t, &streamed, &in_memory)
}

@(test)
streaming_table_matches_string_reader_complex :: proc(t: ^testing.T) {
	fixture_path :: "tests/fixtures/complex_metrics.csv"
	data, read_err := os.read_entire_file(fixture_path, context.allocator)
	testing.expect(t, read_err == nil)
	if read_err != nil {
		return
	}
	defer delete(data)

	streamed, stream_err := ingest.read_csv_table(fixture_path, "complex_metrics")
	testing.expect_value(t, stream_err, snout_core.Error.None)
	defer snout_core.free_table(&streamed)

	in_memory, memory_err := ingest.read_csv_string(string(data), "complex_metrics")
	testing.expect_value(t, memory_err, snout_core.Error.None)
	defer snout_core.free_table(&in_memory)

	expect_tables_equal(t, &streamed, &in_memory)
}

@(test)
streaming_table_matches_string_reader_500 :: proc(t: ^testing.T) {
	fixture_path :: "tests/fixtures/complex_metrics_500.csv"
	data, read_err := os.read_entire_file(fixture_path, context.allocator)
	testing.expect(t, read_err == nil)
	if read_err != nil {
		return
	}
	defer delete(data)

	streamed, stream_err := ingest.read_csv_table(fixture_path, "complex_metrics_500")
	testing.expect_value(t, stream_err, snout_core.Error.None)
	defer snout_core.free_table(&streamed)

	in_memory, memory_err := ingest.read_csv_string(string(data), "complex_metrics_500")
	testing.expect_value(t, memory_err, snout_core.Error.None)
	defer snout_core.free_table(&in_memory)

	expect_tables_equal(t, &streamed, &in_memory)
}

@(test)
streaming_table_quotes_and_commas :: proc(t: ^testing.T) {
	content := "name,message\npig,\"hello, world\"\nboar,\"he said \"\"snout\"\"\"\n"
	path := write_streaming_csv(t, "quotes", content)
	defer remove_streaming_csv(path)

	table, err := ingest.read_csv_table(path, "quotes")
	testing.expect_value(t, err, snout_core.Error.None)
	defer snout_core.free_table(&table)

	message, found := snout_core.get_column(&table, "message")
	testing.expect(t, found)
	if found {
		testing.expect_value(t, message.strings[0], "hello, world")
		testing.expect_value(t, message.strings[1], "he said \"snout\"")
	}
}

@(test)
streaming_table_null_masks :: proc(t: ^testing.T) {
	content := "name,latency\na,10\nb,\nc,30\n"
	path := write_streaming_csv(t, "nulls", content)
	defer remove_streaming_csv(path)

	table, err := ingest.read_csv_table(path, "nulls")
	testing.expect_value(t, err, snout_core.Error.None)
	defer snout_core.free_table(&table)

	latency, found := snout_core.get_column(&table, "latency")
	testing.expect(t, found)
	if found {
		testing.expect(t, latency.nullable)
		testing.expect_value(t, latency.null_mask[0], false)
		testing.expect_value(t, latency.null_mask[1], true)
		testing.expect_value(t, latency.null_mask[2], false)
		testing.expect_value(t, latency.int64s[0], i64(10))
		testing.expect_value(t, latency.int64s[2], i64(30))
	}
}

@(test)
streaming_table_row_added_between_passes :: proc(t: ^testing.T) {
	content := "a,b\n1,2\n"
	path := write_streaming_csv(t, "mutate_add", content)
	defer remove_streaming_csv(path)

	schema, schema_err := ingest.inspect_csv_file(path, "mutate_add")
	testing.expect_value(t, schema_err, snout_core.Error.None)
	defer ingest.free_csv_file_schema(&schema)

	grown := "a,b\n1,2\n3,4\n"
	rewrite_err := os.write_entire_file(path, transmute([]byte)grown)
	testing.expect(t, rewrite_err == nil)

	_, err := ingest.populate_csv_table(path, &schema, context.allocator)
	testing.expect_value(t, err, snout_core.Error.Input_Changed_During_Read)
}

@(test)
streaming_table_header_changed_between_passes :: proc(t: ^testing.T) {
	content := "a,b\n1,2\n"
	path := write_streaming_csv(t, "mutate_header", content)
	defer remove_streaming_csv(path)

	schema, schema_err := ingest.inspect_csv_file(path, "mutate_header")
	testing.expect_value(t, schema_err, snout_core.Error.None)
	defer ingest.free_csv_file_schema(&schema)

	changed := "a,c\n1,2\n"
	rewrite_err := os.write_entire_file(path, transmute([]byte)changed)
	testing.expect(t, rewrite_err == nil)

	_, err := ingest.populate_csv_table(path, &schema, context.allocator)
	testing.expect_value(t, err, snout_core.Error.Input_Changed_During_Read)
}

@(test)
streaming_table_incompatible_value_between_passes :: proc(t: ^testing.T) {
	content := "a,b\n1,2\n"
	path := write_streaming_csv(t, "mutate_value", content)
	defer remove_streaming_csv(path)

	schema, schema_err := ingest.inspect_csv_file(path, "mutate_value")
	testing.expect_value(t, schema_err, snout_core.Error.None)
	defer ingest.free_csv_file_schema(&schema)

	changed := "a,b\n1,oops\n"
	rewrite_err := os.write_entire_file(path, transmute([]byte)changed)
	testing.expect(t, rewrite_err == nil)

	_, err := ingest.populate_csv_table(path, &schema, context.allocator)
	testing.expect_value(t, err, snout_core.Error.Input_Changed_During_Read)
}

@(test)
streaming_table_row_removed_between_passes :: proc(t: ^testing.T) {
	content := "a,b\n1,2\n3,4\n"
	path := write_streaming_csv(t, "mutate_remove", content)
	defer remove_streaming_csv(path)

	schema, schema_err := ingest.inspect_csv_file(path, "mutate_remove")
	testing.expect_value(t, schema_err, snout_core.Error.None)
	defer ingest.free_csv_file_schema(&schema)

	shrunk := "a,b\n1,2\n"
	rewrite_err := os.write_entire_file(path, transmute([]byte)shrunk)
	testing.expect(t, rewrite_err == nil)

	_, err := ingest.populate_csv_table(path, &schema, context.allocator)
	testing.expect_value(t, err, snout_core.Error.Input_Changed_During_Read)
}
