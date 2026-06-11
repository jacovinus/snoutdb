package tests

import "core:testing"
import snout_core "../core"
import aggregate "../exec"
import ingest "../ingest"
import storage "../storage"

SIMPLE_JSONL_PATH :: "tests/fixtures/simple_events.jsonl"
COMPLEX_JSONL_PATH :: "tests/fixtures/complex_calls.jsonl"

@(test)
simple_jsonl_loads :: proc(t: ^testing.T) {
	table, err := ingest.read_jsonl_table(SIMPLE_JSONL_PATH, "simple_events")
	testing.expect_value(t, err, snout_core.Error.None)
	if err != .None {
		return
	}
	defer snout_core.free_table(&table)

	testing.expect_value(t, table.row_count, 3)
	testing.expect_value(t, len(table.columns), 5)

	expected := [?]struct {
		name: string,
		kind: snout_core.Column_Type,
	}{
		{"timestamp", .Timestamp},
		{"endpoint", .String},
		{"status", .Int64},
		{"latency_ms", .Int64},
		{"cached", .Bool},
	}
	for item, index in expected {
		testing.expect_value(t, table.columns[index].name, item.name)
		testing.expect_value(t, table.columns[index].kind, item.kind)
	}
}

@(test)
json_integer_and_float_promote_to_float :: proc(t: ^testing.T) {
	input := "{\"value\":10}\n{\"value\":12.5}\n"
	table, err := ingest.read_jsonl_string(input, "promotion")
	testing.expect_value(t, err, snout_core.Error.None)
	if err != .None {
		return
	}
	defer snout_core.free_table(&table)

	value, found := snout_core.get_column(&table, "value")
	testing.expect(t, found)
	if found {
		testing.expect_value(t, value.kind, snout_core.Column_Type.Float64)
		testing.expect_value(t, value.float64s[0], 10.0)
		testing.expect_value(t, value.float64s[1], 12.5)
	}
}

@(test)
json_missing_and_null_fields_are_nullable :: proc(t: ^testing.T) {
	input := "{\"name\":\"a\",\"value\":10}\n{\"name\":\"b\"}\n{\"name\":\"c\",\"value\":null}\n{\"name\":\"d\",\"value\":30}\n"
	table, err := ingest.read_jsonl_string(input, "nullable")
	testing.expect_value(t, err, snout_core.Error.None)
	if err != .None {
		return
	}
	defer snout_core.free_table(&table)

	value, found := snout_core.get_column(&table, "value")
	testing.expect(t, found)
	if found {
		testing.expect(t, value.nullable)
		testing.expect(t, value.null_mask[1])
		testing.expect(t, value.null_mask[2])
		testing.expect(t, !value.null_mask[0])
		testing.expect(t, !value.null_mask[3])
	}
}

@(test)
json_empty_string_is_not_null :: proc(t: ^testing.T) {
	input := "{\"note\":\"\"}\n{\"note\":null}\n"
	table, err := ingest.read_jsonl_string(input, "empty_string")
	testing.expect_value(t, err, snout_core.Error.None)
	if err != .None {
		return
	}
	defer snout_core.free_table(&table)

	note, found := snout_core.get_column(&table, "note")
	testing.expect(t, found)
	if found {
		testing.expect(t, !note.null_mask[0])
		testing.expect(t, note.null_mask[1])
		testing.expect_value(t, note.strings[0], "")
	}
}

@(test)
json_late_fields_preserve_first_seen_order :: proc(t: ^testing.T) {
	input := "{\"a\":1,\"b\":2}\n{\"b\":3,\"c\":4}\n"
	table, err := ingest.read_jsonl_string(input, "order")
	testing.expect_value(t, err, snout_core.Error.None)
	if err != .None {
		return
	}
	defer snout_core.free_table(&table)

	testing.expect_value(t, table.columns[0].name, "a")
	testing.expect_value(t, table.columns[1].name, "b")
	testing.expect_value(t, table.columns[2].name, "c")
	testing.expect(t, table.columns[0].null_mask[1])
	testing.expect(t, table.columns[2].null_mask[0])
}

@(test)
json_string_escapes_are_decoded :: proc(t: ^testing.T) {
	input := "{\"text\":\"quote \\\" and slash \\\\ and snowman \\u2603\"}\n"
	table, err := ingest.read_jsonl_string(input, "escapes")
	testing.expect_value(t, err, snout_core.Error.None)
	if err != .None {
		return
	}
	defer snout_core.free_table(&table)

	text, found := snout_core.get_column(&table, "text")
	testing.expect(t, found)
	if found {
		testing.expect_value(t, text.strings[0], "quote \" and slash \\ and snowman \u2603")
	}
}

@(test)
json_scientific_notation_is_float :: proc(t: ^testing.T) {
	input := "{\"value\":1.5e2}\n{\"value\":-2.5e-1}\n"
	table, err := ingest.read_jsonl_string(input, "scientific")
	testing.expect_value(t, err, snout_core.Error.None)
	if err != .None {
		return
	}
	defer snout_core.free_table(&table)

	value, found := snout_core.get_column(&table, "value")
	testing.expect(t, found)
	if found {
		testing.expect_value(t, value.float64s[0], 150.0)
		testing.expect_value(t, value.float64s[1], -0.25)
	}
}

@(test)
json_incompatible_types_are_rejected :: proc(t: ^testing.T) {
	input := "{\"value\":true}\n{\"value\":10}\n"
	_, err := ingest.read_jsonl_string(input, "incompatible")
	testing.expect_value(t, err, snout_core.Error.Incompatible_JSON_Types)
}

