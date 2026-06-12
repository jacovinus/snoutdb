package tests

import "core:testing"
import snout_core "../core"
import ingest "../ingest"
import query "../query"
import storage "../storage"

@(test)
composite_grouping_and_multiple_aggregates_work :: proc(t: ^testing.T) {
	table, err := ingest.read_jsonl_table(COMPLEX_JSONL_PATH, "calls")
	testing.expect_value(t, err, snout_core.Error.None)
	if err != .None {
		return
	}
	defer snout_core.free_table(&table)

	group_columns := [?]string{"region", "carrier"}
	aggregates := [?]query.Aggregate_Spec{
		{kind = .Avg, column_name = "mos"},
		{kind = .Count, column_name = "*"},
		{kind = .Max, column_name = "jitter_ms"},
	}
	result, query_err := query.execute_group_query(
		&table,
		query.Group_Query{
			group_columns = group_columns[:],
			aggregates = aggregates[:],
		},
	)
	testing.expect_value(t, query_err, snout_core.Error.None)
	if query_err != .None {
		return
	}
	defer query.free_group_result_set(&result)

	testing.expect_value(t, result.selected_rows, 100)
	testing.expect_value(t, len(result.group_columns), 2)
	testing.expect_value(t, len(result.aggregates), 3)
	total := 0
	for group, index in result.groups {
		testing.expect_value(t, len(group.keys), 2)
		testing.expect_value(t, len(group.values), 3)
		testing.expect(t, group.values[0].valid)
		testing.expect_value(t, group.values[1].int_value, i64(group.row_count))
		total += group.row_count
		if index > 0 {
			testing.expect(
				t,
				query.compare_group_results(result.groups[index-1], group) < 0,
			)
		}
	}
	testing.expect_value(t, total, 100)
}

@(test)
filters_apply_before_all_aggregates :: proc(t: ^testing.T) {
	table, err := ingest.read_jsonl_table(COMPLEX_JSONL_PATH, "calls")
	testing.expect_value(t, err, snout_core.Error.None)
	if err != .None {
		return
	}
	defer snout_core.free_table(&table)

	completed, predicate_err := query.make_filter_predicate(
		&table,
		"result",
		.Equal,
		"completed",
	)
	testing.expect_value(t, predicate_err, snout_core.Error.None)
	group_columns := [?]string{"region"}
	aggregates := [?]query.Aggregate_Spec{
		{kind = .Avg, column_name = "mos"},
		{kind = .Count, column_name = "*"},
	}
	filters := [?]query.Filter_Predicate{completed}
	result, query_err := query.execute_group_query(
		&table,
		query.Group_Query{
			group_columns = group_columns[:],
			aggregates = aggregates[:],
			filters = filters[:],
		},
	)
	testing.expect_value(t, query_err, snout_core.Error.None)
	if query_err != .None {
		return
	}
	defer query.free_group_result_set(&result)

	testing.expect(t, result.selected_rows > 0)
	testing.expect(t, result.selected_rows < table.row_count)
	for group in result.groups {
		testing.expect(t, group.values[0].float_value >= 1)
		testing.expect(t, group.values[0].float_value <= 5)
		testing.expect_value(t, group.values[1].int_value, i64(group.row_count))
	}
}

@(test)
composite_keys_preserve_types_and_nulls :: proc(t: ^testing.T) {
	input := "{\"region\":\"eu\",\"status\":200,\"cached\":true}\n" +
	         "{\"region\":\"eu\",\"status\":200,\"cached\":false}\n" +
	         "{\"region\":\"eu\",\"status\":null,\"cached\":false}\n" +
	         "{\"region\":\"us\",\"status\":200,\"cached\":true}\n"
	table, err := ingest.read_jsonl_string(input, "typed_keys")
	testing.expect_value(t, err, snout_core.Error.None)
	if err != .None {
		return
	}
	defer snout_core.free_table(&table)

	group_columns := [?]string{"region", "status", "cached"}
	aggregates := [?]query.Aggregate_Spec{{kind = .Count, column_name = "*"}}
	result, query_err := query.execute_group_query(
		&table,
		query.Group_Query{
			group_columns = group_columns[:],
			aggregates = aggregates[:],
		},
	)
	testing.expect_value(t, query_err, snout_core.Error.None)
	if query_err != .None {
		return
	}
	defer query.free_group_result_set(&result)

	testing.expect_value(t, len(result.groups), 4)
	testing.expect_value(t, result.groups[0].keys[0].string_value, "eu")
	testing.expect(t, result.groups[0].keys[1].is_null)
	testing.expect(t, !result.groups[1].keys[2].bool_value)
	testing.expect(t, result.groups[2].keys[2].bool_value)
}

