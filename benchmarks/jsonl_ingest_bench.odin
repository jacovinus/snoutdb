package main

import "core:fmt"
import "core:os"
import "core:time"
import snout_core "../core"
import ingest "../ingest"

JSONL_BENCH_FIXTURES :: [3]string {
	"tests/fixtures/complex_metrics_500.jsonl",
	"tests/fixtures/complex_metrics_50000.jsonl",
	"tests/fixtures/complex_metrics_5000000.jsonl",
}

main :: proc() {
	paths: []string
	if len(os.args) > 1 {
		paths = os.args[1:]
	} else {
		fixtures := JSONL_BENCH_FIXTURES
		paths = fixtures[:]
	}
	for path in paths {
		info, stat_err := os.stat(path, context.temp_allocator)
		if stat_err != nil {
			fmt.eprintfln("skip %s: not found", path)
			continue
		}
		run_jsonl_scanner_benchmark(path, info.size)
		run_jsonl_inspection_benchmark(path)
		run_jsonl_table_load_benchmark(path)
		fmt.println()
	}
}

run_jsonl_scanner_benchmark :: proc(path: string, file_size: i64) {
	scanner, open_err := ingest.open_jsonl_scanner(path)
	if open_err != .None {
		fmt.eprintfln("scanner open failed for %s: %v", path, open_err)
		return
	}
	defer ingest.close_jsonl_scanner(&scanner)

	start := time.tick_now()
	rows := 0
	for {
		_, done, err := ingest.next_jsonl_line(&scanner)
		if err != .None {
			fmt.eprintfln("scan failed for %s: %v", path, err)
			return
		}
		if done {
			break
		}
		rows += 1
	}
	elapsed := time.tick_since(start)
	seconds := time.duration_seconds(elapsed)
	mib := f64(file_size) / (1024 * 1024)
	fmt.printfln(
		"scanner    %s: rows=%d bytes=%d elapsed=%v MiB/s=%.1f rows/s=%.0f",
		path,
		rows,
		file_size,
		elapsed,
		mib / seconds,
		f64(rows) / seconds,
	)
}

run_jsonl_inspection_benchmark :: proc(path: string) {
	start := time.tick_now()
	schema, err := ingest.inspect_jsonl_file(path, "bench")
	elapsed := time.tick_since(start)
	if err != .None {
		fmt.eprintfln("inspection failed for %s: %v", path, err)
		return
	}
	fmt.printfln(
		"inspect    %s: rows=%d columns=%d elapsed=%v",
		path,
		schema.row_count,
		len(schema.columns),
		elapsed,
	)
	ingest.free_jsonl_file_schema(&schema)
}

run_jsonl_table_load_benchmark :: proc(path: string) {
	inspect_start := time.tick_now()
	schema, schema_err := ingest.inspect_jsonl_file(path, "bench")
	inspect_elapsed := time.tick_since(inspect_start)
	if schema_err != .None {
		fmt.eprintfln("inspection failed for %s: %v", path, schema_err)
		return
	}
	defer ingest.free_jsonl_file_schema(&schema)

	populate_start := time.tick_now()
	table, table_err := ingest.populate_jsonl_table(path, &schema, context.allocator)
	populate_elapsed := time.tick_since(populate_start)
	if table_err != .None {
		fmt.eprintfln("population failed for %s: %v", path, table_err)
		return
	}
	fmt.printfln(
		"table load %s: rows=%d inspect=%v populate=%v total=%v",
		path,
		table.row_count,
		inspect_elapsed,
		populate_elapsed,
		inspect_elapsed + populate_elapsed,
	)
	snout_core.free_table(&table)
}
