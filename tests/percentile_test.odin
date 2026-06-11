package tests

import "core:math"
import "core:strings"
import "core:testing"
import snout_core "../core"
import exec_agg "../exec"
import ingest "../ingest"
import query "../query"

// ---- helpers ----------------------------------------------------------------

@(private = "file")
pct_make_int_col :: proc(
	name: string,
	values: []i64,
	nulls: []bool = nil,
	allocator := context.allocator,
) -> snout_core.Column {
	col: snout_core.Column
	col.name = strings.clone(name, allocator)
	col.kind = .Int64
	col.nullable = nulls != nil
	col.null_mask, _ = make([]bool, len(values), allocator)
	if nulls != nil {
		copy(col.null_mask, nulls)
	}
	col.int64s, _ = make([]i64, len(values), allocator)
	copy(col.int64s, values)
	return col
}

@(private = "file")
pct_make_float_col :: proc(
	name: string,
	values: []f64,
	nulls: []bool = nil,
	allocator := context.allocator,
) -> snout_core.Column {
	col: snout_core.Column
	col.name = strings.clone(name, allocator)
	col.kind = .Float64
	col.nullable = nulls != nil
	col.null_mask, _ = make([]bool, len(values), allocator)
	if nulls != nil {
		copy(col.null_mask, nulls)
	}
	col.float64s, _ = make([]f64, len(values), allocator)
	copy(col.float64s, values)
	return col
}

@(private = "file")
pct_make_bool_col :: proc(
	name: string,
	values: []bool,
	nulls: []bool = nil,
	allocator := context.allocator,
) -> snout_core.Column {
	col: snout_core.Column
	col.name = strings.clone(name, allocator)
	col.kind = .Bool
	col.nullable = nulls != nil
	col.null_mask, _ = make([]bool, len(values), allocator)
	if nulls != nil {
		copy(col.null_mask, nulls)
	}
	col.bools, _ = make([]bool, len(values), allocator)
	copy(col.bools, values)
	return col
}

