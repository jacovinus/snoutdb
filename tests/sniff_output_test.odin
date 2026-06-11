package tests

import "core:encoding/json"
import "core:strings"
import "core:testing"
import snout_core "../core"
import ingest "../ingest"
import result_output "../output"
import sniff "../sniff"
import storage "../storage"

@(test)
sniff_suggestions_follow_supported_query_grammar :: proc(t: ^testing.T) {
	table, err := ingest.read_csv_table(
		"tests/fixtures/complex_metrics_500.csv",
		"complex_metrics_500",
	)
	testing.expect_value(t, err, snout_core.Error.None)
	if err != .None {
		return
	}
	defer snout_core.free_table(&table)

	report, profile_err := sniff.profile_table(&table)
	testing.expect_value(t, profile_err, snout_core.Error.None)
	if profile_err != .None {
		return
	}
	defer sniff.free_sniff_report(&report)

	testing.expect_value(t, len(report.suggestions), 5)
	first := &report.suggestions[0]
	testing.expect_value(t, len(first.group_columns), 1)
	testing.expect_value(t, len(first.aggregates), 2)
	testing.expect_value(t, first.aggregates[0].column_name, "mos")
	testing.expect_value(t, first.aggregates[1].column_name, "*")
	testing.expect_value(t, first.limit, 10)

	command := result_output.render_suggestion_command("calls.csv", first)
	testing.expect(t, strings.contains(command, "group="))
	testing.expect(t, strings.contains(command, "-- avg=mos count=rows"))
	testing.expect(t, strings.contains(command, "--sort avg=mos desc"))
}

@(test)
sniff_unsafe_names_are_profiled_but_omitted_from_suggestions :: proc(t: ^testing.T) {
	input := "{\"region\":\"eu\",\"average mos\":3.0}\n" +
	         "{\"region\":\"us\",\"average mos\":4.0}\n" +
	         "{\"region\":\"eu\",\"average mos\":2.0}\n"
	table, err := ingest.read_jsonl_string(input, "unsafe")
	testing.expect_value(t, err, snout_core.Error.None)
	if err != .None {
		return
	}
	defer snout_core.free_table(&table)

	report, profile_err := sniff.profile_table(&table)
	testing.expect_value(t, profile_err, snout_core.Error.None)
	if profile_err != .None {
		return
	}
	defer sniff.free_sniff_report(&report)

	_, found := sniff_profile_by_name(&report, "average mos")
	testing.expect(t, found)
	testing.expect_value(t, len(report.warnings), 1)
	testing.expect(t, strings.contains(report.warnings[0], "omitted from suggestions"))
	for &suggestion in report.suggestions {
		for &aggregate in suggestion.aggregates {
			testing.expect(t, aggregate.column_name != "average mos")
		}
	}
}

@(test)
sniff_table_and_json_outputs_include_the_required_contract :: proc(t: ^testing.T) {
	table, err := ingest.read_csv_table(
		"tests/fixtures/simple_metrics.csv",
		"simple_metrics",
	)
	testing.expect_value(t, err, snout_core.Error.None)
	if err != .None {
		return
	}
	defer snout_core.free_table(&table)

	report, profile_err := sniff.profile_table(&table)
	testing.expect_value(t, profile_err, snout_core.Error.None)
	if profile_err != .None {
		return
	}
	defer sniff.free_sniff_report(&report)

	table_text, table_err := result_output.render_sniff_report(
		&report,
		"tests/fixtures/simple_metrics.csv",
		.Table,
	)
	testing.expect_value(t, table_err, snout_core.Error.None)
	if table_err == .None {
		defer delete(table_text)
		testing.expect(t, strings.contains(table_text, "profile_version: 1"))
		testing.expect(t, strings.contains(table_text, "suggested queries"))
		testing.expect(t, strings.contains(table_text, "column"))
	}

	json_text, json_err := result_output.render_sniff_report(
		&report,
		"tests/fixtures/simple_metrics.csv",
		.JSON,
	)
	testing.expect_value(t, json_err, snout_core.Error.None)
	if json_err == .None {
		defer delete(json_text)
		testing.expect(t, strings.has_prefix(json_text, "{"))
		testing.expect(t, json.is_valid(transmute([]byte)json_text, parse_integers = true))
		testing.expect(t, strings.contains(json_text, `"version": 1`))
		testing.expect(t, strings.contains(json_text, `"numeric": null`))
	}
}

