package tests

import "core:math"
import "core:strings"
import "core:testing"
import snout_core "../core"
import ingest "../ingest"
import sniff "../sniff"

sniff_profile_by_name :: proc(
	report: ^sniff.Sniff_Report,
	name: string,
) -> (^sniff.Column_Profile, bool) {
	for &column in report.columns {
		if column.name == name {
			return &column, true
		}
	}
	return nil, false
}

@(test)
sniff_profiles_nulls_numeric_ranges_and_timestamps :: proc(t: ^testing.T) {
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

	timestamp, timestamp_found := sniff_profile_by_name(&report, "timestamp")
	testing.expect(t, timestamp_found)
	if timestamp_found {
		testing.expect_value(t, timestamp.role, sniff.Column_Role.Timestamp)
		testing.expect_value(t, timestamp.timestamp.min, "2026-06-08T10:00:00Z")
		testing.expect_value(t, timestamp.timestamp.max, "2026-06-08T12:21:23Z")
	}

	mos, mos_found := sniff_profile_by_name(&report, "mos")
	testing.expect(t, mos_found)
	if mos_found {
		testing.expect_value(t, mos.null_count, 11)
		testing.expect_value(t, mos.non_null_count, 489)
		testing.expect_value(t, mos.numeric.count, 489)
		testing.expect_value(t, mos.numeric.float_min, 1.83)
		testing.expect_value(t, mos.numeric.float_max, 4.41)
		testing.expect(t, mos.numeric.mean > 3.17 && mos.numeric.mean < 3.19)
	}
}

@(test)
sniff_cardinality_is_exact_at_the_configured_limit :: proc(t: ^testing.T) {
	input := "value\nalpha\nbeta\ngamma\nalpha\nbeta\ngamma\n"
	table, err := ingest.read_csv_string(input, "exact_limit")
	testing.expect_value(t, err, snout_core.Error.None)
	if err != .None {
		return
	}
	defer snout_core.free_table(&table)

	config := sniff.DEFAULT_SNIFF_CONFIG
	config.max_distinct_values = 3
	report, profile_err := sniff.profile_table(&table, config)
	testing.expect_value(t, profile_err, snout_core.Error.None)
	if profile_err != .None {
		return
	}
	defer sniff.free_sniff_report(&report)

	testing.expect(t, report.columns[0].cardinality.exact)
	testing.expect_value(t, report.columns[0].cardinality.distinct_count, 3)
	testing.expect_value(t, report.columns[0].role, sniff.Column_Role.Dimension)
}

@(test)
sniff_cardinality_truncates_only_on_an_unseen_value :: proc(t: ^testing.T) {
	input := "value\nalpha\nbeta\ngamma\nalpha\ndelta\n"
	table, err := ingest.read_csv_string(input, "truncated")
	testing.expect_value(t, err, snout_core.Error.None)
	if err != .None {
		return
	}
	defer snout_core.free_table(&table)

	config := sniff.DEFAULT_SNIFF_CONFIG
	config.max_distinct_values = 3
	report, profile_err := sniff.profile_table(&table, config)
	testing.expect_value(t, profile_err, snout_core.Error.None)
	if profile_err != .None {
		return
	}
	defer sniff.free_sniff_report(&report)

	testing.expect(t, !report.columns[0].cardinality.exact)
	testing.expect_value(t, report.columns[0].cardinality.lower_bound, 4)
	cardinality_warning_found := false
	for warning in report.warnings {
		if strings.contains(warning, "exceeded 3 distinct values") {
			cardinality_warning_found = true
		}
	}
	testing.expect(t, cardinality_warning_found)
}

@(test)
sniff_top_values_use_count_then_typed_value_order :: proc(t: ^testing.T) {
	input := "region\nwest\neast\nwest\neast\nnorth\n"
	table, err := ingest.read_csv_string(input, "top_values")
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

	top := report.columns[0].top_values
	testing.expect_value(t, len(top), 3)
	testing.expect_value(t, top[0].value.string_value, "east")
	testing.expect_value(t, top[0].count, 2)
	testing.expect_value(t, top[1].value.string_value, "west")
	testing.expect_value(t, top[1].count, 2)
	testing.expect_value(t, top[2].value.string_value, "north")
}

@(test)
sniff_top_values_can_be_disabled :: proc(t: ^testing.T) {
	table, err := ingest.read_csv_string("region\neu\nus\neu\n", "no_top_values")
	testing.expect_value(t, err, snout_core.Error.None)
	if err != .None {
		return
	}
	defer snout_core.free_table(&table)

	config := sniff.DEFAULT_SNIFF_CONFIG
	config.top_value_count = 0
	report, profile_err := sniff.profile_table(&table, config)
	testing.expect_value(t, profile_err, snout_core.Error.None)
	if profile_err != .None {
		return
	}
	defer sniff.free_sniff_report(&report)
	testing.expect_value(t, len(report.columns[0].top_values), 0)
}

@(test)
sniff_rejects_non_finite_float_values :: proc(t: ^testing.T) {
	table, err := ingest.read_csv_string(
		"timestamp,value\n2026-01-01T00:00:00Z,1.5\n2026-01-02T00:00:00Z,2.5\n",
		"non_finite",
	)
	testing.expect_value(t, err, snout_core.Error.None)
	if err != .None {
		return
	}
	defer snout_core.free_table(&table)
	table.columns[1].float64s[1] = math.QNAN_F64

	_, profile_err := sniff.profile_table(&table)
	testing.expect_value(t, profile_err, snout_core.Error.Non_Finite_Profile_Value)
}

@(test)
sniff_does_not_mutate_the_source_table :: proc(t: ^testing.T) {
	table, err := ingest.read_jsonl_string(
		"{\"region\":\"eu\",\"value\":1}\n{\"region\":null,\"value\":2}\n",
		"immutable",
	)
	testing.expect_value(t, err, snout_core.Error.None)
	if err != .None {
		return
	}
	defer snout_core.free_table(&table)

	original_name, _ := strings.clone(table.columns[0].name)
	defer delete(original_name)
	original_value, _ := strings.clone(table.columns[0].strings[0])
	defer delete(original_value)
	original_null := table.columns[0].null_mask[1]

	report, profile_err := sniff.profile_table(&table)
	testing.expect_value(t, profile_err, snout_core.Error.None)
	if profile_err == .None {
		sniff.free_sniff_report(&report)
	}

	testing.expect_value(t, table.row_count, 2)
	testing.expect_value(t, table.columns[0].name, original_name)
	testing.expect_value(t, table.columns[0].strings[0], original_value)
	testing.expect_value(t, table.columns[0].null_mask[1], original_null)
}

@(test)
sniff_global_budget_uses_an_observed_lower_bound :: proc(t: ^testing.T) {
	state: sniff.Column_Scan_State
	sniff.init_scan_state(&state)
	state.string_seen = make(map[string]struct{})
	defer delete(state.string_seen)
	state.string_freq = make(map[string]int)
	defer delete(state.string_freq)
	warnings := make([dynamic]string, 0)
	defer delete(warnings)
	global_entries := sniff.MAX_TOTAL_TRACKED_DISTINCT_VALUES

	sniff.track_string_value(
		&state,
		"first",
		sniff.DEFAULT_SNIFF_CONFIG,
		&global_entries,
		"value",
		&warnings,
		context.allocator,
	)

	testing.expect(t, !state.cardinality_exact)
	testing.expect_value(t, state.lower_bound, 1)
	testing.expect_value(t, len(warnings), 1)
	for warning in warnings {
		delete(warning)
	}
}
