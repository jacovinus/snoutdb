package tests

import "core:testing"
import snout_core "../core"
import sniff "../sniff"

profile_for_role :: proc(
	name: string,
	kind: snout_core.Column_Type,
	non_null_count: int,
	distinct_count: int,
) -> sniff.Column_Profile {
	return sniff.Column_Profile{
		name = name,
		kind = kind,
		non_null_count = non_null_count,
		cardinality = {
			exact = true,
			distinct_count = distinct_count,
		},
		numeric = {
			valid = kind == .Int64 || kind == .Float64,
			kind = kind,
		},
	}
}

@(test)
sniff_identifier_requires_name_evidence_and_uniqueness :: proc(t: ^testing.T) {
	call_id := profile_for_role("call_id", .String, 100, 100)
	sniff.classify_column_role(&call_id)
	testing.expect_value(t, call_id.role, sniff.Column_Role.Identifier)

	message := profile_for_role("message", .String, 100, 100)
	sniff.classify_column_role(&message)
	testing.expect_value(t, message.role, sniff.Column_Role.Unknown)

	customer_id := profile_for_role("customer_id", .String, 100, 4)
	sniff.classify_column_role(&customer_id)
	testing.expect_value(t, customer_id.role, sniff.Column_Role.Dimension)
}

@(test)
sniff_classifies_bool_and_low_cardinality_numeric_dimensions :: proc(t: ^testing.T) {
	active := profile_for_role("active", .Bool, 100, 2)
	sniff.classify_column_role(&active)
	testing.expect_value(t, active.role, sniff.Column_Role.Dimension)

	status := profile_for_role("status", .Int64, 100, 3)
	sniff.classify_column_role(&status)
	testing.expect_value(t, status.role, sniff.Column_Role.Dimension)
}

@(test)
sniff_classifies_remaining_numeric_columns_as_metrics :: proc(t: ^testing.T) {
	duration := profile_for_role("duration", .Int64, 100, 100)
	sniff.classify_column_role(&duration)
	testing.expect_value(t, duration.role, sniff.Column_Role.Metric)

	mos := profile_for_role("mos", .Float64, 100, 5)
	sniff.classify_column_role(&mos)
	testing.expect_value(t, mos.role, sniff.Column_Role.Metric)
}

@(test)
sniff_classifies_empty_and_unknown_columns_as_unknown :: proc(t: ^testing.T) {
	empty := profile_for_role("empty", .String, 0, 0)
	sniff.classify_column_role(&empty)
	testing.expect_value(t, empty.role, sniff.Column_Role.Unknown)
	testing.expect_value(t, empty.role_reason, "all values are null")

	unknown := profile_for_role("value", .Unknown, 10, 1)
	sniff.classify_column_role(&unknown)
	testing.expect_value(t, unknown.role, sniff.Column_Role.Unknown)
	testing.expect_value(t, unknown.role_reason, "unknown source type")
}

@(test)
sniff_dimension_and_metric_ranking_are_deterministic :: proc(t: ^testing.T) {
	columns := []sniff.Column_Profile{
		{
			name = "carrier",
			role = .Dimension,
			null_ratio = 0,
			cardinality = {exact = true, distinct_count = 5},
			source_index = 0,
		},
		{
			name = "region",
			role = .Dimension,
			null_ratio = 0.1,
			cardinality = {exact = true, distinct_count = 3},
			source_index = 1,
		},
		{
			name = "mos",
			role = .Metric,
			non_null_count = 10,
			source_index = 2,
		},
		{
			name = "jitter_ms",
			role = .Metric,
			non_null_count = 10,
			source_index = 3,
		},
		{
			name = "other",
			role = .Metric,
			non_null_count = 10,
			source_index = 4,
		},
	}

	dimensions := sniff.rank_dimensions(columns)
	metrics := sniff.rank_metrics(columns)
	testing.expect_value(t, dimensions[0].name, "region")
	testing.expect_value(t, dimensions[1].name, "carrier")
	testing.expect_value(t, metrics[0].name, "mos")
	testing.expect_value(t, metrics[1].name, "jitter_ms")
	testing.expect_value(t, metrics[2].name, "other")
}
