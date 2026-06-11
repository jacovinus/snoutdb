package tests

import "core:fmt"
import "core:os"
import "core:testing"
import snout_core "../core"
import ingest "../ingest"
import result_output "../output"
import sniff "../sniff"

@(private = "file")
write_sniff_jsonl :: proc(t: ^testing.T, name, content: string) -> string {
	path := fmt.aprintf("tests/fixtures/.tmp_sniff_jsonl_%s.jsonl", name)
	err := os.write_entire_file(path, transmute([]byte)content)
	testing.expect(t, err == nil, "could not write temp sniff jsonl fixture")
	return path
}

@(private = "file")
remove_sniff_jsonl :: proc(path: string) {
	os.remove(path)
	delete(path)
}

// expect_jsonl_direct_matches_table compares profile_jsonl_file against
// read_jsonl_table + profile_table and asserts byte-identical renders.
@(private = "file")
expect_jsonl_direct_matches_table :: proc(
	t: ^testing.T,
	path, table_name: string,
	config: sniff.Sniff_Config = sniff.DEFAULT_SNIFF_CONFIG,
) {
	direct, direct_err := sniff.profile_jsonl_file(path, table_name, config)
	testing.expect_value(t, direct_err, snout_core.Error.None)
	if direct_err != .None {
		return
	}
	defer sniff.free_sniff_report(&direct)

	table, table_err := ingest.read_jsonl_table(path, table_name)
	testing.expect_value(t, table_err, snout_core.Error.None)
	if table_err != .None {
		return
	}
	defer snout_core.free_table(&table)

	from_table, profile_err := sniff.profile_table(&table, config)
	testing.expect_value(t, profile_err, snout_core.Error.None)
	if profile_err != .None {
		return
	}
	defer sniff.free_sniff_report(&from_table)

	direct_table_render, direct_table_err := result_output.render_sniff_report(
		&direct,
		path,
		.Table,
		context.temp_allocator,
	)
	testing.expect_value(t, direct_table_err, snout_core.Error.None)
	table_table_render, table_table_err := result_output.render_sniff_report(
		&from_table,
		path,
		.Table,
		context.temp_allocator,
	)
	testing.expect_value(t, table_table_err, snout_core.Error.None)
	testing.expect_value(t, direct_table_render, table_table_render)

	direct_json_render, direct_json_err := result_output.render_sniff_report(
		&direct,
		path,
		.JSON,
		context.temp_allocator,
	)
	testing.expect_value(t, direct_json_err, snout_core.Error.None)
	table_json_render, table_json_err := result_output.render_sniff_report(
		&from_table,
		path,
		.JSON,
		context.temp_allocator,
	)
	testing.expect_value(t, table_json_err, snout_core.Error.None)
	testing.expect_value(t, direct_json_render, table_json_render)
}

@(test)
sniff_jsonl_direct_matches_table_complex_metrics_500 :: proc(t: ^testing.T) {
	expect_jsonl_direct_matches_table(
		t,
		"tests/fixtures/complex_metrics_500.jsonl",
		"complex_metrics",
	)
}

@(test)
sniff_jsonl_direct_matches_table_simple_events :: proc(t: ^testing.T) {
	expect_jsonl_direct_matches_table(t, "tests/fixtures/simple_events.jsonl", "simple_events")
}

@(test)
sniff_jsonl_direct_matches_table_reduced_config :: proc(t: ^testing.T) {
	config := sniff.DEFAULT_SNIFF_CONFIG
	config.top_value_count = 2
	config.max_suggestions = 2
	expect_jsonl_direct_matches_table(
		t,
		"tests/fixtures/complex_metrics_500.jsonl",
		"complex_metrics",
		config,
	)
}

@(test)
sniff_jsonl_direct_matches_table_zero_top_suggestions :: proc(t: ^testing.T) {
	config := sniff.DEFAULT_SNIFF_CONFIG
	config.top_value_count = 0
	config.max_suggestions = 0
	expect_jsonl_direct_matches_table(
		t,
		"tests/fixtures/complex_metrics_500.jsonl",
		"complex_metrics",
		config,
	)
}

