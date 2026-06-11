package tests

import "core:os"
import "core:strings"
import "core:testing"
import snout_core "../core"
import snout_merge "../merge"
import query "../query"
import storage "../storage"

// ---- helpers ----------------------------------------------------------------

@(private = "file")
make_str_col :: proc(
	name: string,
	values: []string,
	allocator := context.allocator,
) -> snout_core.Column {
	col: snout_core.Column
	col.name = strings.clone(name, allocator)
	col.kind = .String
	col.nullable = false
	col.null_mask, _ = make([]bool, len(values), allocator)
	col.strings, _ = make([]string, len(values), allocator)
	for v, i in values {
		col.strings[i] = strings.clone(v, allocator)
	}
	return col
}

@(private = "file")
make_i64_col :: proc(
	name: string,
	values: []i64,
	allocator := context.allocator,
) -> snout_core.Column {
	col: snout_core.Column
	col.name = strings.clone(name, allocator)
	col.kind = .Int64
	col.nullable = false
	col.null_mask, _ = make([]bool, len(values), allocator)
	col.int64s, _ = make([]i64, len(values), allocator)
	copy(col.int64s, values)
	return col
}

@(private = "file")
make_f64_col :: proc(
	name: string,
	values: []f64,
	allocator := context.allocator,
) -> snout_core.Column {
	col: snout_core.Column
	col.name = strings.clone(name, allocator)
	col.kind = .Float64
	col.nullable = false
	col.null_mask, _ = make([]bool, len(values), allocator)
	col.float64s, _ = make([]f64, len(values), allocator)
	copy(col.float64s, values)
	return col
}

@(private = "file")
make_b_col :: proc(
	name: string,
	values: []bool,
	allocator := context.allocator,
) -> snout_core.Column {
	col: snout_core.Column
	col.name = strings.clone(name, allocator)
	col.kind = .Bool
	col.nullable = false
	col.null_mask, _ = make([]bool, len(values), allocator)
	col.bools, _ = make([]bool, len(values), allocator)
	copy(col.bools, values)
	return col
}

@(private = "file")
build_table :: proc(name: string, cols: []snout_core.Column) -> snout_core.Table {
	t: snout_core.Table
	t.allocator = context.allocator
	t.row_count = len(cols[0].null_mask)
	t.name, _ = strings.clone(name)
	t.columns, _ = make([]snout_core.Column, len(cols))
	copy(t.columns, cols)
	return t
}

// ---- tests ------------------------------------------------------------------

@(test)
rollup_count_per_group :: proc(t: ^testing.T) {
	src := build_table("events", {
		make_str_col("region", {"us", "eu", "us", "eu", "ap", "ap"}),
		make_i64_col("latency", {10, 20, 30, 40, 50, 60}),
	})
	defer snout_core.free_table(&src)

	gq := query.Group_Query{
		group_columns = {"region"},
		aggregates    = {query.Aggregate_Spec{kind = .Count, column_name = "*"}},
	}
	result, err := snout_merge.rollup_tables([]^snout_core.Table{&src}, "out", gq)
	testing.expect(t, err == .None, "rollup_tables should succeed")
	defer snout_core.free_table(&result)

	testing.expect_value(t, result.row_count, 3)
	testing.expect_value(t, len(result.columns), 2)
	testing.expect_value(t, result.columns[0].name, "region")
	testing.expect_value(t, result.columns[1].name, "count")
	// Groups sorted: ap, eu, us
	testing.expect_value(t, result.columns[0].strings[0], "ap")
	testing.expect_value(t, result.columns[0].strings[1], "eu")
	testing.expect_value(t, result.columns[0].strings[2], "us")
	testing.expect_value(t, result.columns[1].int64s[0], i64(2))
	testing.expect_value(t, result.columns[1].int64s[1], i64(2))
	testing.expect_value(t, result.columns[1].int64s[2], i64(2))
}

@(test)
rollup_sum_and_avg :: proc(t: ^testing.T) {
	src := build_table("t", {
		make_str_col("region", {"us", "eu", "us"}),
		make_i64_col("val", {10, 20, 30}),
	})
	defer snout_core.free_table(&src)

	gq := query.Group_Query{
		group_columns = {"region"},
		aggregates = {
			query.Aggregate_Spec{kind = .Sum, column_name = "val"},
			query.Aggregate_Spec{kind = .Avg, column_name = "val"},
		},
	}
	result, err := snout_merge.rollup_tables([]^snout_core.Table{&src}, "out", gq)
	testing.expect(t, err == .None)
	defer snout_core.free_table(&result)

	testing.expect_value(t, result.row_count, 2)
	// eu: sum=20, avg=20.0
	testing.expect_value(t, result.columns[1].int64s[0], i64(20))
	testing.expect_value(t, result.columns[2].float64s[0], f64(20.0))
	// us: sum=40, avg=20.0
	testing.expect_value(t, result.columns[1].int64s[1], i64(40))
	testing.expect_value(t, result.columns[2].float64s[1], f64(20.0))
}