@(private = "file")
pct_make_string_col :: proc(
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

// pct_make_table performs a shallow copy of cols into a new Table.
// The Table takes ownership of all column backing data; do NOT free
// the original column locals separately — call free_table only.
@(private = "file")
pct_make_table :: proc(
	name: string,
	row_count: int,
	cols: []snout_core.Column,
	allocator := context.allocator,
) -> snout_core.Table {
	columns, _ := make([]snout_core.Column, len(cols), allocator)
	copy(columns, cols)
	return snout_core.Table{
		name      = strings.clone(name, allocator),
		row_count = row_count,
		columns   = columns,
		allocator = allocator,
	}
}

// run_single_group runs a group-by query against table with group column "g".
@(private = "file")
run_single_group :: proc(
	t: ^testing.T,
	table: ^snout_core.Table,
	aggregates: []query.Aggregate_Spec,
) -> (result: query.Group_Result_Set, ok: bool) {
	gcols := [?]string{"g"}
	r, err := query.execute_group_query(
		table,
		query.Group_Query{group_columns = gcols[:], aggregates = aggregates},
	)
	testing.expect_value(t, err, snout_core.Error.None)
	return r, err == .None
}

// ---- aggregate_name ---------------------------------------------------------

@(test)
aggregate_name_count_sum_avg_min_max :: proc(t: ^testing.T) {
	testing.expect_value(t, query.aggregate_name({kind = .Count}),      "count")
	testing.expect_value(t, query.aggregate_name({kind = .Sum}),        "sum")
	testing.expect_value(t, query.aggregate_name({kind = .Avg}),        "avg")
	testing.expect_value(t, query.aggregate_name({kind = .Min}),        "min")
	testing.expect_value(t, query.aggregate_name({kind = .Max}),        "max")
	testing.expect_value(t, query.aggregate_name({kind = .Error_Rate}), "error_rate")
}

@(test)
aggregate_name_percentile_produces_pN_string :: proc(t: ^testing.T) {
	testing.expect_value(t, query.aggregate_name({kind = .Percentile, percentile = 0.50}), "p50")
	testing.expect_value(t, query.aggregate_name({kind = .Percentile, percentile = 0.95}), "p95")
	testing.expect_value(t, query.aggregate_name({kind = .Percentile, percentile = 0.99}), "p99")
	testing.expect_value(t, query.aggregate_name({kind = .Percentile, percentile = 0.00}), "p0")
}

// ---- parse_aggregate_spec_kind ----------------------------------------------

@(test)
parse_aggregate_spec_kind_classic_aggregates :: proc(t: ^testing.T) {
	cases_k := [][2]string{
		{"count", "count"}, {"sum", "sum"}, {"avg", "avg"},
		{"min", "min"}, {"max", "max"}, {"error_rate", "error_rate"},
	}
	expected_kinds := []query.Aggregate_Kind{
		.Count, .Sum, .Avg, .Min, .Max, .Error_Rate,
	}
	for entry, i in cases_k {
		spec, ok := query.parse_aggregate_spec_kind(entry[0])
		testing.expect(t, ok, entry[0])
		testing.expect_value(t, spec.kind, expected_kinds[i])
	}
}

@(test)
parse_aggregate_spec_kind_percentile_values :: proc(t: ^testing.T) {
	pct_texts := [4]string{"p0", "p50", "p95", "p99"}
	pct_vals  := [4]f64{0.00, 0.50, 0.95, 0.99}
	for i in 0..<4 {
		spec, ok := query.parse_aggregate_spec_kind(pct_texts[i])
		testing.expect(t, ok, pct_texts[i])
		testing.expect_value(t, spec.kind, query.Aggregate_Kind.Percentile)
		testing.expect(t, math.abs(spec.percentile - pct_vals[i]) < 1e-9, pct_texts[i])
	}
}

@(test)
parse_aggregate_spec_kind_p100_is_rejected :: proc(t: ^testing.T) {
	_, ok := query.parse_aggregate_spec_kind("p100")
	testing.expect(t, !ok, "p100 must be rejected (out of range 0-99)")
}

@(test)
parse_aggregate_spec_kind_garbage_returns_false :: proc(t: ^testing.T) {
	bad_texts := [5]string{"", "COUNT", "average", "pXX", "p-1"}
	for text in bad_texts {
		_, ok := query.parse_aggregate_spec_kind(text)
		testing.expect(t, !ok, text)
	}
}

// ---- percentile correctness (group-by) --------------------------------------

@(test)
percentile_p50_of_five_values_is_median :: proc(t: ^testing.T) {
	// [1,2,3,4,5]: p50 index = floor(0.5 * 4) = 2 → 3
	values := [5]i64{1, 2, 3, 4, 5}
	grp    := [5]string{"a", "a", "a", "a", "a"}
	table := pct_make_table("t", 5, []snout_core.Column{
		pct_make_string_col("g", grp[:]),
		pct_make_int_col("v", values[:]),
	})
	defer snout_core.free_table(&table)

	aggregates := [?]query.Aggregate_Spec{{kind = .Percentile, column_name = "v", percentile = 0.50}}
	result, ok := run_single_group(t, &table, aggregates[:])
	if !ok { return }
	defer query.free_group_result_set(&result)

	testing.expect_value(t, len(result.groups), 1)
	v := result.groups[0].values[0]
	testing.expect(t, v.valid)
	testing.expect_value(t, v.kind, snout_core.Column_Type.Float64)
	testing.expect(t, math.abs(v.float_value - 3.0) < 1e-9)
}

@(test)
percentile_p95_of_100_sequential_values :: proc(t: ^testing.T) {
	// [1..100]: p95 index = floor(0.95 * 99) = 94 → 95
	N :: 100
	values: [N]i64
	grp:    [N]string
	for i in 0..<N { values[i] = i64(i + 1); grp[i] = "a" }
	table := pct_make_table("t", N, []snout_core.Column{
		pct_make_string_col("g", grp[:]),
		pct_make_int_col("v", values[:]),
	})
	defer snout_core.free_table(&table)

	aggregates := [?]query.Aggregate_Spec{{kind = .Percentile, column_name = "v", percentile = 0.95}}
	result, ok := run_single_group(t, &table, aggregates[:])
	if !ok { return }
	defer query.free_group_result_set(&result)

	v := result.groups[0].values[0]
	testing.expect(t, v.valid)
	testing.expect(t, math.abs(v.float_value - 95.0) < 1e-9)
}

@(test)
percentile_p99_of_100_sequential_values :: proc(t: ^testing.T) {
	// [1..100]: p99 index = floor(0.99 * 99) = 98 → 99
	N :: 100
	values: [N]i64
	grp:    [N]string
	for i in 0..<N { values[i] = i64(i + 1); grp[i] = "a" }
	table := pct_make_table("t", N, []snout_core.Column{
		pct_make_string_col("g", grp[:]),
		pct_make_int_col("v", values[:]),
	})
	defer snout_core.free_table(&table)

	aggregates := [?]query.Aggregate_Spec{{kind = .Percentile, column_name = "v", percentile = 0.99}}
	result, ok := run_single_group(t, &table, aggregates[:])
	if !ok { return }
	defer query.free_group_result_set(&result)

	v := result.groups[0].values[0]
	testing.expect(t, v.valid)
	testing.expect(t, math.abs(v.float_value - 99.0) < 1e-9)
}

@(test)
percentile_p0_equals_minimum :: proc(t: ^testing.T) {
	values := [5]i64{7, 3, 1, 9, 5}
	grp    := [5]string{"a", "a", "a", "a", "a"}
	table := pct_make_table("t", 5, []snout_core.Column{
		pct_make_string_col("g", grp[:]),
		pct_make_int_col("v", values[:]),
	})
	defer snout_core.free_table(&table)

	aggregates := [?]query.Aggregate_Spec{{kind = .Percentile, column_name = "v", percentile = 0.0}}
	result, ok := run_single_group(t, &table, aggregates[:])
	if !ok { return }
	defer query.free_group_result_set(&result)

	v := result.groups[0].values[0]
	testing.expect(t, v.valid)
	testing.expect(t, math.abs(v.float_value - 1.0) < 1e-9)
}

@(test)
percentile_single_row_returns_that_value :: proc(t: ^testing.T) {
	values := [1]i64{42}
	grp    := [1]string{"a"}
	table := pct_make_table("t", 1, []snout_core.Column{
		pct_make_string_col("g", grp[:]),
		pct_make_int_col("v", values[:]),
	})
	defer snout_core.free_table(&table)

	aggregates := [?]query.Aggregate_Spec{{kind = .Percentile, column_name = "v", percentile = 0.95}}
	result, ok := run_single_group(t, &table, aggregates[:])
	if !ok { return }
	defer query.free_group_result_set(&result)

	v := result.groups[0].values[0]
	testing.expect(t, v.valid)
	testing.expect(t, math.abs(v.float_value - 42.0) < 1e-9)
}

@(test)
percentile_all_null_column_returns_invalid :: proc(t: ^testing.T) {
	nulls  := [3]bool{true, true, true}
	values := [3]i64{1, 2, 3}
	grp    := [3]string{"a", "a", "a"}
	table := pct_make_table("t", 3, []snout_core.Column{
		pct_make_string_col("g", grp[:]),
		pct_make_int_col("v", values[:], nulls[:]),
	})
	defer snout_core.free_table(&table)

	aggregates := [?]query.Aggregate_Spec{{kind = .Percentile, column_name = "v", percentile = 0.50}}
	result, ok := run_single_group(t, &table, aggregates[:])
	if !ok { return }
	defer query.free_group_result_set(&result)

	testing.expect(t, !result.groups[0].values[0].valid)
}

@(test)
percentile_float64_column :: proc(t: ^testing.T) {
	// [1.0, 2.0, 3.0, 4.0, 5.0]: p50 index = floor(0.5*4) = 2 → 3.0
	values := [5]f64{1.0, 2.0, 3.0, 4.0, 5.0}
	grp    := [5]string{"a", "a", "a", "a", "a"}
	table := pct_make_table("t", 5, []snout_core.Column{
		pct_make_string_col("g", grp[:]),
		pct_make_float_col("v", values[:]),
	})
	defer snout_core.free_table(&table)

	aggregates := [?]query.Aggregate_Spec{{kind = .Percentile, column_name = "v", percentile = 0.50}}
	result, ok := run_single_group(t, &table, aggregates[:])
	if !ok { return }
	defer query.free_group_result_set(&result)

	v := result.groups[0].values[0]
	testing.expect(t, v.valid)
	testing.expect_value(t, v.kind, snout_core.Column_Type.Float64)
	testing.expect(t, math.abs(v.float_value - 3.0) < 1e-9)
}

@(test)
two_percentiles_same_column_both_correct :: proc(t: ^testing.T) {
	// [1..10]: p0=1, p99 index=floor(0.99*9)=8 → 9
	N :: 10
	values: [N]i64
	grp:    [N]string
	for i in 0..<N { values[i] = i64(i + 1); grp[i] = "a" }
	table := pct_make_table("t", N, []snout_core.Column{
		pct_make_string_col("g", grp[:]),
		pct_make_int_col("v", values[:]),
	})
	defer snout_core.free_table(&table)

	aggregates := [?]query.Aggregate_Spec{
		{kind = .Percentile, column_name = "v", percentile = 0.00},
		{kind = .Percentile, column_name = "v", percentile = 0.99},
	}
	result, ok := run_single_group(t, &table, aggregates[:])
	if !ok { return }
	defer query.free_group_result_set(&result)

	testing.expect_value(t, len(result.groups[0].values), 2)
	testing.expect(t, math.abs(result.groups[0].values[0].float_value - 1.0) < 1e-9)
	testing.expect(t, math.abs(result.groups[0].values[1].float_value - 9.0) < 1e-9)
}

@(test)
percentile_and_avg_in_same_query :: proc(t: ^testing.T) {
	values := [5]i64{1, 2, 3, 4, 5}
	grp    := [5]string{"a", "a", "a", "a", "a"}
	table := pct_make_table("t", 5, []snout_core.Column{
		pct_make_string_col("g", grp[:]),
		pct_make_int_col("v", values[:]),
	})
	defer snout_core.free_table(&table)

	aggregates := [?]query.Aggregate_Spec{
		{kind = .Percentile, column_name = "v", percentile = 0.50},
		{kind = .Avg, column_name = "v"},
	}
	result, ok := run_single_group(t, &table, aggregates[:])
	if !ok { return }
	defer query.free_group_result_set(&result)

	testing.expect(t, math.abs(result.groups[0].values[0].float_value - 3.0) < 1e-9) // p50
	testing.expect(t, math.abs(result.groups[0].values[1].float_value - 3.0) < 1e-9) // avg
}

@(test)
percentile_per_group_correct :: proc(t: ^testing.T) {
	// group "a": [10, 20, 30, 40, 50] p50 = 30
	// group "b": [1, 2, 3, 4, 5]     p50 = 3
	grp    := [10]string{"a", "a", "a", "a", "a", "b", "b", "b", "b", "b"}
	values := [10]i64{10, 20, 30, 40, 50, 1, 2, 3, 4, 5}
	table := pct_make_table("t", 10, []snout_core.Column{
		pct_make_string_col("g", grp[:]),
		pct_make_int_col("v", values[:]),
	})
	defer snout_core.free_table(&table)

	aggregates := [?]query.Aggregate_Spec{{kind = .Percentile, column_name = "v", percentile = 0.50}}
	result, ok := run_single_group(t, &table, aggregates[:])
	if !ok { return }
	defer query.free_group_result_set(&result)

	testing.expect_value(t, len(result.groups), 2)
	// groups sorted by key: "a" < "b"
	testing.expect(t, math.abs(result.groups[0].values[0].float_value - 30.0) < 1e-9)
	testing.expect(t, math.abs(result.groups[1].values[0].float_value -  3.0) < 1e-9)
}

// ---- error rate correctness -------------------------------------------------

@(test)
error_rate_one_third_is_correct :: proc(t: ^testing.T) {
	bools := [3]bool{true, false, false}
	grp   := [3]string{"a", "a", "a"}
	table := pct_make_table("t", 3, []snout_core.Column{
		pct_make_string_col("g", grp[:]),
		pct_make_bool_col("e", bools[:]),
	})
	defer snout_core.free_table(&table)

	aggregates := [?]query.Aggregate_Spec{{kind = .Error_Rate, column_name = "e"}}
	result, ok := run_single_group(t, &table, aggregates[:])
	if !ok { return }
	defer query.free_group_result_set(&result)

	v := result.groups[0].values[0]
	testing.expect(t, v.valid)
	testing.expect_value(t, v.kind, snout_core.Column_Type.Float64)
	testing.expect(t, math.abs(v.float_value - (1.0/3.0)) < 1e-9)
}

@(test)
error_rate_all_true_is_one :: proc(t: ^testing.T) {
	bools := [4]bool{true, true, true, true}
	grp   := [4]string{"a", "a", "a", "a"}
	table := pct_make_table("t", 4, []snout_core.Column{
		pct_make_string_col("g", grp[:]),
		pct_make_bool_col("e", bools[:]),
	})
	defer snout_core.free_table(&table)

	aggregates := [?]query.Aggregate_Spec{{kind = .Error_Rate, column_name = "e"}}
	result, ok := run_single_group(t, &table, aggregates[:])
	if !ok { return }
	defer query.free_group_result_set(&result)

	testing.expect(t, math.abs(result.groups[0].values[0].float_value - 1.0) < 1e-9)
}

@(test)
error_rate_all_false_is_zero :: proc(t: ^testing.T) {
	bools := [4]bool{false, false, false, false}
	grp   := [4]string{"a", "a", "a", "a"}
	table := pct_make_table("t", 4, []snout_core.Column{
		pct_make_string_col("g", grp[:]),
		pct_make_bool_col("e", bools[:]),
	})
	defer snout_core.free_table(&table)

	aggregates := [?]query.Aggregate_Spec{{kind = .Error_Rate, column_name = "e"}}
	result, ok := run_single_group(t, &table, aggregates[:])
	if !ok { return }
	defer query.free_group_result_set(&result)

	testing.expect(t, math.abs(result.groups[0].values[0].float_value - 0.0) < 1e-9)
}

@(test)
error_rate_nulls_excluded_from_denominator :: proc(t: ^testing.T) {
	// [true, false, NULL, NULL]: rate = 1/2 = 0.5
	nulls := [4]bool{false, false, true, true}
	bools := [4]bool{true, false, false, true}
	grp   := [4]string{"a", "a", "a", "a"}
	table := pct_make_table("t", 4, []snout_core.Column{
		pct_make_string_col("g", grp[:]),
		pct_make_bool_col("e", bools[:], nulls[:]),
	})
	defer snout_core.free_table(&table)

	aggregates := [?]query.Aggregate_Spec{{kind = .Error_Rate, column_name = "e"}}
	result, ok := run_single_group(t, &table, aggregates[:])
	if !ok { return }
	defer query.free_group_result_set(&result)

	v := result.groups[0].values[0]
	testing.expect(t, v.valid)
	testing.expect(t, math.abs(v.float_value - 0.5) < 1e-9)
}

@(test)
error_rate_all_null_returns_invalid :: proc(t: ^testing.T) {
	nulls := [3]bool{true, true, true}
	bools := [3]bool{true, false, true}
	grp   := [3]string{"a", "a", "a"}
	table := pct_make_table("t", 3, []snout_core.Column{
		pct_make_string_col("g", grp[:]),
		pct_make_bool_col("e", bools[:], nulls[:]),
	})
	defer snout_core.free_table(&table)

	aggregates := [?]query.Aggregate_Spec{{kind = .Error_Rate, column_name = "e"}}
	result, ok := run_single_group(t, &table, aggregates[:])
	if !ok { return }
	defer query.free_group_result_set(&result)

	testing.expect(t, !result.groups[0].values[0].valid)
}

@(test)
error_rate_on_non_bool_column_is_invalid :: proc(t: ^testing.T) {
	values := [3]i64{1, 2, 3}
	grp    := [3]string{"a", "a", "a"}
	table := pct_make_table("t", 3, []snout_core.Column{
		pct_make_string_col("g", grp[:]),
		pct_make_int_col("v", values[:]),
	})
	defer snout_core.free_table(&table)

	aggregates := [?]query.Aggregate_Spec{{kind = .Error_Rate, column_name = "v"}}
	gcols := [?]string{"g"}
	_, err := query.execute_group_query(
		&table,
		query.Group_Query{group_columns = gcols[:], aggregates = aggregates[:]},
	)
	testing.expect_value(t, err, snout_core.Error.Invalid_Aggregate_Column)
}

@(test)
error_rate_and_count_in_same_query :: proc(t: ^testing.T) {
	bools := [4]bool{true, false, true, false}
	grp   := [4]string{"a", "a", "a", "a"}
	table := pct_make_table("t", 4, []snout_core.Column{
		pct_make_string_col("g", grp[:]),
		pct_make_bool_col("e", bools[:]),
	})
	defer snout_core.free_table(&table)

	aggregates := [?]query.Aggregate_Spec{
		{kind = .Error_Rate, column_name = "e"},
		{kind = .Count, column_name = "*"},
	}
	result, ok := run_single_group(t, &table, aggregates[:])
	if !ok { return }
	defer query.free_group_result_set(&result)

	testing.expect(t, math.abs(result.groups[0].values[0].float_value - 0.5) < 1e-9)
	testing.expect_value(t, result.groups[0].values[1].int_value, i64(4))
}

// ---- duplicate detection ----------------------------------------------------

@(test)
duplicate_percentile_same_column_same_quantile_rejected :: proc(t: ^testing.T) {
	values := [3]i64{1, 2, 3}
	grp    := [3]string{"a", "a", "a"}
	table := pct_make_table("t", 3, []snout_core.Column{
		pct_make_string_col("g", grp[:]),
		pct_make_int_col("v", values[:]),
	})
	defer snout_core.free_table(&table)

	aggregates := [?]query.Aggregate_Spec{
		{kind = .Percentile, column_name = "v", percentile = 0.95},
		{kind = .Percentile, column_name = "v", percentile = 0.95},
	}
	gcols := [?]string{"g"}
	_, err := query.execute_group_query(
		&table,
		query.Group_Query{group_columns = gcols[:], aggregates = aggregates[:]},
	)
	testing.expect_value(t, err, snout_core.Error.Duplicate_Result_Column)
}

@(test)
duplicate_percentile_same_column_different_quantile_allowed :: proc(t: ^testing.T) {
	values := [5]i64{1, 2, 3, 4, 5}
	grp    := [5]string{"a", "a", "a", "a", "a"}
	table := pct_make_table("t", 5, []snout_core.Column{
		pct_make_string_col("g", grp[:]),
		pct_make_int_col("v", values[:]),
	})
	defer snout_core.free_table(&table)

	aggregates := [?]query.Aggregate_Spec{
		{kind = .Percentile, column_name = "v", percentile = 0.50},
		{kind = .Percentile, column_name = "v", percentile = 0.95},
	}
	result, ok := run_single_group(t, &table, aggregates[:])
	testing.expect(t, ok)
	if ok { query.free_group_result_set(&result) }
}

@(test)
duplicate_error_rate_same_column_rejected :: proc(t: ^testing.T) {
	bools := [3]bool{true, false, true}
	grp   := [3]string{"a", "a", "a"}
	table := pct_make_table("t", 3, []snout_core.Column{
		pct_make_string_col("g", grp[:]),
		pct_make_bool_col("e", bools[:]),
	})
	defer snout_core.free_table(&table)

	aggregates := [?]query.Aggregate_Spec{
		{kind = .Error_Rate, column_name = "e"},
		{kind = .Error_Rate, column_name = "e"},
	}
	gcols := [?]string{"g"}
	_, err := query.execute_group_query(
		&table,
		query.Group_Query{group_columns = gcols[:], aggregates = aggregates[:]},
	)
	testing.expect_value(t, err, snout_core.Error.Duplicate_Result_Column)
}

// ---- Numeric_Stats percentiles -----------------------------------------------

@(test)
numeric_stats_percentiles_on_int64_column :: proc(t: ^testing.T) {
	// [1..10]: p50 index=floor(0.5*9)=4 → 5; p95 index=floor(0.95*9)=8 → 9; p99 index=floor(0.99*9)=8 → 9
	table, err := ingest.read_csv_string(
		"region,latency\na,1\na,2\na,3\na,4\na,5\na,6\na,7\na,8\na,9\na,10\n",
		"test",
	)
	testing.expect_value(t, err, snout_core.Error.None)
	if err != .None { return }
	defer snout_core.free_table(&table)

	stats, stats_err := exec_agg.numeric_stats(&table, "latency")
	testing.expect_value(t, stats_err, snout_core.Error.None)
	testing.expect_value(t, stats.count, 10)
	testing.expect(t, math.abs(stats.p50 - 5.0) < 1e-9)
	testing.expect(t, math.abs(stats.p95 - 9.0) < 1e-9)
	testing.expect(t, math.abs(stats.p99 - 9.0) < 1e-9)
}

@(test)
numeric_stats_percentiles_on_float64_column :: proc(t: ^testing.T) {
	// [1.0..5.0]: p50 index=floor(0.5*4)=2 → 3.0
	table, err := ingest.read_csv_string(
		"g,v\na,1.0\na,2.0\na,3.0\na,4.0\na,5.0\n",
		"test",
	)
	testing.expect_value(t, err, snout_core.Error.None)
	if err != .None { return }
	defer snout_core.free_table(&table)

	stats, stats_err := exec_agg.numeric_stats(&table, "v")
	testing.expect_value(t, stats_err, snout_core.Error.None)
	testing.expect(t, math.abs(stats.p50 - 3.0) < 1e-9)
}

@(test)
numeric_stats_single_value_all_percentiles_equal :: proc(t: ^testing.T) {
	table, err := ingest.read_csv_string("g,v\na,7\n", "test")
	testing.expect_value(t, err, snout_core.Error.None)
	if err != .None { return }
	defer snout_core.free_table(&table)

	stats, stats_err := exec_agg.numeric_stats(&table, "v")
	testing.expect_value(t, stats_err, snout_core.Error.None)
	testing.expect(t, math.abs(stats.p50 - 7.0) < 1e-9)
	testing.expect(t, math.abs(stats.p95 - 7.0) < 1e-9)
	testing.expect(t, math.abs(stats.p99 - 7.0) < 1e-9)
}

// ---- integration with fixture -----------------------------------------------

@(test)
percentile_and_error_rate_on_complex_metrics_fixture :: proc(t: ^testing.T) {
	table, err := ingest.read_csv_table("tests/fixtures/complex_metrics_500.csv", "calls")
	testing.expect_value(t, err, snout_core.Error.None)
	if err != .None { return }
	defer snout_core.free_table(&table)

	aggregates := [?]query.Aggregate_Spec{
		{kind = .Percentile, column_name = "jitter_ms", percentile = 0.95},
		{kind = .Error_Rate, column_name = "roaming"},
	}
	gcols := [?]string{"region"}
	result, query_err := query.execute_group_query(
		&table,
		query.Group_Query{
			group_columns = gcols[:],
			aggregates    = aggregates[:],
		},
	)
	testing.expect_value(t, query_err, snout_core.Error.None)
	if query_err != .None { return }
	defer query.free_group_result_set(&result)

	testing.expect(t, len(result.groups) > 0)
	for group in result.groups {
		v_pct := group.values[0]
		v_er  := group.values[1]
		if v_pct.valid {
			testing.expect(t, v_pct.float_value >= 0)
		}
		if v_er.valid {
			testing.expect(t, v_er.float_value >= 0.0 && v_er.float_value <= 1.0)
		}
	}
}