@(test)
numeric_aggregates_ignore_null_values :: proc(t: ^testing.T) {
	input := "{\"key\":\"a\",\"i\":2,\"f\":1.5}\n" +
	         "{\"key\":\"a\",\"i\":null,\"f\":null}\n" +
	         "{\"key\":\"a\",\"i\":8,\"f\":4.5}\n"
	table, err := ingest.read_jsonl_string(input, "aggregates")
	testing.expect_value(t, err, snout_core.Error.None)
	if err != .None {
		return
	}
	defer snout_core.free_table(&table)

	group_columns := [?]string{"key"}
	aggregates := [?]query.Aggregate_Spec{
		{kind = .Sum, column_name = "i"},
		{kind = .Avg, column_name = "i"},
		{kind = .Min, column_name = "f"},
		{kind = .Max, column_name = "f"},
	}
	result, query_err := query.execute_group_query(
		&table,
		query.Group_Query{
			group_columns = group_columns[:],
			aggregates = aggregates[:],
		},
	)
	testing.expect_value(t, query_err, snout_core.Error.None)
	if query_err != .None {
		return
	}
	defer query.free_group_result_set(&result)

	values := result.groups[0].values
	testing.expect_value(t, values[0].int_value, i64(10))
	testing.expect_value(t, values[0].count, 2)
	testing.expect_value(t, values[1].float_value, 5.0)
	testing.expect_value(t, values[2].float_value, 1.5)
	testing.expect_value(t, values[3].float_value, 4.5)
}

@(test)
count_star_and_count_column_are_explicit :: proc(t: ^testing.T) {
	input := "{\"key\":\"a\",\"value\":1}\n" +
	         "{\"key\":\"a\",\"value\":null}\n" +
	         "{\"key\":\"a\",\"value\":3}\n"
	table, err := ingest.read_jsonl_string(input, "counts")
	testing.expect_value(t, err, snout_core.Error.None)
	if err != .None {
		return
	}
	defer snout_core.free_table(&table)

	group_columns := [?]string{"key"}
	aggregates := [?]query.Aggregate_Spec{
		{kind = .Count, column_name = "*"},
		{kind = .Count, column_name = "value"},
	}
	result, query_err := query.execute_group_query(
		&table,
		query.Group_Query{
			group_columns = group_columns[:],
			aggregates = aggregates[:],
		},
	)
	testing.expect_value(t, query_err, snout_core.Error.None)
	if query_err != .None {
		return
	}
	defer query.free_group_result_set(&result)

	testing.expect_value(t, result.groups[0].values[0].int_value, i64(3))
	testing.expect_value(t, result.groups[0].values[1].int_value, i64(2))
}

@(test)
null_only_aggregate_is_null_without_implicit_count :: proc(t: ^testing.T) {
	input := "{\"key\":\"empty\",\"value\":null}\n" +
	         "{\"key\":\"full\",\"value\":4}\n"
	table, err := ingest.read_jsonl_string(input, "null_aggregate")
	testing.expect_value(t, err, snout_core.Error.None)
	if err != .None {
		return
	}
	defer snout_core.free_table(&table)

	group_columns := [?]string{"key"}
	aggregates := [?]query.Aggregate_Spec{{kind = .Avg, column_name = "value"}}
	result, query_err := query.execute_group_query(
		&table,
		query.Group_Query{
			group_columns = group_columns[:],
			aggregates = aggregates[:],
		},
	)
	testing.expect_value(t, query_err, snout_core.Error.None)
	if query_err != .None {
		return
	}
	defer query.free_group_result_set(&result)

	testing.expect_value(t, len(result.groups[0].values), 1)
	testing.expect(t, !result.groups[0].values[0].valid)
	testing.expect(t, result.groups[1].values[0].valid)
}