@(test)
sniff_json_output_is_deterministic :: proc(t: ^testing.T) {
	table, err := ingest.read_csv_table(
		"tests/fixtures/complex_metrics_500.csv",
		"complex_metrics_500",
	)
	testing.expect_value(t, err, snout_core.Error.None)
	if err != .None {
		return
	}
	defer snout_core.free_table(&table)

	first_report, first_err := sniff.profile_table(&table)
	testing.expect_value(t, first_err, snout_core.Error.None)
	if first_err != .None {
		return
	}
	defer sniff.free_sniff_report(&first_report)
	second_report, second_err := sniff.profile_table(&table)
	testing.expect_value(t, second_err, snout_core.Error.None)
	if second_err != .None {
		return
	}
	defer sniff.free_sniff_report(&second_report)

	first, first_render_err := result_output.render_sniff_report(
		&first_report,
		"fixture",
		.JSON,
	)
	testing.expect_value(t, first_render_err, snout_core.Error.None)
	if first_render_err != .None {
		return
	}
	defer delete(first)
	second, second_render_err := result_output.render_sniff_report(
		&second_report,
		"fixture",
		.JSON,
	)
	testing.expect_value(t, second_render_err, snout_core.Error.None)
	if second_render_err != .None {
		return
	}
	defer delete(second)
	testing.expect_value(t, first, second)
}

@(test)
sniff_csv_jsonl_and_snout_profiles_have_logical_parity :: proc(t: ^testing.T) {
	csv_table, csv_err := ingest.read_csv_table(
		"tests/fixtures/complex_metrics_500.csv",
		"equivalent",
	)
	testing.expect_value(t, csv_err, snout_core.Error.None)
	if csv_err != .None {
		return
	}
	defer snout_core.free_table(&csv_table)

	jsonl_table, jsonl_err := ingest.read_jsonl_table(
		"tests/fixtures/complex_metrics_500.jsonl",
		"equivalent",
	)
	testing.expect_value(t, jsonl_err, snout_core.Error.None)
	if jsonl_err != .None {
		return
	}
	defer snout_core.free_table(&jsonl_table)

	data, storage_err := storage.serialize_table(&jsonl_table)
	testing.expect_value(t, storage_err, snout_core.Error.None)
	if storage_err != .None {
		return
	}
	defer delete(data)
	snout_table, read_err := storage.deserialize_table(data)
	testing.expect_value(t, read_err, snout_core.Error.None)
	if read_err != .None {
		return
	}
	defer snout_core.free_table(&snout_table)

	csv_report, csv_profile_err := sniff.profile_table(&csv_table)
	jsonl_report, jsonl_profile_err := sniff.profile_table(&jsonl_table)
	snout_report, snout_profile_err := sniff.profile_table(&snout_table)
	testing.expect_value(t, csv_profile_err, snout_core.Error.None)
	testing.expect_value(t, jsonl_profile_err, snout_core.Error.None)
	testing.expect_value(t, snout_profile_err, snout_core.Error.None)
	if csv_profile_err != .None || jsonl_profile_err != .None || snout_profile_err != .None {
		return
	}
	defer sniff.free_sniff_report(&csv_report)
	defer sniff.free_sniff_report(&jsonl_report)
	defer sniff.free_sniff_report(&snout_report)

	csv_json, _ := result_output.render_sniff_report(&csv_report, "fixture", .JSON)
	defer delete(csv_json)
	jsonl_json, _ := result_output.render_sniff_report(&jsonl_report, "fixture", .JSON)
	defer delete(jsonl_json)
	snout_json, _ := result_output.render_sniff_report(&snout_report, "fixture", .JSON)
	defer delete(snout_json)
	testing.expect_value(t, csv_json, jsonl_json)
	testing.expect_value(t, jsonl_json, snout_json)
}

@(test)
sniff_option_values_are_strict_and_bounded :: proc(t: ^testing.T) {
	valid, valid_err := sniff.parse_sniff_option_value("20", 0, 20)
	testing.expect_value(t, valid_err, snout_core.Error.None)
	testing.expect_value(t, valid, 20)

	invalid_values := []string{"", "-1", "1.5", "1e2", "999999999999999999999999"}
	for value in invalid_values {
		_, err := sniff.parse_sniff_option_value(value, 0, 20)
		testing.expect_value(t, err, snout_core.Error.Invalid_Sniff_Option)
	}
	_, too_large := sniff.parse_sniff_option_value("21", 0, 20)
	testing.expect_value(t, too_large, snout_core.Error.Sniff_Limit_Too_Large)

	_, table_ok := result_output.parse_sniff_output_format("table")
	_, json_ok := result_output.parse_sniff_output_format("json")
	_, csv_ok := result_output.parse_sniff_output_format("csv")
	testing.expect(t, table_ok)
	testing.expect(t, json_ok)
	testing.expect(t, !csv_ok)
}
