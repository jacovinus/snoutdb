package tests

import "core:io"
import "core:os"
import "core:testing"
import snout_core "../core"
import ingest "../ingest"
import result_output "../output"
import sniff "../sniff"

@(test)
sniff_writes_to_stdout :: proc(t: ^testing.T) {
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

	stdout, writer_ok := io.to_writer(os.to_stream(os.stdout))
	testing.expect(t, writer_ok)
	write_err := result_output.write_sniff_report(
		stdout,
		&report,
		"tests/fixtures/simple_metrics.csv",
		result_output.Sniff_Output_Format.Table,
	)
	testing.expect_value(t, write_err, snout_core.Error.None)
}