@(test)
filters_are_typed_and_combined_with_and :: proc(t: ^testing.T) {
	input := "{\"at\":\"2026-01-01T00:00:00Z\",\"n\":1,\"ok\":true,\"v\":null}\n" +
	         "{\"at\":\"2026-01-02T00:00:00Z\",\"n\":5,\"ok\":true,\"v\":2}\n" +
	         "{\"at\":\"2026-01-03T00:00:00Z\",\"n\":9,\"ok\":false,\"v\":3}\n"
	table, err := ingest.read_jsonl_string(input, "filters")
	testing.expect_value(t, err, snout_core.Error.None)
	if err != .None {
		return
	}
	defer snout_core.free_table(&table)

	numeric, numeric_err := query.make_filter_predicate(&table, "n", .Greater_Equal, "5")
	boolean, bool_err := query.make_filter_predicate(&table, "ok", .Equal, "true")
	timestamp, timestamp_err := query.make_filter_predicate(
		&table,
		"at",
		.Greater_Equal,
		"2026-01-02T00:00:00Z",
	)
	non_null, null_err := query.make_filter_predicate(&table, "v", .Is_Not_Null, "")
	testing.expect_value(t, numeric_err, snout_core.Error.None)
	testing.expect_value(t, bool_err, snout_core.Error.None)
	testing.expect_value(t, timestamp_err, snout_core.Error.None)
	testing.expect_value(t, null_err, snout_core.Error.None)

	filters := [?]query.Filter_Predicate{numeric, boolean, timestamp, non_null}
	selection, count, selection_err := query.build_selection(&table, filters[:])
	testing.expect_value(t, selection_err, snout_core.Error.None)
	if selection_err == .None {
		defer delete(selection)
		testing.expect_value(t, count, 1)
		testing.expect(t, selection[1])
	}
}

@(test)
string_contains_filters_support_partial_and_case_insensitive_matches :: proc(t: ^testing.T) {
	input := "{\"message\":\"Start to send telemetry events\",\"level\":\"INFO\"}\n" +
	         "{\"message\":\"Telemetry upload failed\",\"level\":\"ERROR\"}\n" +
	         "{\"message\":\"window resized\",\"level\":\"INFO\"}\n" +
	         "{\"message\":null,\"level\":\"WARN\"}\n"
	table, err := ingest.read_jsonl_string(input, "contains")
	testing.expect_value(t, err, snout_core.Error.None)
	if err != .None {
		return
	}
	defer snout_core.free_table(&table)

	contains, contains_err := query.make_filter_predicate(
		&table,
		"message",
		.Contains,
		"telemetry",
	)
	icontains, icontains_err := query.make_filter_predicate(
		&table,
		"message",
		.IContains,
		"TELEMETRY",
	)
	not_contains, not_contains_err := query.make_filter_predicate(
		&table,
		"message",
		.Not_Contains,
		"telemetry",
	)
	testing.expect_value(t, contains_err, snout_core.Error.None)
	testing.expect_value(t, icontains_err, snout_core.Error.None)
	testing.expect_value(t, not_contains_err, snout_core.Error.None)

	contains_selection, contains_count, contains_selection_err :=
		query.build_selection(&table, []query.Filter_Predicate{contains})
	testing.expect_value(t, contains_selection_err, snout_core.Error.None)
	if contains_selection_err == .None {
		defer delete(contains_selection)
		testing.expect_value(t, contains_count, 1)
		testing.expect(t, contains_selection[0])
	}

	icontains_selection, icontains_count, icontains_selection_err :=
		query.build_selection(&table, []query.Filter_Predicate{icontains})
	testing.expect_value(t, icontains_selection_err, snout_core.Error.None)
	if icontains_selection_err == .None {
		defer delete(icontains_selection)
		testing.expect_value(t, icontains_count, 2)
		testing.expect(t, icontains_selection[0])
		testing.expect(t, icontains_selection[1])
	}

	not_selection, not_count, not_selection_err :=
		query.build_selection(&table, []query.Filter_Predicate{not_contains})
	testing.expect_value(t, not_selection_err, snout_core.Error.None)
	if not_selection_err == .None {
		defer delete(not_selection)
		testing.expect_value(t, not_count, 2)
		testing.expect(t, not_selection[1])
		testing.expect(t, not_selection[2])
		testing.expect(t, !not_selection[3], "null strings should not match not-contains")
	}
}

