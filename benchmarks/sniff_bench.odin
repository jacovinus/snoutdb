package main

import "core:fmt"
import "core:strings"
import "core:time"
import snout_core "../core"
import ingest "../ingest"
import sniff "../sniff"

main :: proc() {
	small, small_err := ingest.read_csv_table(
		"tests/fixtures/complex_metrics_500.csv",
		"small_telemetry",
	)
	if small_err == .None {
		run_sniff_benchmark(
			"small telemetry",
			&small,
			sniff.DEFAULT_SNIFF_CONFIG,
		)
		snout_core.free_table(&small)
	}

	low_cardinality := make_low_cardinality_table(100_000)
	run_sniff_benchmark(
		"medium low cardinality",
		&low_cardinality,
		sniff.DEFAULT_SNIFF_CONFIG,
	)
	snout_core.free_table(&low_cardinality)

	unique_identifier := make_identifier_table(100_000)
	identifier_config := sniff.DEFAULT_SNIFF_CONFIG
	identifier_config.max_distinct_values = 100_000
	run_sniff_benchmark(
		"medium unique identifier",
		&unique_identifier,
		identifier_config,
	)
	snout_core.free_table(&unique_identifier)

	truncated := make_identifier_table(100_000)
	truncated_config := sniff.DEFAULT_SNIFF_CONFIG
	truncated_config.max_distinct_values = 1_000
	run_sniff_benchmark(
		"cardinality truncation",
		&truncated,
		truncated_config,
	)
	snout_core.free_table(&truncated)
}

run_sniff_benchmark :: proc(
	label: string,
	table: ^snout_core.Table,
	config: sniff.Sniff_Config,
) {
	start := time.tick_now()
	report, err := sniff.profile_table(table, config)
	elapsed := time.tick_since(start)
	if err != .None {
		fmt.printfln("%s: error=%v", label, err)
		return
	}
	defer sniff.free_sniff_report(&report)

	fmt.printfln(
		"%s: rows=%d columns=%d max_distinct=%d elapsed=%v",
		label,
		table.row_count,
		len(table.columns),
		config.max_distinct_values,
		elapsed,
	)
}

make_low_cardinality_table :: proc(row_count: int) -> snout_core.Table {
	table := make_benchmark_table("low_cardinality", row_count, 10)
	for column_index in 0..<2 {
		column := &table.columns[column_index]
		column.name = benchmark_clone(fmt.tprintf("dimension_%d", column_index))
		column.kind = .String
		column.strings, _ = make([]string, row_count)
		column.null_mask, _ = make([]bool, row_count)
		for row_index in 0..<row_count {
			column.strings[row_index] = benchmark_clone(
				fmt.tprintf("value_%02d", (row_index+column_index)%20),
			)
		}
	}
	for column_index in 2..<10 {
		column := &table.columns[column_index]
		column.name = benchmark_clone(fmt.tprintf("metric_%d", column_index-2))
		column.kind = .Int64
		column.int64s, _ = make([]i64, row_count)
		column.null_mask, _ = make([]bool, row_count)
		for row_index in 0..<row_count {
			column.int64s[row_index] = i64(row_index*(column_index+1))
		}
	}
	return table
}

make_identifier_table :: proc(row_count: int) -> snout_core.Table {
	table := make_benchmark_table("unique_identifier", row_count, 2)
	id := &table.columns[0]
	id.name = benchmark_clone("event_id")
	id.kind = .String
	id.strings, _ = make([]string, row_count)
	id.null_mask, _ = make([]bool, row_count)
	for row_index in 0..<row_count {
		id.strings[row_index] = benchmark_clone(fmt.tprintf("event-%06d", row_index))
	}

	value := &table.columns[1]
	value.name = benchmark_clone("latency_ms")
	value.kind = .Int64
	value.int64s, _ = make([]i64, row_count)
	value.null_mask, _ = make([]bool, row_count)
	for row_index in 0..<row_count {
		value.int64s[row_index] = i64(row_index%10_000)
	}
	return table
}

make_benchmark_table :: proc(
	name: string,
	row_count: int,
	column_count: int,
) -> snout_core.Table {
	table := snout_core.Table{
		name = benchmark_clone(name),
		row_count = row_count,
		allocator = context.allocator,
	}
	table.columns, _ = make([]snout_core.Column, column_count)
	return table
}

benchmark_clone :: proc(value: string) -> string {
	result, _ := strings.clone(value)
	return result
}