@(test)
sniff_jsonl_direct_matches_table_truncated_cardinality :: proc(t: ^testing.T) {
	config := sniff.DEFAULT_SNIFF_CONFIG
	config.max_distinct_values = 3
	expect_jsonl_direct_matches_table(
		t,
		"tests/fixtures/complex_metrics_500.jsonl",
		"complex_metrics",
		config,
	)
}

@(test)
sniff_jsonl_role_parity :: proc(t: ^testing.T) {
	direct, direct_err := sniff.profile_jsonl_file(
		"tests/fixtures/complex_metrics_500.jsonl",
		"complex_metrics",
	)
	testing.expect_value(t, direct_err, snout_core.Error.None)
	if direct_err != .None {
		return
	}
	defer sniff.free_sniff_report(&direct)

	table, table_err := ingest.read_jsonl_table(
		"tests/fixtures/complex_metrics_500.jsonl",
		"complex_metrics",
	)
	testing.expect_value(t, table_err, snout_core.Error.None)
	if table_err != .None {
		return
	}
	defer snout_core.free_table(&table)

	from_table, profile_err := sniff.profile_table(&table)
	testing.expect_value(t, profile_err, snout_core.Error.None)
	if profile_err != .None {
		return
	}
	defer sniff.free_sniff_report(&from_table)

	testing.expect_value(t, len(direct.columns), len(from_table.columns))
	for col, index in from_table.columns {
		testing.expect_value(t, direct.columns[index].role, col.role)
	}
}

@(test)
sniff_jsonl_direct_report_fields :: proc(t: ^testing.T) {
	report, err := sniff.profile_jsonl_file(
		"tests/fixtures/complex_metrics_500.jsonl",
		"complex_metrics",
	)
	testing.expect_value(t, err, snout_core.Error.None)
	if err != .None {
		return
	}
	defer sniff.free_sniff_report(&report)

	testing.expect_value(t, report.row_count, 500)
	testing.expect_value(t, report.table_name, "complex_metrics")
	testing.expect(t, report.column_count > 0)
}

@(test)
sniff_jsonl_direct_missing_file :: proc(t: ^testing.T) {
	_, err := sniff.profile_jsonl_file("/nonexistent/path.jsonl", "x")
	testing.expect_value(t, err, snout_core.Error.Io)
}

@(test)
sniff_jsonl_direct_repeated_calls_stable :: proc(t: ^testing.T) {
	config := sniff.DEFAULT_SNIFF_CONFIG
	path := "tests/fixtures/complex_metrics_500.jsonl"

	r1, err1 := sniff.profile_jsonl_file(path, "cm")
	testing.expect_value(t, err1, snout_core.Error.None)
	if err1 != .None {
		return
	}
	defer sniff.free_sniff_report(&r1)

	r2, err2 := sniff.profile_jsonl_file(path, "cm", config)
	testing.expect_value(t, err2, snout_core.Error.None)
	if err2 != .None {
		return
	}
	defer sniff.free_sniff_report(&r2)

	render1, _ := result_output.render_sniff_report(&r1, path, .JSON, context.temp_allocator)
	render2, _ := result_output.render_sniff_report(&r2, path, .JSON, context.temp_allocator)
	testing.expect_value(t, render1, render2)
}

@(test)
sniff_jsonl_direct_all_null_column :: proc(t: ^testing.T) {
	content := "{\"a\":1,\"b\":null}\n{\"a\":2,\"b\":null}\n"
	path := write_sniff_jsonl(t, "all_null", content)
	defer remove_sniff_jsonl(path)
	expect_jsonl_direct_matches_table(t, path, "all_null")
}

@(test)
sniff_jsonl_direct_int_float_promotion :: proc(t: ^testing.T) {
	content := "{\"value\":10}\n{\"value\":12.5}\n{\"value\":7}\n"
	path := write_sniff_jsonl(t, "int_float_sniff", content)
	defer remove_sniff_jsonl(path)
	expect_jsonl_direct_matches_table(t, path, "int_float_sniff")
}

@(test)
sniff_jsonl_direct_late_field :: proc(t: ^testing.T) {
	content := "{\"a\":1,\"b\":\"x\"}\n{\"a\":2,\"b\":\"y\",\"c\":true}\n"
	path := write_sniff_jsonl(t, "late_field_sniff", content)
	defer remove_sniff_jsonl(path)
	expect_jsonl_direct_matches_table(t, path, "late_field_sniff")
}