@(test)
rollup_merges_two_sources_before_aggregating :: proc(t: ^testing.T) {
	src_a := build_table("a", {
		make_str_col("region", {"us", "eu"}),
		make_i64_col("val", {10, 20}),
	})
	defer snout_core.free_table(&src_a)

	src_b := build_table("b", {
		make_str_col("region", {"us", "ap"}),
		make_i64_col("val", {30, 40}),
	})
	defer snout_core.free_table(&src_b)

	gq := query.Group_Query{
		group_columns = {"region"},
		aggregates    = {query.Aggregate_Spec{kind = .Sum, column_name = "val"}},
	}
	result, err := snout_merge.rollup_tables([]^snout_core.Table{&src_a, &src_b}, "out", gq)
	testing.expect(t, err == .None)
	defer snout_core.free_table(&result)

	// ap:40, eu:20, us:40
	testing.expect_value(t, result.row_count, 3)
	testing.expect_value(t, result.columns[0].strings[0], "ap")
	testing.expect_value(t, result.columns[1].int64s[0], i64(40))
	testing.expect_value(t, result.columns[0].strings[1], "eu")
	testing.expect_value(t, result.columns[1].int64s[1], i64(20))
	testing.expect_value(t, result.columns[0].strings[2], "us")
	testing.expect_value(t, result.columns[1].int64s[2], i64(40))
}

@(test)
rollup_int64_group_key :: proc(t: ^testing.T) {
	src := build_table("t", {
		make_i64_col("id", {1, 2, 1, 2}),
		make_i64_col("v", {10, 20, 30, 40}),
	})
	defer snout_core.free_table(&src)

	gq := query.Group_Query{
		group_columns = {"id"},
		aggregates    = {query.Aggregate_Spec{kind = .Sum, column_name = "v"}},
	}
	result, err := snout_merge.rollup_tables([]^snout_core.Table{&src}, "out", gq)
	testing.expect(t, err == .None)
	defer snout_core.free_table(&result)

	testing.expect_value(t, result.row_count, 2)
	testing.expect_value(t, result.columns[0].kind, snout_core.Column_Type.Int64)
	testing.expect_value(t, result.columns[0].int64s[0], i64(1))
	testing.expect_value(t, result.columns[0].int64s[1], i64(2))
	testing.expect_value(t, result.columns[1].int64s[0], i64(40))
	testing.expect_value(t, result.columns[1].int64s[1], i64(60))
}

@(test)
rollup_bool_group_key :: proc(t: ^testing.T) {
	src := build_table("t", {
		make_b_col("ok", {true, false, true, false, true}),
		make_i64_col("v", {1, 2, 3, 4, 5}),
	})
	defer snout_core.free_table(&src)

	gq := query.Group_Query{
		group_columns = {"ok"},
		aggregates    = {query.Aggregate_Spec{kind = .Count, column_name = "*"}},
	}
	result, err := snout_merge.rollup_tables([]^snout_core.Table{&src}, "out", gq)
	testing.expect(t, err == .None)
	defer snout_core.free_table(&result)

	testing.expect_value(t, result.row_count, 2)
	testing.expect_value(t, result.columns[0].kind, snout_core.Column_Type.Bool)
	// false group first (compare_group_keys: false < true)
	testing.expect_value(t, result.columns[0].bools[0], false)
	testing.expect_value(t, result.columns[1].int64s[0], i64(2))
	testing.expect_value(t, result.columns[0].bools[1], true)
	testing.expect_value(t, result.columns[1].int64s[1], i64(3))
}

@(test)
rollup_error_rate_aggregate :: proc(t: ^testing.T) {
	src := build_table("t", {
		make_str_col("region", {"us", "us", "eu", "eu"}),
		make_b_col("ok", {true, false, true, true}),
	})
	defer snout_core.free_table(&src)

	gq := query.Group_Query{
		group_columns = {"region"},
		aggregates    = {query.Aggregate_Spec{kind = .Error_Rate, column_name = "ok"}},
	}
	result, err := snout_merge.rollup_tables([]^snout_core.Table{&src}, "out", gq)
	testing.expect(t, err == .None)
	defer snout_core.free_table(&result)

	testing.expect_value(t, result.row_count, 2)
	testing.expect_value(t, result.columns[1].kind, snout_core.Column_Type.Float64)
	// eu: 2/2 = 1.0 ; us: 1/2 = 0.5
	testing.expect_value(t, result.columns[1].float64s[0], f64(1.0))
	testing.expect_value(t, result.columns[1].float64s[1], f64(0.5))
}

