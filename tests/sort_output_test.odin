package tests

import "core:strings"
import "core:testing"
import "core:io"
import snout_core "../core"
import ingest "../ingest"
import result_output "../output"
import query "../query"

@(test)
aggregate_sort_descends_with_key_tie_breaker :: proc(t: ^testing.T) {
	input := "{\"region\":\"z\",\"value\":10}\n" +
	         "{\"region\":\"a\",\"value\":10}\n" +
	         "{\"region\":\"m\",\"value\":2}\n"
	table, err := ingest.read_jsonl_string(input, "sort")
	testing.expect_value(t, err, snout_core.Error.None)
	if err != .None {
		return
	}
	defer snout_core.free_table(&table)

	result := execute_test_group(t, &table, []string{"region"}, []query.Aggregate_Spec{
		{kind = .Avg, column_name = "value"},
	})
	if result.groups == nil {
		return
	}
	defer query.free_group_result_set(&result)

	term, resolve_err := query.resolve_sort_target(&result, "avg=value")
	testing.expect_value(t, resolve_err, snout_core.Error.None)
	term.direction = .Descending
	sort_err := query.sort_group_results(&result, []query.Sort_Term{term})
	testing.expect_value(t, sort_err, snout_core.Error.None)

	testing.expect_value(t, result.groups[0].keys[0].string_value, "a")
	testing.expect_value(t, result.groups[1].keys[0].string_value, "z")
	testing.expect_value(t, result.groups[2].keys[0].string_value, "m")
}

@(test)
multiple_sort_terms_use_left_to_right_precedence :: proc(t: ^testing.T) {
	input := "{\"region\":\"b\",\"carrier\":\"x\",\"value\":5}\n" +
	         "{\"region\":\"a\",\"carrier\":\"x\",\"value\":5}\n" +
	         "{\"region\":\"c\",\"carrier\":\"x\",\"value\":8}\n" +
	         "{\"region\":\"c\",\"carrier\":\"x\",\"value\":8}\n"
	table, err := ingest.read_jsonl_string(input, "multi_sort")
	testing.expect_value(t, err, snout_core.Error.None)
	if err != .None {
		return
	}
	defer snout_core.free_table(&table)

	result := execute_test_group(
		t,
		&table,
		[]string{"region", "carrier"},
		[]query.Aggregate_Spec{
			{kind = .Avg, column_name = "value"},
			{kind = .Count, column_name = "*"},
		},
	)
	if result.groups == nil {
		return
	}
	defer query.free_group_result_set(&result)

	avg_term, _ := query.resolve_sort_target(&result, "avg=value")
	avg_term.direction = .Descending
	count_term, _ := query.resolve_sort_target(&result, "count=rows")
	count_term.direction = .Descending
	terms := [?]query.Sort_Term{avg_term, count_term}
	sort_err := query.sort_group_results(&result, terms[:])
	testing.expect_value(t, sort_err, snout_core.Error.None)

	testing.expect_value(t, result.groups[0].keys[0].string_value, "c")
	testing.expect_value(t, result.groups[0].values[1].int_value, i64(2))
	testing.expect_value(t, result.groups[1].keys[0].string_value, "a")
	testing.expect_value(t, result.groups[2].keys[0].string_value, "b")
}

@(test)
null_aggregate_sort_follows_direction :: proc(t: ^testing.T) {
	input := "{\"key\":\"null\",\"value\":null}\n" +
	         "{\"key\":\"low\",\"value\":1}\n" +
	         "{\"key\":\"high\",\"value\":9}\n"
	table, err := ingest.read_jsonl_string(input, "null_sort")
	testing.expect_value(t, err, snout_core.Error.None)
	if err != .None {
		return
	}
	defer snout_core.free_table(&table)

	result := execute_test_group(t, &table, []string{"key"}, []query.Aggregate_Spec{
		{kind = .Avg, column_name = "value"},
	})
	if result.groups == nil {
		return
	}
	defer query.free_group_result_set(&result)

	term, _ := query.resolve_sort_target(&result, "avg=value")
	term.direction = .Ascending
	_ = query.sort_group_results(&result, []query.Sort_Term{term})
	testing.expect_value(t, result.groups[0].keys[0].string_value, "null")

	term.direction = .Descending
	_ = query.sort_group_results(&result, []query.Sort_Term{term})
	testing.expect_value(t, result.groups[0].keys[0].string_value, "high")
	testing.expect_value(t, result.groups[2].keys[0].string_value, "null")
}