@(test)
contains_filters_reject_non_string_columns :: proc(t: ^testing.T) {
	input := "{\"message\":\"ok\",\"status\":200,\"at\":\"2026-01-01T00:00:00Z\"}\n"
	table, err := ingest.read_jsonl_string(input, "contains_types")
	testing.expect_value(t, err, snout_core.Error.None)
	if err != .None {
		return
	}
	defer snout_core.free_table(&table)

	_, numeric_err := query.make_filter_predicate(&table, "status", .Contains, "20")
	_, timestamp_err := query.make_filter_predicate(&table, "at", .IContains, "2026")
	testing.expect_value(t, numeric_err, snout_core.Error.Unsupported_Filter_Operator)
	testing.expect_value(t, timestamp_err, snout_core.Error.Unsupported_Filter_Operator)
}

@(test)
contains_filter_operators_parse :: proc(t: ^testing.T) {
	contains, contains_ok := query.parse_filter_operator("contains")
	not_contains, not_contains_ok := query.parse_filter_operator("not-contains")
	icontains, icontains_ok := query.parse_filter_operator("icontains")
	testing.expect(t, contains_ok)
	testing.expect(t, not_contains_ok)
	testing.expect(t, icontains_ok)
	testing.expect_value(t, contains, query.Filter_Operator.Contains)
	testing.expect_value(t, not_contains, query.Filter_Operator.Not_Contains)
	testing.expect_value(t, icontains, query.Filter_Operator.IContains)
}

@(test)
query_validation_returns_specific_errors :: proc(t: ^testing.T) {
	input := "{\"key\":\"a\",\"number\":1,\"ratio\":1.5,\"flag\":true}\n"
	table, err := ingest.read_jsonl_string(input, "errors")
	testing.expect_value(t, err, snout_core.Error.None)
	if err != .None {
		return
	}
	defer snout_core.free_table(&table)

	count := [?]query.Aggregate_Spec{{kind = .Count, column_name = "*"}}
	missing := [?]string{"missing"}
	_, missing_err := query.execute_group_query(
		&table,
		query.Group_Query{group_columns = missing[:], aggregates = count[:]},
	)
	testing.expect_value(t, missing_err, snout_core.Error.Column_Not_Found)

	float_group := [?]string{"ratio"}
	_, float_group_err := query.execute_group_query(
		&table,
		query.Group_Query{group_columns = float_group[:], aggregates = count[:]},
	)
	testing.expect_value(
		t,
		float_group_err,
		snout_core.Error.Unsupported_Group_Column_Type,
	)

	key_group := [?]string{"key"}
	invalid_sum := [?]query.Aggregate_Spec{{kind = .Sum, column_name = "key"}}
	_, aggregate_err := query.execute_group_query(
		&table,
		query.Group_Query{
			group_columns = key_group[:],
			aggregates = invalid_sum[:],
		},
	)
	testing.expect_value(
		t,
		aggregate_err,
		snout_core.Error.Invalid_Aggregate_Column,
	)

	_, malformed_err := query.execute_group_query(&table, query.Group_Query{})
	testing.expect_value(
		t,
		malformed_err,
		snout_core.Error.Malformed_Query_Arguments,
	)
}

