package main

import "core:fmt"
import "core:os"
import "core:time"
import snout_core "../core"
import ingest "../ingest"
import snout_merge "../merge"
import storage "../storage"

MERGE_BENCH_FIXTURES :: [3]string {
	"tests/fixtures/complex_metrics_500.csv",
	"tests/fixtures/complex_metrics_50000.csv",
	"tests/fixtures/complex_metrics_500000.csv",
}

main :: proc() {
	paths: []string
	if len(os.args) > 1 {
		paths = os.args[1:]
	} else {
		fixtures := MERGE_BENCH_FIXTURES
		paths = fixtures[:]
	}
	for path in paths {
		if _, stat_err := os.stat(path, context.temp_allocator); stat_err != nil {
			fmt.eprintfln("skip %s: not found", path)
			continue
		}
		run_merge_benchmark(path)
		fmt.println()
	}
}

run_merge_benchmark :: proc(path: string) {
	// Load source from CSV → .snout → read back (avoids CSV parse time in merge bench)
	load_start := time.tick_now()
	table, load_err := ingest.read_csv_table(path, "bench")
	load_elapsed := time.tick_since(load_start)
	if load_err != .None {
		fmt.eprintfln("load failed for %s: %v", path, load_err)
		return
	}
	defer snout_core.free_table(&table)

	tmp_path := fmt.aprintf("%s.bench.snout", path, allocator = context.temp_allocator)
	if w_err := storage.write_snout_file(tmp_path, &table); w_err != .None {
		fmt.eprintfln("write failed: %v", w_err)
		return
	}
	defer os.remove(tmp_path)

	src, read_err := storage.read_snout_file(tmp_path)
	if read_err != .None {
		fmt.eprintfln("read failed: %v", read_err)
		return
	}
	defer snout_core.free_table(&src)

	fmt.printfln(
		"load+write+read %s: rows=%d cols=%d elapsed=%v",
		path,
		src.row_count,
		len(src.columns),
		load_elapsed,
	)

	// Benchmark: self-append (doubles the table)
	append_start := time.tick_now()
	merged, merge_err := snout_merge.append_tables(&src, []^snout_core.Table{&src})
	append_elapsed := time.tick_since(append_start)
	if merge_err != .None {
		fmt.eprintfln("append failed: %v", merge_err)
		return
	}
	defer snout_core.free_table(&merged)
	fmt.printfln(
		"append (self×2)  %s: rows=%d elapsed=%v",
		path,
		merged.row_count,
		append_elapsed,
	)

	// Benchmark: compact
	compact_start := time.tick_now()
	compacted, compact_err := snout_merge.compact_table(&src)
	compact_elapsed := time.tick_since(compact_start)
	if compact_err != .None {
		fmt.eprintfln("compact failed: %v", compact_err)
		return
	}
	defer snout_core.free_table(&compacted)
	fmt.printfln(
		"compact          %s: rows=%d elapsed=%v",
		path,
		compacted.row_count,
		compact_elapsed,
	)

	// Benchmark: write merged result
	out_path := fmt.aprintf("%s.bench_merged.snout", path, allocator = context.temp_allocator)
	write_start := time.tick_now()
	write_err := storage.write_snout_file(out_path, &merged)
	write_elapsed := time.tick_since(write_start)
	defer os.remove(out_path)
	if write_err != .None {
		fmt.eprintfln("write merged failed: %v", write_err)
		return
	}
	fmt.printfln(
		"write merged     %s: rows=%d elapsed=%v",
		path,
		merged.row_count,
		write_elapsed,
	)
}
