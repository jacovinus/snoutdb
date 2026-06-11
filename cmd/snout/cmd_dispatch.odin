package main

import "core:fmt"
import "core:os"
import "core:strings"
import snout_core "../../core"
import aggregate "../../exec"
import ingest "../../ingest"
import snout_merge "../../merge"
import xform "../../transform"
import query "../../query"
import storage "../../storage"

run_csv_info :: proc() {
	if len(os.args) != 3 {
		print_usage()
		os.exit(1)
	}
	table := load_csv_or_exit(os.args[2])
	defer snout_core.free_table(&table)
	print_table_info(&table)
}

run_csv_avg :: proc() {
	if len(os.args) != 4 {
		print_usage()
		os.exit(1)
	}
	table := load_csv_or_exit(os.args[2])
	defer snout_core.free_table(&table)
	column_name := os.args[3]
	average, avg_err := aggregate.avg_f64_or_i64(&table, column_name)
	if avg_err != .None {
		fmt.eprintfln("error: %s", snout_core.error_message(avg_err))
		os.exit(1)
	}
	fmt.printfln("avg(%s): %.1f", column_name, average)
}

run_csv_stats :: proc() {
	if len(os.args) != 4 {
		print_usage()
		os.exit(1)
	}
	table := load_csv_or_exit(os.args[2])
	defer snout_core.free_table(&table)
	column_name := os.args[3]
	stats, stats_err := aggregate.numeric_stats(&table, column_name)
	if stats_err != .None {
		fmt.eprintfln("error: %s", snout_core.error_message(stats_err))
		os.exit(1)
	}
	print_numeric_stats(column_name, stats)
}

run_csv_import :: proc() {
	if len(os.args) != 4 {
		print_usage()
		os.exit(1)
	}
	table := load_csv_or_exit(os.args[2])
	defer snout_core.free_table(&table)
	dest := os.args[3]
	if write_err := storage.write_snout_file(dest, &table); write_err != .None {
		fmt.eprintfln("error: %s", snout_core.error_message(write_err))
		os.exit(1)
	}
	print_written(dest, &table)
}

run_jsonl_info :: proc() {
	if len(os.args) != 3 {
		print_usage()
		os.exit(1)
	}
	table := load_jsonl_or_exit(os.args[2])
	defer snout_core.free_table(&table)
	print_table_info(&table)
}

run_jsonl_stats :: proc() {
	if len(os.args) != 4 {
		print_usage()
		os.exit(1)
	}
	table := load_jsonl_or_exit(os.args[2])
	defer snout_core.free_table(&table)
	column_name := os.args[3]
	stats, stats_err := aggregate.numeric_stats(&table, column_name)
	if stats_err != .None {
		fmt.eprintfln("error: %s", snout_core.error_message(stats_err))
		os.exit(1)
	}
	print_numeric_stats(column_name, stats)
}

run_jsonl_import :: proc() {
	if len(os.args) != 4 {
		print_usage()
		os.exit(1)
	}
	table := load_jsonl_or_exit(os.args[2])
	defer snout_core.free_table(&table)
	dest := os.args[3]
	if write_err := storage.write_snout_file(dest, &table); write_err != .None {
		fmt.eprintfln("error: %s", snout_core.error_message(write_err))
		os.exit(1)
	}
	print_written(dest, &table)
}

run_info :: proc() {
	if len(os.args) != 3 {
		print_usage()
		os.exit(1)
	}
	table := load_snout_or_exit(os.args[2])
	defer snout_core.free_table(&table)
	print_table_info(&table)
}

run_stats :: proc() {
	if len(os.args) != 4 {
		print_usage()
		os.exit(1)
	}
	table := load_snout_or_exit(os.args[2])
	defer snout_core.free_table(&table)
	column_name := os.args[3]
	stats, stats_err := aggregate.numeric_stats(&table, column_name)
	if stats_err != .None {
		fmt.eprintfln("error: %s", snout_core.error_message(stats_err))
		os.exit(1)
	}
	print_numeric_stats(column_name, stats)
}

run_append :: proc() {
	if len(os.args) < 5 {
		fmt.eprintln("usage: snout append <base.snout> <extra.snout> [<extra2.snout>...] <output.snout>")
		os.exit(1)
	}
	output_path := os.args[len(os.args)-1]
	base := load_snout_or_exit(os.args[2])
	defer snout_core.free_table(&base)
	extra_paths := os.args[3:len(os.args)-1]
	extras := make([]snout_core.Table, len(extra_paths), context.temp_allocator)
	for path, i in extra_paths {
		extras[i] = load_snout_or_exit(path)
	}
	defer for &t in extras { snout_core.free_table(&t) }
	extra_ptrs := make([]^snout_core.Table, len(extras), context.temp_allocator)
	for &t, i in extras {
		extra_ptrs[i] = &t
	}
	merged, merge_err := snout_merge.append_tables(&base, extra_ptrs)
	if merge_err != .None {
		fmt.eprintfln("error: %s", snout_core.error_message(merge_err))
		os.exit(1)
	}
	defer snout_core.free_table(&merged)
	if write_err := storage.write_snout_file(output_path, &merged); write_err != .None {
		fmt.eprintfln("error: %s", snout_core.error_message(write_err))
		os.exit(1)
	}
	print_written(output_path, &merged)
}

