package tests

import "core:testing"
import snout_core "../core"
import ingest "../ingest"
import sniff "../sniff"

@(test)
sniff_profiles_simple_metrics :: proc(t: ^testing.T) {
	table, err := ingest.read_csv_table("tests/fixtures/simple_metrics.csv", "simple_metrics")
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

	testing.expect_value(t, report.row_count, 5)
	testing.expect_value(t, report.column_count, 5)
}
