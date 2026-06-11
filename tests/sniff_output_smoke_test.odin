package tests

import "core:testing"
import snout_core "../core"
import ingest "../ingest"
import result_output "../output"
import sniff "../sniff"

@(test)
sniff_writes_table_output :: proc(t: ^testing.T) {
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

	rendered, render_err := result_output.render_sniff_report(
		&report,
		"tests/fixtures/simple_metrics.csv",
		result_output.Sniff_Output_Format.Table,
	)
	testing.expect_value(t, render_err, snout_core.Error.None)
	if render_err != .None {
		return
	}
	defer delete(rendered)
	testing.expect(t, len(rendered) > 0)
}
