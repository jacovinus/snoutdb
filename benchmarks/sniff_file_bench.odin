package main

import "core:fmt"
import "core:os"
import "core:time"
import ingest "../ingest"
import sniff "../sniff"

SNIFF_BENCH_FIXTURES :: [3]string {
	"tests/fixtures/complex_metrics_500.csv",
	"tests/fixtures/complex_metrics_50000.csv",
	"tests/fixtures/complex_metrics_5000000.csv",
}

main :: proc() {
	paths: []string
	if len(os.args) > 1 {
		paths = os.args[1:]
	} else {
		fixtures := SNIFF_BENCH_FIXTURES
		paths = fixtures[:]
	}
	for path in paths {
		if _, stat_err := os.stat(path, context.temp_allocator); stat_err != nil {
			fmt.eprintfln("skip %s: not found", path)
			continue
		}
		run_direct_sniff_benchmark(path, sniff.DEFAULT_SNIFF_CONFIG, "default")

		reduced := sniff.DEFAULT_SNIFF_CONFIG
		reduced.top_value_count = 0
		reduced.max_suggestions = 0
		run_direct_sniff_benchmark(path, reduced, "reduced")
		fmt.println()
	}
}

run_direct_sniff_benchmark :: proc(
	path: string,
	config: sniff.Sniff_Config,
	label: string,
) {
	inspect_start := time.tick_now()
	schema, schema_err := ingest.inspect_csv_file(path, "bench")
	inspect_elapsed := time.tick_since(inspect_start)
	if schema_err != .None {
		fmt.eprintfln("inspection failed for %s: %v", path, schema_err)
		return
	}
	ingest.free_csv_file_schema(&schema)

	total_start := time.tick_now()
	report, err := sniff.profile_csv_file(path, "bench", config)
	total_elapsed := time.tick_since(total_start)
	if err != .None {
		fmt.eprintfln("direct sniff failed for %s: %v", path, err)
		return
	}
	fmt.printfln(
		"direct sniff (%s) %s: rows=%d columns=%d inspect=%v profile=%v total=%v",
		label,
		path,
		report.row_count,
		report.column_count,
		inspect_elapsed,
		total_elapsed - inspect_elapsed,
		total_elapsed,
	)
	sniff.free_sniff_report(&report)
}