@(test)
rollup_float_sum_min_max :: proc(t: ^testing.T) {
	src := build_table("t", {
		make_str_col("region", {"us", "eu", "us"}),
		make_f64_col("latency", {1.5, 2.5, 3.5}),
	})
	defer snout_core.free_table(&src)

	gq := query.Group_Query{
		group_columns = {"region"},
		aggregates = {
			query.Aggregate_Spec{kind = .Sum, column_name = "latency"},
			query.Aggregate_Spec{kind = .Min, column_name = "latency"},
			query.Aggregate_Spec{kind = .Max, column_name = "latency"},
		},
	}
	result, err := snout_merge.rollup_tables([]^snout_core.Table{&src}, "out", gq)
	testing.expect(t, err == .None)
	defer snout_core.free_table(&result)

	testing.expect_value(t, result.row_count, 2)
	// eu: sum=2.5, min=2.5, max=2.5
	testing.expect_value(t, result.columns[1].float64s[0], f64(2.5))
	testing.expect_value(t, result.columns[2].float64s[0], f64(2.5))
	testing.expect_value(t, result.columns[3].float64s[0], f64(2.5))
	// us: sum=5.0, min=1.5, max=3.5
	testing.expect_value(t, result.columns[1].float64s[1], f64(5.0))
	testing.expect_value(t, result.columns[2].float64s[1], f64(1.5))
	testing.expect_value(t, result.columns[3].float64s[1], f64(3.5))
}

@(test)
rollup_zero_groups_infers_types_from_source :: proc(t: ^testing.T) {
	// Filter matches nothing → 0 groups; column types inferred from source.
	src := build_table("t", {
		make_str_col("region", {"us", "eu"}),
		make_i64_col("val", {10, 20}),
	})
	defer snout_core.free_table(&src)

	gq := query.Group_Query{
		group_columns = {"region"},
		aggregates    = {query.Aggregate_Spec{kind = .Count, column_name = "*"}},
		filters = {
			query.Filter_Predicate{
				column_name = "region",
				operator    = .Equal,
				value       = {kind = .String, string_value = "ap"},
			},
		},
	}
	result, err := snout_merge.rollup_tables([]^snout_core.Table{&src}, "out", gq)
	testing.expect(t, err == .None)
	defer snout_core.free_table(&result)

	testing.expect_value(t, result.row_count, 0)
	testing.expect_value(t, len(result.columns), 2)
	testing.expect_value(t, result.columns[0].kind, snout_core.Column_Type.String)
	testing.expect_value(t, result.columns[1].kind, snout_core.Column_Type.Int64)
}

@(test)
rollup_empty_sources_returns_error :: proc(t: ^testing.T) {
	gq := query.Group_Query{
		group_columns = {"region"},
		aggregates    = {query.Aggregate_Spec{kind = .Count, column_name = "*"}},
	}
	_, err := snout_merge.rollup_tables([]^snout_core.Table{}, "out", gq)
	testing.expect_value(t, err, snout_core.Error.Empty_Input)
}

@(test)
rollup_result_owns_all_strings :: proc(t: ^testing.T) {
	// Free the source before using the result; no UAF if strings are properly owned.
	src := build_table("t", {
		make_str_col("region", {"us", "eu", "us"}),
		make_i64_col("val", {1, 2, 3}),
	})
	gq := query.Group_Query{
		group_columns = {"region"},
		aggregates    = {query.Aggregate_Spec{kind = .Sum, column_name = "val"}},
	}
	result, err := snout_merge.rollup_tables([]^snout_core.Table{&src}, "owned", gq)
	snout_core.free_table(&src)
	testing.expect(t, err == .None)
	defer snout_core.free_table(&result)

	testing.expect_value(t, result.name, "owned")
	testing.expect_value(t, result.columns[0].name, "region")
	testing.expect_value(t, result.columns[1].name, "sum_val")
	testing.expect_value(t, result.columns[0].strings[0], "eu")
	testing.expect_value(t, result.columns[0].strings[1], "us")
}

@(test)
rollup_result_survives_storage_round_trip :: proc(t: ^testing.T) {
	src := build_table("events", {
		make_str_col("region", {"us", "eu", "us", "eu", "ap"}),
		make_i64_col("requests", {1, 2, 3, 4, 5}),
	})
	defer snout_core.free_table(&src)

	gq := query.Group_Query{
		group_columns = {"region"},
		aggregates    = {query.Aggregate_Spec{kind = .Sum, column_name = "requests"}},
	}
	rollup_out, err := snout_merge.rollup_tables([]^snout_core.Table{&src}, "rollup_rt", gq)
	testing.expect(t, err == .None)
	defer snout_core.free_table(&rollup_out)

	tmp_path := "tests/fixtures/rollup_rt_tmp.snout"
	write_err := storage.write_snout_file(tmp_path, &rollup_out)
	testing.expect(t, write_err == .None)
	defer os.remove(tmp_path)

	read_back, read_err := storage.read_snout_file(tmp_path)
	testing.expect(t, read_err == .None)
	defer snout_core.free_table(&read_back)

	testing.expect_value(t, read_back.row_count, rollup_out.row_count)
	testing.expect_value(t, len(read_back.columns), len(rollup_out.columns))
	for i in 0 ..< rollup_out.row_count {
		testing.expect_value(t, read_back.columns[0].strings[i], rollup_out.columns[0].strings[i])
		testing.expect_value(t, read_back.columns[1].int64s[i], rollup_out.columns[1].int64s[i])
	}
}