run_consolidate :: proc() {
	if len(os.args) < 5 {
		fmt.eprintln("usage: snout consolidate <a.snout> <b.snout> [<c.snout>...] <output.snout>")
		os.exit(1)
	}
	output_path  := os.args[len(os.args)-1]
	source_paths := os.args[2:len(os.args)-1]
	tables := make([]snout_core.Table, len(source_paths), context.temp_allocator)
	for path, i in source_paths {
		tables[i] = load_snout_or_exit(path)
	}
	defer for &t in tables { snout_core.free_table(&t) }
	extra_ptrs := make([]^snout_core.Table, len(tables)-1, context.temp_allocator)
	for i in 0..<len(tables)-1 {
		extra_ptrs[i] = &tables[i+1]
	}
	merged, merge_err := snout_merge.append_tables(&tables[0], extra_ptrs)
	if merge_err != .None {
		fmt.eprintfln("error: %s", snout_core.error_message(merge_err))
		os.exit(1)
	}
	defer snout_core.free_table(&merged)
	if write_err := storage.write_snout_file(output_path, &merged); write_err != .None {
		fmt.eprintfln("error: %s", snout_core.error_message(write_err))
		os.exit(1)
	}
	print_written(output_path, &merged)
}

run_compact :: proc() {
	if len(os.args) != 4 {
		fmt.eprintln("usage: snout compact <input.snout> <output.snout>")
		os.exit(1)
	}
	table := load_snout_or_exit(os.args[2])
	defer snout_core.free_table(&table)
	output_path := os.args[3]
	compacted, compact_err := snout_merge.compact_table(&table)
	if compact_err != .None {
		fmt.eprintfln("error: %s", snout_core.error_message(compact_err))
		os.exit(1)
	}
	defer snout_core.free_table(&compacted)
	if write_err := storage.write_snout_file(output_path, &compacted); write_err != .None {
		fmt.eprintfln("error: %s", snout_core.error_message(write_err))
		os.exit(1)
	}
	print_written(output_path, &compacted)
}

run_transform :: proc() {
	if len(os.args) < 5 {
		fmt.eprintln("usage: snout transform <input> <output.snout> op=args [op=args ...]")
		fmt.eprintln("  ops: rename=from:to  drop=col  cast=col:type")
		fmt.eprintln("       derive=out:expr  bucket=col:edges:labels:out")
		fmt.eprintln("       date_trunc=col:unit[:out]  regex_extract=col:pat:N:out")
		fmt.eprintln("       json_extract=col:key:out")
		os.exit(1)
	}
	input_path  := os.args[2]
	output_path := os.args[3]
	table := load_table_or_exit(input_path)
	defer snout_core.free_table(&table)

	ops := make([dynamic]xform.Transform_Op, 0, allocator = context.temp_allocator)
	for _, i in os.args[4:] {
		arg := os.args[4+i]
		op, op_ok := xform.parse_transform_op(arg)
		if !op_ok {
			fmt.eprintfln("error: invalid transform expression %q", arg)
			os.exit(1)
		}
		append(&ops, op)
	}

	result, xform_err := xform.apply_transforms(&table, ops[:])
	if xform_err != .None {
		fmt.eprintfln("error: %s", snout_core.error_message(xform_err))
		os.exit(1)
	}
	defer snout_core.free_table(&result)
	if write_err := storage.write_snout_file(output_path, &result); write_err != .None {
		fmt.eprintfln("error: %s", snout_core.error_message(write_err))
		os.exit(1)
	}
	print_written(output_path, &result)
}