@(test)
sort_validation_and_limit_parsing_are_specific :: proc(t: ^testing.T) {
	result := query.Group_Result_Set{
		group_columns = []string{"region"},
		aggregates = []query.Aggregate_Spec{{kind = .Avg, column_name = "mos"}},
	}
	_, missing_err := query.resolve_sort_target(&result, "max=mos")
	testing.expect_value(t, missing_err, snout_core.Error.Sort_Target_Not_Found)

	_, direction_ok := query.parse_sort_direction("down")
	testing.expect(t, !direction_ok)

	duplicate := [?]query.Sort_Term{
		{target_kind = .Group_Column, result_index = 0},
		{target_kind = .Group_Column, result_index = 0},
	}
	duplicate_err := query.sort_group_results(&result, duplicate[:])
	testing.expect_value(t, duplicate_err, snout_core.Error.Duplicate_Sort_Target)

	value, limit_err := query.parse_result_limit("10")
	testing.expect_value(t, limit_err, snout_core.Error.None)
	testing.expect_value(t, value, 10)
	_, negative_err := query.parse_result_limit("-1")
	testing.expect_value(t, negative_err, snout_core.Error.Invalid_Limit)
	_, decimal_err := query.parse_result_limit("1.5")
	testing.expect_value(t, decimal_err, snout_core.Error.Invalid_Limit)
	_, large_err := query.parse_result_limit("1000001")
	testing.expect_value(t, large_err, snout_core.Error.Limit_Too_Large)
}

@(test)
duplicate_result_columns_are_rejected :: proc(t: ^testing.T) {
	input := "{\"region\":\"eu\",\"value\":1}\n"
	table, err := ingest.read_jsonl_string(input, "duplicates")
	testing.expect_value(t, err, snout_core.Error.None)
	if err != .None {
		return
	}
	defer snout_core.free_table(&table)

	_, group_err := query.execute_group_query(
		&table,
		query.Group_Query{
			group_columns = []string{"region", "region"},
			aggregates = []query.Aggregate_Spec{{kind = .Count, column_name = "*"}},
		},
	)
	testing.expect_value(t, group_err, snout_core.Error.Duplicate_Result_Column)

	_, aggregate_err := query.execute_group_query(
		&table,
		query.Group_Query{
			group_columns = []string{"region"},
			aggregates = []query.Aggregate_Spec{
				{kind = .Avg, column_name = "value"},
				{kind = .Avg, column_name = "value"},
			},
		},
	)
	testing.expect_value(
		t,
		aggregate_err,
		snout_core.Error.Duplicate_Result_Column,
	)
}

@(test)
csv_output_escapes_and_distinguishes_null_from_empty :: proc(t: ^testing.T) {
	input := "{\"key\":null,\"value\":1}\n" +
	         "{\"key\":\"\",\"value\":2}\n" +
	         "{\"key\":\"a,b\",\"value\":3}\n" +
	         "{\"key\":\"say \\\"hi\\\"\",\"value\":4}\n"
	table, err := ingest.read_jsonl_string(input, "csv_output")
	testing.expect_value(t, err, snout_core.Error.None)
	if err != .None {
		return
	}
	defer snout_core.free_table(&table)

	result := execute_test_group(t, &table, []string{"key"}, []query.Aggregate_Spec{
		{kind = .Sum, column_name = "value"},
	})
	if result.groups == nil {
		return
	}
	defer query.free_group_result_set(&result)

	rendered, render_err := result_output.render_group_results(
		&result,
		result.groups,
		.CSV,
	)
	testing.expect_value(t, render_err, snout_core.Error.None)
	if render_err != .None {
		return
	}
	defer delete(rendered)

	expected :=
		"key,sum(value)\n" +
		",1\n" +
		"\"\",2\n" +
		"\"a,b\",3\n" +
		"\"say \"\"hi\"\"\",4\n"
	testing.expect_value(t, rendered, expected)
	testing.expect(t, !strings.contains(rendered, "groups:"))
}

@(test)
jsonl_output_preserves_types_and_nulls :: proc(t: ^testing.T) {
	input := "{\"key\":null,\"flag\":false,\"value\":null}\n" +
	         "{\"key\":\"eu\",\"flag\":true,\"value\":2.5}\n"
	table, err := ingest.read_jsonl_string(input, "json_output")
	testing.expect_value(t, err, snout_core.Error.None)
	if err != .None {
		return
	}
	defer snout_core.free_table(&table)

	result := execute_test_group(
		t,
		&table,
		[]string{"key", "flag"},
		[]query.Aggregate_Spec{{kind = .Avg, column_name = "value"}},
	)
	if result.groups == nil {
		return
	}
	defer query.free_group_result_set(&result)

	rendered, render_err := result_output.render_group_results(
		&result,
		result.groups,
		.JSONL,
	)
	testing.expect_value(t, render_err, snout_core.Error.None)
	if render_err != .None {
		return
	}
	defer delete(rendered)

	expected :=
		"{\"key\":null,\"flag\":false,\"avg(value)\":null}\n" +
		"{\"key\":\"eu\",\"flag\":true,\"avg(value)\":2.5}\n"
	testing.expect_value(t, rendered, expected)
	testing.expect(t, !strings.contains(rendered, "selected_rows:"))
}