@(test)
json_numbers_promote_to_string_when_mixed_with_text :: proc(t: ^testing.T) {
	input := "{\"value\":10}\n{\"value\":\"ready\"}\n"
	table, err := ingest.read_jsonl_string(input, "string_promotion")
	testing.expect_value(t, err, snout_core.Error.None)
	if err != .None {
		return
	}
	defer snout_core.free_table(&table)

	value, found := snout_core.get_column(&table, "value")
	testing.expect(t, found)
	if found {
		testing.expect_value(t, value.kind, snout_core.Column_Type.String)
		testing.expect_value(t, value.strings[0], "10")
		testing.expect_value(t, value.strings[1], "ready")
	}
}

@(test)
json_nested_values_are_rejected :: proc(t: ^testing.T) {
	_, object_err := ingest.read_jsonl_string(
		"{\"metadata\":{\"region\":\"eu-west\"}}\n",
		"nested_object",
	)
	testing.expect_value(t, object_err, snout_core.Error.Unsupported_JSON_Value)

	_, array_err := ingest.read_jsonl_string(
		"{\"tags\":[\"voice\",\"production\"]}\n",
		"nested_array",
	)
	testing.expect_value(t, array_err, snout_core.Error.Unsupported_JSON_Value)
}

@(test)
json_top_level_scalars_are_rejected :: proc(t: ^testing.T) {
	_, array_err := ingest.read_jsonl_string("[1,2,3]\n", "array")
	testing.expect_value(t, array_err, snout_core.Error.Expected_JSON_Object)

	_, scalar_err := ingest.read_jsonl_string("\"value\"\n", "scalar")
	testing.expect_value(t, scalar_err, snout_core.Error.Expected_JSON_Object)
}

@(test)
json_duplicate_keys_are_rejected :: proc(t: ^testing.T) {
	_, err := ingest.read_jsonl_string(
		"{\"status\":200,\"status\":500}\n",
		"duplicate",
	)
	testing.expect_value(t, err, snout_core.Error.Duplicate_JSON_Key)
}

@(test)
json_malformed_line_reports_line_number :: proc(t: ^testing.T) {
	input := "{\"value\":1}\n{\"value\":}\n{\"value\":3}\n"
	_, detail := ingest.read_jsonl_string_detailed(input, "malformed")
	testing.expect_value(t, detail.code, snout_core.Error.Malformed_JSON)
	testing.expect_value(t, detail.line, 2)
}

@(test)
json_empty_lines_and_crlf_are_supported :: proc(t: ^testing.T) {
	input := "\r\n{\"value\":1}\r\n   \r\n{\"value\":2}\r\n"
	table, err := ingest.read_jsonl_string(input, "crlf")
	testing.expect_value(t, err, snout_core.Error.None)
	if err != .None {
		return
	}
	defer snout_core.free_table(&table)
	testing.expect_value(t, table.row_count, 2)
}

@(test)
json_numbers_out_of_range_are_rejected :: proc(t: ^testing.T) {
	_, integer_err := ingest.read_jsonl_string(
		"{\"value\":9223372036854775808}\n",
		"integer_overflow",
	)
	testing.expect_value(t, integer_err, snout_core.Error.Number_Out_Of_Range)

	_, float_err := ingest.read_jsonl_string("{\"value\":1e9999}\n", "float_overflow")
	testing.expect_value(t, float_err, snout_core.Error.Number_Out_Of_Range)
}

@(test)
json_line_size_limit_is_enforced :: proc(t: ^testing.T) {
	line := "                                 "
	_, detail := ingest.read_jsonl_string_with_limit(line, "large", 32)
	testing.expect_value(t, detail.code, snout_core.Error.Line_Too_Large)
	testing.expect_value(t, detail.line, 1)
}

@(test)
complex_jsonl_round_trips_through_snout :: proc(t: ^testing.T) {
	source, err := ingest.read_jsonl_table(COMPLEX_JSONL_PATH, "complex_calls")
	testing.expect_value(t, err, snout_core.Error.None)
	if err != .None {
		return
	}
	defer snout_core.free_table(&source)

	testing.expect_value(t, source.row_count, 100)
	jitter, found := snout_core.get_column(&source, "jitter_ms")
	testing.expect(t, found)
	if found {
		testing.expect(t, jitter.null_mask[9])
		testing.expect(t, jitter.null_mask[10])
	}

	data, storage_err := storage.serialize_table(&source)
	testing.expect_value(t, storage_err, snout_core.Error.None)
	if storage_err != .None {
		return
	}
	defer delete(data)

	loaded, read_err := storage.deserialize_table(data)
	testing.expect_value(t, read_err, snout_core.Error.None)
	if read_err != .None {
		return
	}
	defer snout_core.free_table(&loaded)

	stat_columns := [?]string{"mos", "jitter_ms", "packet_loss_pct"}
	for column_name in stat_columns {
		before, before_err := aggregate.numeric_stats(&source, column_name)
		after, after_err := aggregate.numeric_stats(&loaded, column_name)
		testing.expect_value(t, before_err, snout_core.Error.None)
		testing.expect_value(t, after_err, snout_core.Error.None)
		testing.expect_value(t, after.count, before.count)
		testing.expect_value(t, after.null_count, before.null_count)
		testing.expect_value(t, after.sum, before.sum)
		testing.expect_value(t, after.min, before.min)
		testing.expect_value(t, after.max, before.max)
	}

	note, note_found := snout_core.get_column(&loaded, "note")
	testing.expect(t, note_found)
	if note_found {
		testing.expect(t, note.null_mask[0])
		testing.expect(t, !note.null_mask[11])
		testing.expect_value(t, note.strings[11], "")
		testing.expect_value(t, note.strings[12], "caller said \"hello\"")
	}
}
