package main

import "core:fmt"
import "core:time"
import snout_core "../../core"
import aggregate "../../exec"

print_processing_time :: proc(start: time.Tick) {
	fmt.eprintfln("Elapsed: %v.", time.tick_since(start))
}

print_table_info :: proc(table: ^snout_core.Table) {
	fmt.printfln("table: %s", table.name)
	fmt.printfln("rows: %d", table.row_count)
	fmt.println("columns:")
	for column in table.columns {
		fmt.printfln(
			"  %-12s %-9s nullable=%v",
			column.name,
			snout_core.column_type_name(column.kind),
			column.nullable,
		)
	}
}

print_numeric_stats :: proc(column_name: string, stats: aggregate.Numeric_Stats) {
	fmt.printfln("column: %s", column_name)
	fmt.printfln("type: %s", snout_core.column_type_name(stats.kind))
	fmt.printfln("count: %d", stats.count)
	fmt.printfln("nulls: %d", stats.null_count)
	if stats.kind == .Int64 {
		fmt.printfln("sum: %.0f", stats.sum)
		fmt.printfln("avg: %.2f", stats.avg)
		fmt.printfln("min: %.0f", stats.min)
		fmt.printfln("max: %.0f", stats.max)
		fmt.printfln("p50: %.0f", stats.p50)
		fmt.printfln("p95: %.0f", stats.p95)
		fmt.printfln("p99: %.0f", stats.p99)
	} else {
		fmt.printfln("sum: %.6f", stats.sum)
		fmt.printfln("avg: %.6f", stats.avg)
		fmt.printfln("min: %.6f", stats.min)
		fmt.printfln("max: %.6f", stats.max)
		fmt.printfln("p50: %.6f", stats.p50)
		fmt.printfln("p95: %.6f", stats.p95)
		fmt.printfln("p99: %.6f", stats.p99)
	}
}

print_written :: proc(path: string, table: ^snout_core.Table) {
	fmt.printfln("written: %s", path)
	fmt.printfln("table: %s", table.name)
	fmt.printfln("rows: %d", table.row_count)
	fmt.printfln("columns: %d", len(table.columns))
}