run_rollup :: proc() {
	args := os.args[2:]
	group_pos := -1
	for arg, i in args {
		if strings.has_prefix(arg, "group=") {
			group_pos = i
			break
		}
	}
	if group_pos < 2 {
		fmt.eprintln("usage: snout rollup <src1.snout> [src2.snout...] <output.snout> group=col,col -- agg=col ...")
		os.exit(1)
	}
	positional   := args[:group_pos]
	output_path  := positional[len(positional)-1]
	source_paths := positional[:len(positional)-1]

	group_text := args[group_pos][len("group="):]
	if len(group_text) == 0 {
		fmt.eprintln("error: expected group=<column>[,<column>...]")
		os.exit(1)
	}
	group_columns := strings.split(group_text, ",", context.temp_allocator)
	if len(group_columns) == 0 || len(group_columns) > query.MAX_GROUP_COLUMNS {
		fmt.eprintln("error: invalid group column list")
		os.exit(1)
	}
	for col_name in group_columns {
		if col_name == "" {
			fmt.eprintln("error: group columns cannot be empty")
			os.exit(1)
		}
	}

	cursor := group_pos + 1
	if cursor >= len(args) || args[cursor] != "--" {
		fmt.eprintln("error: expected -- before aggregate expressions")
		os.exit(1)
	}
	cursor += 1

	aggs := make([dynamic]query.Aggregate_Spec, 0, allocator = context.temp_allocator)
	for cursor < len(args) {
		expression := args[cursor]
		sep := strings.index_byte(expression, '=')
		if sep <= 0 || sep == len(expression)-1 {
			fmt.eprintfln("error: invalid aggregate expression %q", expression)
			os.exit(1)
		}
		agg_text := expression[:sep]
		agg_col  := expression[sep+1:]
		spec_partial, agg_ok := query.parse_aggregate_spec_kind(agg_text)
		if !agg_ok {
			fmt.eprintfln("error: invalid aggregate %q", agg_text)
			os.exit(1)
		}
		if spec_partial.kind == .Count && agg_col == "rows" {
			agg_col = "*"
		}
		if agg_col == "*" && spec_partial.kind != .Count {
			fmt.eprintfln("error: only count=rows accepts a row wildcard")
			os.exit(1)
		}
		append(&aggs, query.Aggregate_Spec{
			kind        = spec_partial.kind,
			column_name = agg_col,
			percentile  = spec_partial.percentile,
		})
		cursor += 1
	}
	if len(aggs) == 0 || len(aggs) > query.MAX_AGGREGATES {
		fmt.eprintln("error: at least one aggregate expression is required")
		os.exit(1)
	}

	tables := make([]snout_core.Table, len(source_paths), context.temp_allocator)
	for path, i in source_paths {
		tables[i] = load_snout_or_exit(path)
	}
	defer for &t in tables { snout_core.free_table(&t) }
	ptrs := make([]^snout_core.Table, len(tables), context.temp_allocator)
	for &t, i in tables {
		ptrs[i] = &t
	}

	rollup_name := table_name_from_path(output_path, ".snout")
	result, rollup_err := snout_merge.rollup_tables(ptrs, rollup_name, query.Group_Query{
		group_columns = group_columns,
		aggregates    = aggs[:],
	})
	if rollup_err != .None {
		fmt.eprintfln("error: %s", snout_core.error_message(rollup_err))
		os.exit(1)
	}
	defer snout_core.free_table(&result)
	if write_err := storage.write_snout_file(output_path, &result); write_err != .None {
		fmt.eprintfln("error: %s", snout_core.error_message(write_err))
		os.exit(1)
	}
	print_written(output_path, &result)
}

run_log_info :: proc() {
	if len(os.args) < 3 {
		fmt.eprintln("usage: snout log-info <file.log> [--format clf|combined|logfmt|syslog|regex] [--pattern \"...\"] [--strict]")
		os.exit(1)
	}
	path   := os.args[2]
	opts   := parse_log_opts(os.args[3:])
	name   := table_name_from_path(path, log_ext_suffix(path))
	schema, err := ingest.inspect_log_file(path, name, opts)
	if err != .None {
		fmt.eprintfln("error: %s", snout_core.error_message(err))
		os.exit(1)
	}
	defer ingest.free_log_file_schema(&schema)
	fmt.printfln("table: %s", schema.table_name)
	fmt.printfln("rows: %d", schema.row_count)
	fmt.printfln("parse_errors: %d", schema.parse_errors)
	fmt.printfln("columns:")
	for col in schema.columns {
		nullable_str := "nullable=true" if col.nullable else "nullable=false"
		fmt.printfln("  %-20s %-10s %s", col.name, snout_core.column_type_name(col.kind), nullable_str)
	}
}

run_log_import :: proc() {
	if len(os.args) < 4 {
		fmt.eprintln("usage: snout log-import <file.log> <out.snout> [--format clf|combined|logfmt|syslog|regex] [--pattern \"...\"] [--strict]")
		os.exit(1)
	}
	path := os.args[2]
	dest := os.args[3]
	opts := parse_log_opts(os.args[4:])
	name := table_name_from_path(path, log_ext_suffix(path))
	table, err := ingest.read_log_table(path, name, opts)
	if err != .None {
		fmt.eprintfln("error: %s", snout_core.error_message(err))
		os.exit(1)
	}
	defer snout_core.free_table(&table)
	if write_err := storage.write_snout_file(dest, &table); write_err != .None {
		fmt.eprintfln("error: %s", snout_core.error_message(write_err))
		os.exit(1)
	}
	print_written(dest, &table)
}