@(test)
query_limits_are_enforced :: proc(t: ^testing.T) {
	input := "{\"key\":\"a\"}\n{\"key\":\"b\"}\n"
	table, err := ingest.read_jsonl_string(input, "limits")
	testing.expect_value(t, err, snout_core.Error.None)
	if err != .None {
		return
	}
	defer snout_core.free_table(&table)

	group_columns := [?]string{"key"}
	aggregates := [?]query.Aggregate_Spec{{kind = .Count, column_name = "*"}}
	_, group_err := query.execute_group_query(
		&table,
		query.Group_Query{
			group_columns = group_columns[:],
			aggregates = aggregates[:],
			max_groups = 1,
		},
	)
	testing.expect_value(t, group_err, snout_core.Error.Too_Many_Groups)

	filters := make([]query.Filter_Predicate, query.MAX_FILTERS+1)
	defer delete(filters)
	_, _, filter_err := query.build_selection(&table, filters)
	testing.expect_value(t, filter_err, snout_core.Error.Too_Many_Filters)
}

@(test)
integer_overflow_only_affects_sum_based_aggregates :: proc(t: ^testing.T) {
	input := "{\"key\":\"a\",\"value\":9223372036854775807}\n" +
	         "{\"key\":\"a\",\"value\":1}\n"
	table, err := ingest.read_jsonl_string(input, "overflow")
	testing.expect_value(t, err, snout_core.Error.None)
	if err != .None {
		return
	}
	defer snout_core.free_table(&table)

	group_columns := [?]string{"key"}
	sum_spec := [?]query.Aggregate_Spec{{kind = .Sum, column_name = "value"}}
	_, sum_err := query.execute_group_query(
		&table,
		query.Group_Query{
			group_columns = group_columns[:],
			aggregates = sum_spec[:],
		},
	)
	testing.expect_value(t, sum_err, snout_core.Error.Aggregate_Overflow)

	min_spec := [?]query.Aggregate_Spec{{kind = .Min, column_name = "value"}}
	minimum, min_err := query.execute_group_query(
		&table,
		query.Group_Query{
			group_columns = group_columns[:],
			aggregates = min_spec[:],
		},
	)
	testing.expect_value(t, min_err, snout_core.Error.None)
	if min_err == .None {
		defer query.free_group_result_set(&minimum)
		testing.expect_value(t, minimum.groups[0].values[0].int_value, i64(1))
	}
}

@(test)
composite_results_survive_snout_round_trip :: proc(t: ^testing.T) {
	source, err := ingest.read_jsonl_table(COMPLEX_JSONL_PATH, "calls")
	testing.expect_value(t, err, snout_core.Error.None)
	if err != .None {
		return
	}
	defer snout_core.free_table(&source)

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

	group_columns := [?]string{"region", "carrier"}
	aggregates := [?]query.Aggregate_Spec{
		{kind = .Avg, column_name = "mos"},
		{kind = .Count, column_name = "*"},
	}
	group_query := query.Group_Query{
		group_columns = group_columns[:],
		aggregates = aggregates[:],
	}
	source_result, source_err := query.execute_group_query(&source, group_query)
	loaded_result, loaded_err := query.execute_group_query(&loaded, group_query)
	testing.expect_value(t, source_err, snout_core.Error.None)
	testing.expect_value(t, loaded_err, snout_core.Error.None)
	if source_err != .None || loaded_err != .None {
		return
	}
	defer query.free_group_result_set(&source_result)
	defer query.free_group_result_set(&loaded_result)

	testing.expect_value(t, len(source_result.groups), len(loaded_result.groups))
	for group, index in source_result.groups {
		testing.expect_value(
			t,
			group.keys[0].string_value,
			loaded_result.groups[index].keys[0].string_value,
		)
		testing.expect_value(
			t,
			group.keys[1].string_value,
			loaded_result.groups[index].keys[1].string_value,
		)
		testing.expect_value(
			t,
			group.values[0].float_value,
			loaded_result.groups[index].values[0].float_value,
		)
	}
}
