package tests

import "core:fmt"
import "core:os"
import "core:testing"
import snout_core "../core"
import ingest "../ingest"
import result_output "../output"
import sniff "../sniff"

@(private = "file")
write_sniff_csv :: proc(t: ^testing.T, name, content: string) -> string {
	path := fmt.aprintf("tests/fixtures/.tmp_sniff_%s.csv", name)
	err := os.write_entire_file(path, transmute([]byte)content)
	testing.expect(t, err == nil, "could not write temp fixture")
	return path
}

@(private = "file")
remove_sniff_csv :: proc(path: string) {
	os.remove(path)
	delete(path)
}

@(private = "file")
expect_direct_matches_table :: proc(
	t: ^testing.T,
	path, table_name: string,
	config: sniff.Sniff_Config = sniff.DEFAULT_SNIFF_CONFIG,
) {
	direct, direct_err := sniff.profile_csv_file(path, table_name, config)
	testing.expect_value(t, direct_err, snout_core.Error.None)
	if direct_err != .None {
		return
	}
	defer sniff.free_sniff_report(&direct)

	table, table_err := ingest.read_csv_table(path, table_name)
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
direct_sniff_matches_table_sniff_fixture_500 :: proc(t: ^testing.T) {
	expect_direct_matches_table(
		t,
		"tests/fixtures/complex_metrics_500.csv",
		"complex_metrics_500",
	)
}

@(test)
direct_sniff_matches_table_sniff_simple :: proc(t: ^testing.T) {
	expect_direct_matches_table(
		t,
		"tests/fixtures/simple_metrics.csv",
		"simple_metrics",
	)
}

@(test)
direct_sniff_matches_with_reduced_config :: proc(t: ^testing.T) {
	config := sniff.DEFAULT_SNIFF_CONFIG
	config.top_value_count = 2
	config.max_suggestions = 1
	expect_direct_matches_table(
		t,
		"tests/fixtures/complex_metrics_500.csv",
		"complex_metrics_500",
		config,
	)
}

@(test)
direct_sniff_matches_with_truncated_cardinality :: proc(t: ^testing.T) {
	config := sniff.DEFAULT_SNIFF_CONFIG
	config.max_distinct_values = 3
	expect_direct_matches_table(
		t,
		"tests/fixtures/complex_metrics_500.csv",
		"complex_metrics_500",
		config,
	)
}

@(test)
direct_sniff_matches_with_zero_top_and_suggestions :: proc(t: ^testing.T) {
	config := sniff.DEFAULT_SNIFF_CONFIG
	config.top_value_count = 0
	config.max_suggestions = 0
	expect_direct_matches_table(
		t,
		"tests/fixtures/complex_metrics_500.csv",
		"complex_metrics_500",
		config,
	)
}

@(test)
direct_sniff_all_null_column_parity :: proc(t: ^testing.T) {
	content := "a,empty\n1,\n2,\n3,\n"
	path := write_sniff_csv(t, "all_null", content)
	defer remove_sniff_csv(path)
	expect_direct_matches_table(t, path, "all_null")
}

@(test)
direct_sniff_header_only_parity :: proc(t: ^testing.T) {
	content := "a,b\n"
	path := write_sniff_csv(t, "header_only", content)
	defer remove_sniff_csv(path)
	expect_direct_matches_table(t, path, "header_only")
}

@(test)
direct_sniff_role_parity_mixed :: proc(t: ^testing.T) {
	content := "user_id,region,score,active,created_at\n" +
		"u-1,eu-west,1.5,true,2026-06-08T10:00:00Z\n" +
		"u-2,eu-west,2.5,false,2026-06-08T10:00:01Z\n" +
		"u-3,us-east,3.5,true,2026-06-08T10:00:02Z\n" +
		"u-4,us-east,4.5,false,2026-06-08T10:00:03Z\n"
	path := write_sniff_csv(t, "roles", content)
	defer remove_sniff_csv(path)
	expect_direct_matches_table(t, path, "roles")
}

@(test)
direct_sniff_report_fields :: proc(t: ^testing.T) {
	report, err := sniff.profile_csv_file(
		"tests/fixtures/complex_metrics_500.csv",
		"complex_metrics_500",
	)
	testing.expect_value(t, err, snout_core.Error.None)
	if err != .None {
		return
	}
	defer sniff.free_sniff_report(&report)

	testing.expect_value(t, report.version, 1)
	testing.expect_value(t, report.table_name, "complex_metrics_500")
	testing.expect_value(t, report.row_count, 500)
	testing.expect_value(t, report.column_count, 20)
}

@(test)
direct_sniff_missing_file :: proc(t: ^testing.T) {
	_, err := sniff.profile_csv_file("tests/fixtures/.no_such_file.csv", "missing")
	testing.expect_value(t, err, snout_core.Error.Io)
}

@(test)
direct_sniff_file_changed_between_passes :: proc(t: ^testing.T) {
	content := "a,b\n1,x\n"
	path := write_sniff_csv(t, "mutating", content)
	defer remove_sniff_csv(path)

	report, err := sniff.profile_csv_file(path, "mutating")
	testing.expect_value(t, err, snout_core.Error.None)
	if err == .None {
		sniff.free_sniff_report(&report)
	}
}

@(test)
direct_sniff_repeated_calls_are_stable :: proc(t: ^testing.T) {
	for _ in 0 ..< 3 {
		report, err := sniff.profile_csv_file(
			"tests/fixtures/complex_metrics_500.csv",
			"complex_metrics_500",
		)
		testing.expect_value(t, err, snout_core.Error.None)
		if err != .None {
			return
		}
		testing.expect_value(t, report.row_count, 500)
		sniff.free_sniff_report(&report)
	}
}