@(test)
json_output_is_an_array_with_native_types :: proc(t: ^testing.T) {
	input := "{\"key\":null,\"flag\":false,\"value\":null}\n" +
	         "{\"key\":\"eu\",\"flag\":true,\"value\":2.5}\n"
	table, err := ingest.read_jsonl_string(input, "json_array_output")
	testing.expect_value(t, err, snout_core.Error.None)
	if err != .None {
		return
	}
	defer snout_core.free_table(&table)

	result := execute_test_group(
		t,
		&table,
		[]string{"key", "flag"},
		[]query.Aggregate_Spec{{kind = .Avg, column_name = "value"}},
	)
	if result.groups == nil {
		return
	}
	defer query.free_group_result_set(&result)

	rendered, render_err := result_output.render_group_results(
		&result,
		result.groups,
		.JSON,
	)
	testing.expect_value(t, render_err, snout_core.Error.None)
	if render_err != .None {
		return
	}
	defer delete(rendered)

	expected :=
		"[{\"key\":null,\"flag\":false,\"avg(value)\":null}," +
		"{\"key\":\"eu\",\"flag\":true,\"avg(value)\":2.5}]\n"
	testing.expect_value(t, rendered, expected)
	testing.expect(t, !strings.contains(rendered, "groups:"))
}

@(test)
zero_limit_output_contracts_are_preserved :: proc(t: ^testing.T) {
	input := "{\"key\":\"a\",\"value\":1}\n"
	table, err := ingest.read_jsonl_string(input, "zero_limit")
	testing.expect_value(t, err, snout_core.Error.None)
	if err != .None {
		return
	}
	defer snout_core.free_table(&table)

	result := execute_test_group(t, &table, []string{"key"}, []query.Aggregate_Spec{
		{kind = .Avg, column_name = "value"},
	})
	if result.groups == nil {
		return
	}
	defer query.free_group_result_set(&result)

	table_text, _ := result_output.render_group_results(
		&result,
		result.groups[:0],
		.Table,
		true,
	)
	defer delete(table_text)
	testing.expect(t, strings.contains(table_text, "shown: 0"))
	testing.expect(t, strings.contains(table_text, "key  avg(value)"))

	csv_text, _ := result_output.render_group_results(
		&result,
		result.groups[:0],
		.CSV,
	)
	defer delete(csv_text)
	testing.expect_value(t, csv_text, "key,avg(value)\n")

	json_text, _ := result_output.render_group_results(
		&result,
		result.groups[:0],
		.JSON,
	)
	defer delete(json_text)
	testing.expect_value(t, json_text, "[]\n")

	jsonl_text, _ := result_output.render_group_results(
		&result,
		result.groups[:0],
		.JSONL,
	)
	defer delete(jsonl_text)
	testing.expect_value(t, jsonl_text, "")
}

@(test)
output_writer_failures_are_reported :: proc(t: ^testing.T) {
	result := query.Group_Result_Set{
		group_columns = []string{"key"},
		aggregates = []query.Aggregate_Spec{{kind = .Count, column_name = "*"}},
	}
	writer := io.Writer{procedure = failing_writer_proc}
	err := result_output.write_group_results(
		writer,
		&result,
		nil,
		.CSV,
	)
	testing.expect_value(t, err, snout_core.Error.Output_Write_Failed)
}

failing_writer_proc :: proc(
	_: rawptr,
	mode: io.Stream_Mode,
	_: []byte,
	_: i64,
	_: io.Seek_From,
) -> (i64, io.Error) {
	#partial switch mode {
	case .Query:
		return io.query_utility({.Write})
	case .Write:
		return 0, .Closed
	case:
		return 0, .Unsupported
	}
}

execute_test_group :: proc(
	t: ^testing.T,
	table: ^snout_core.Table,
	group_columns: []string,
	aggregates: []query.Aggregate_Spec,
) -> query.Group_Result_Set {
	result, err := query.execute_group_query(
		table,
		query.Group_Query{
			group_columns = group_columns,
			aggregates = aggregates,
		},
	)
	testing.expect_value(t, err, snout_core.Error.None)
	return result
}
