package tests

import "core:fmt"
import "core:os"
import "core:strings"
import "core:testing"
import snout_core "../core"
import ingest "../ingest"
import snout_merge "../merge"
import storage "../storage"

// ---- helpers ----------------------------------------------------------------

@(private = "file")
make_int_col :: proc(
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
make_float_col :: proc(
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
make_string_col :: proc(
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
make_bool_col :: proc(
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

// make_table wraps a slice of columns into a Table (takes ownership).
@(private = "file")
make_table :: proc(
	name: string,
	row_count: int,
	columns: ..snout_core.Column,
	allocator := context.allocator,
) -> snout_core.Table {
	table: snout_core.Table
	table.allocator = allocator
	table.name = strings.clone(name, allocator)
	table.row_count = row_count
	table.columns, _ = make([]snout_core.Column, len(columns), allocator)
	for col, i in columns {
		table.columns[i] = col
	}
	return table
}

// write a table to a temp .snout file; caller must os.remove + delete the path
@(private = "file")
write_tmp_snout :: proc(t: ^testing.T, table: ^snout_core.Table, suffix: string) -> string {
	path := fmt.aprintf("tests/fixtures/.tmp_merge_%s.snout", suffix)
	err := storage.write_snout_file(path, table)
	testing.expect_value(t, err, snout_core.Error.None)
	return path
}

@(private = "file")
read_tmp_snout :: proc(t: ^testing.T, path: string) -> snout_core.Table {
	table, err := storage.read_snout_file(path)
	testing.expect_value(t, err, snout_core.Error.None)
	return table
}

// ---- promote_merge_type -----------------------------------------------------

@(test)
merge_promote_identity :: proc(t: ^testing.T) {
	testing.expect_value(t, snout_merge.promote_merge_type(.Int64, .Int64), snout_core.Column_Type.Int64)
	testing.expect_value(t, snout_merge.promote_merge_type(.Float64, .Float64), snout_core.Column_Type.Float64)
	testing.expect_value(t, snout_merge.promote_merge_type(.Bool, .Bool), snout_core.Column_Type.Bool)
	testing.expect_value(t, snout_merge.promote_merge_type(.String, .String), snout_core.Column_Type.String)
	testing.expect_value(t, snout_merge.promote_merge_type(.Timestamp, .Timestamp), snout_core.Column_Type.Timestamp)
}

@(test)
merge_promote_int_float :: proc(t: ^testing.T) {
	testing.expect_value(t, snout_merge.promote_merge_type(.Int64, .Float64), snout_core.Column_Type.Float64)
	testing.expect_value(t, snout_merge.promote_merge_type(.Float64, .Int64), snout_core.Column_Type.Float64)
}

@(test)
merge_promote_to_string :: proc(t: ^testing.T) {
	testing.expect_value(t, snout_merge.promote_merge_type(.Int64, .String), snout_core.Column_Type.String)
	testing.expect_value(t, snout_merge.promote_merge_type(.Bool, .Int64), snout_core.Column_Type.String)
	testing.expect_value(t, snout_merge.promote_merge_type(.Bool, .Float64), snout_core.Column_Type.String)
	testing.expect_value(t, snout_merge.promote_merge_type(.Timestamp, .Int64), snout_core.Column_Type.String)
}

@(test)
merge_promote_unknown :: proc(t: ^testing.T) {
	testing.expect_value(t, snout_merge.promote_merge_type(.Unknown, .Int64), snout_core.Column_Type.Int64)
	testing.expect_value(t, snout_merge.promote_merge_type(.Int64, .Unknown), snout_core.Column_Type.Int64)
}

// ---- schema alignment -------------------------------------------------------

@(test)
merge_identical_schemas :: proc(t: ^testing.T) {
	a := make_table("x", 3, make_int_col("value", []i64{1, 2, 3}))
	defer snout_core.free_table(&a)
	b := make_table("x", 2, make_int_col("value", []i64{4, 5}))
	defer snout_core.free_table(&b)

	out, err := snout_merge.append_tables(&a, []^snout_core.Table{&b})
	defer snout_core.free_table(&out)
	testing.expect_value(t, err, snout_core.Error.None)
	testing.expect_value(t, out.row_count, 5)
	testing.expect_value(t, len(out.columns), 1)
	testing.expect_value(t, out.columns[0].kind, snout_core.Column_Type.Int64)
	testing.expect_value(t, out.columns[0].nullable, false)
	testing.expect_value(t, out.columns[0].int64s[0], i64(1))
	testing.expect_value(t, out.columns[0].int64s[4], i64(5))
}

@(test)
merge_extra_column_in_second_source :: proc(t: ^testing.T) {
	// a has "v"; b has "v" and "w"
	a := make_table("t", 2, make_int_col("v", []i64{10, 20}))
	defer snout_core.free_table(&a)

	w_col := make_string_col("w", []string{"hello", "world"})
	b := make_table("t", 2, make_int_col("v", []i64{30, 40}), w_col)
	defer snout_core.free_table(&b)

	out, err := snout_merge.append_tables(&a, []^snout_core.Table{&b})
	defer snout_core.free_table(&out)
	testing.expect_value(t, err, snout_core.Error.None)
	testing.expect_value(t, out.row_count, 4)
	testing.expect_value(t, len(out.columns), 2)

	// "v": present in both, non-nullable
	testing.expect_value(t, out.columns[0].name, "v")
	testing.expect_value(t, out.columns[0].nullable, false)
	testing.expect_value(t, out.columns[0].int64s[0], i64(10))
	testing.expect_value(t, out.columns[0].int64s[3], i64(40))

	// "w": absent from a → nullable, a-rows are null
	testing.expect_value(t, out.columns[1].name, "w")
	testing.expect_value(t, out.columns[1].nullable, true)
	testing.expect(t, out.columns[1].null_mask[0] == true, "a-row 0 null for w")
	testing.expect(t, out.columns[1].null_mask[1] == true, "a-row 1 null for w")
	testing.expect(t, out.columns[1].null_mask[2] == false, "b-row 0 not null for w")
	testing.expect_value(t, out.columns[1].strings[2], "hello")
	testing.expect_value(t, out.columns[1].strings[3], "world")
}

@(test)
merge_missing_column_in_second_source :: proc(t: ^testing.T) {
	// a has "v" and "w"; b has only "v"
	w_col := make_bool_col("w", []bool{true, false})
	a := make_table("t", 2, make_int_col("v", []i64{1, 2}), w_col)
	defer snout_core.free_table(&a)
	b := make_table("t", 2, make_int_col("v", []i64{3, 4}))
	defer snout_core.free_table(&b)

	out, err := snout_merge.append_tables(&a, []^snout_core.Table{&b})
	defer snout_core.free_table(&out)
	testing.expect_value(t, err, snout_core.Error.None)
	testing.expect_value(t, out.row_count, 4)

	// "w" nullable because b lacks it; b-rows null
	col_w := &out.columns[1]
	testing.expect_value(t, col_w.name, "w")
	testing.expect_value(t, col_w.nullable, true)
	testing.expect(t, col_w.null_mask[0] == false, "a-row 0 not null")
	testing.expect(t, col_w.null_mask[1] == false, "a-row 1 not null")
	testing.expect(t, col_w.null_mask[2] == true, "b-row 0 null")
	testing.expect(t, col_w.null_mask[3] == true, "b-row 1 null")
	testing.expect_value(t, col_w.bools[0], true)
	testing.expect_value(t, col_w.bools[1], false)
}

@(test)
merge_int64_to_float64_promotion :: proc(t: ^testing.T) {
	a := make_table("t", 2, make_int_col("score", []i64{1, 2}))
	defer snout_core.free_table(&a)
	b := make_table("t", 2, make_float_col("score", []f64{3.5, 4.5}))
	defer snout_core.free_table(&b)

	out, err := snout_merge.append_tables(&a, []^snout_core.Table{&b})
	defer snout_core.free_table(&out)
	testing.expect_value(t, err, snout_core.Error.None)
	testing.expect_value(t, out.columns[0].kind, snout_core.Column_Type.Float64)
	testing.expect_value(t, out.columns[0].float64s[0], f64(1))
	testing.expect_value(t, out.columns[0].float64s[1], f64(2))
	testing.expect_value(t, out.columns[0].float64s[2], f64(3.5))
	testing.expect_value(t, out.columns[0].float64s[3], f64(4.5))
}

@(test)
merge_bool_string_promotes_to_string :: proc(t: ^testing.T) {
	a := make_table("t", 2, make_bool_col("flag", []bool{true, false}))
	defer snout_core.free_table(&a)
	b := make_table("t", 2, make_string_col("flag", []string{"yes", "no"}))
	defer snout_core.free_table(&b)

	out, err := snout_merge.append_tables(&a, []^snout_core.Table{&b})
	defer snout_core.free_table(&out)
	testing.expect_value(t, err, snout_core.Error.None)
	testing.expect_value(t, out.columns[0].kind, snout_core.Column_Type.String)
	testing.expect_value(t, out.columns[0].strings[0], "true")
	testing.expect_value(t, out.columns[0].strings[1], "false")
	testing.expect_value(t, out.columns[0].strings[2], "yes")
	testing.expect_value(t, out.columns[0].strings[3], "no")
}

@(test)
merge_column_order_base_first :: proc(t: ^testing.T) {
	// a: z, a  b: a, b  → expected output: z, a, b
	z_a := make_int_col("z", []i64{1})
	a_a := make_int_col("a", []i64{2})
	a := make_table("t", 1, z_a, a_a)
	defer snout_core.free_table(&a)

	a_b := make_int_col("a", []i64{3})
	b_b := make_int_col("b", []i64{4})
	b := make_table("t", 1, a_b, b_b)
	defer snout_core.free_table(&b)

	out, err := snout_merge.append_tables(&a, []^snout_core.Table{&b})
	defer snout_core.free_table(&out)
	testing.expect_value(t, err, snout_core.Error.None)
	testing.expect_value(t, len(out.columns), 3)
	testing.expect_value(t, out.columns[0].name, "z")
	testing.expect_value(t, out.columns[1].name, "a")
	testing.expect_value(t, out.columns[2].name, "b")
}

// ---- value correctness ------------------------------------------------------

@(test)
merge_int64_values_exact :: proc(t: ^testing.T) {
	a := make_table("t", 3, make_int_col("n", []i64{100, -200, 300}))
	defer snout_core.free_table(&a)
	b := make_table("t", 2, make_int_col("n", []i64{400, 500}))
	defer snout_core.free_table(&b)

	out, err := snout_merge.append_tables(&a, []^snout_core.Table{&b})
	defer snout_core.free_table(&out)
	testing.expect_value(t, err, snout_core.Error.None)
	expected := []i64{100, -200, 300, 400, 500}
	for v, i in expected {
		testing.expect_value(t, out.columns[0].int64s[i], v)
	}
}

@(test)
merge_float64_values_exact :: proc(t: ^testing.T) {
	a := make_table("t", 2, make_float_col("x", []f64{1.5, 2.5}))
	defer snout_core.free_table(&a)
	b := make_table("t", 1, make_float_col("x", []f64{3.5}))
	defer snout_core.free_table(&b)

	out, err := snout_merge.append_tables(&a, []^snout_core.Table{&b})
	defer snout_core.free_table(&out)
	testing.expect_value(t, err, snout_core.Error.None)
	testing.expect_value(t, out.columns[0].float64s[0], f64(1.5))
	testing.expect_value(t, out.columns[0].float64s[2], f64(3.5))
}

@(test)
merge_string_values_cloned :: proc(t: ^testing.T) {
	a := make_table("t", 2, make_string_col("s", []string{"alpha", "beta"}))
	defer snout_core.free_table(&a)
	b := make_table("t", 1, make_string_col("s", []string{"gamma"}))
	defer snout_core.free_table(&b)

	out, err := snout_merge.append_tables(&a, []^snout_core.Table{&b})
	defer snout_core.free_table(&out)
	testing.expect_value(t, err, snout_core.Error.None)
	testing.expect_value(t, out.columns[0].strings[0], "alpha")
	testing.expect_value(t, out.columns[0].strings[1], "beta")
	testing.expect_value(t, out.columns[0].strings[2], "gamma")
}

@(test)
merge_null_mask_preserved :: proc(t: ^testing.T) {
	col: snout_core.Column
	col.name = strings.clone("v", context.allocator)
	col.kind = .Int64
	col.nullable = true
	col.null_mask, _ = make([]bool, 3, context.allocator)
	col.null_mask[1] = true // row 1 is null
	col.int64s, _ = make([]i64, 3, context.allocator)
	col.int64s[0], col.int64s[2] = 10, 30

	a := make_table("t", 3, col)
	defer snout_core.free_table(&a)
	b := make_table("t", 1, make_int_col("v", []i64{99}))
	defer snout_core.free_table(&b)

	out, err := snout_merge.append_tables(&a, []^snout_core.Table{&b})
	defer snout_core.free_table(&out)
	testing.expect_value(t, err, snout_core.Error.None)
	testing.expect_value(t, out.columns[0].nullable, true)
	testing.expect(t, out.columns[0].null_mask[0] == false, "row 0 not null")
	testing.expect(t, out.columns[0].null_mask[1] == true, "row 1 null")
	testing.expect(t, out.columns[0].null_mask[2] == false, "row 2 not null")
	testing.expect(t, out.columns[0].null_mask[3] == false, "row 3 not null")
	testing.expect_value(t, out.columns[0].int64s[0], i64(10))
	testing.expect_value(t, out.columns[0].int64s[2], i64(30))
	testing.expect_value(t, out.columns[0].int64s[3], i64(99))
}

// ---- edge cases -------------------------------------------------------------

@(test)
merge_empty_base :: proc(t: ^testing.T) {
	a := make_table("t", 0, make_int_col("v", []i64{}))
	defer snout_core.free_table(&a)
	b := make_table("t", 2, make_int_col("v", []i64{1, 2}))
	defer snout_core.free_table(&b)

	out, err := snout_merge.append_tables(&a, []^snout_core.Table{&b})
	defer snout_core.free_table(&out)
	testing.expect_value(t, err, snout_core.Error.None)
	testing.expect_value(t, out.row_count, 2)
	testing.expect_value(t, out.columns[0].int64s[0], i64(1))
}

@(test)
merge_empty_extra :: proc(t: ^testing.T) {
	a := make_table("t", 2, make_int_col("v", []i64{1, 2}))
	defer snout_core.free_table(&a)
	b := make_table("t", 0, make_int_col("v", []i64{}))
	defer snout_core.free_table(&b)

	out, err := snout_merge.append_tables(&a, []^snout_core.Table{&b})
	defer snout_core.free_table(&out)
	testing.expect_value(t, err, snout_core.Error.None)
	testing.expect_value(t, out.row_count, 2)
}

@(test)
merge_both_empty_preserves_schema :: proc(t: ^testing.T) {
	a := make_table("t", 0, make_int_col("v", []i64{}))
	defer snout_core.free_table(&a)
	b := make_table("t", 0, make_int_col("v", []i64{}))
	defer snout_core.free_table(&b)

	out, err := snout_merge.append_tables(&a, []^snout_core.Table{&b})
	defer snout_core.free_table(&out)
	testing.expect_value(t, err, snout_core.Error.None)
	testing.expect_value(t, out.row_count, 0)
	testing.expect_value(t, len(out.columns), 1)
}

@(test)
merge_three_way_disjoint_columns :: proc(t: ^testing.T) {
	a := make_table("t", 1, make_int_col("x", []i64{1}))
	defer snout_core.free_table(&a)
	b := make_table("t", 1, make_int_col("y", []i64{2}))
	defer snout_core.free_table(&b)
	c := make_table("t", 1, make_int_col("z", []i64{3}))
	defer snout_core.free_table(&c)

	out, err := snout_merge.append_tables(&a, []^snout_core.Table{&b, &c})
	defer snout_core.free_table(&out)
	testing.expect_value(t, err, snout_core.Error.None)
	testing.expect_value(t, out.row_count, 3)
	testing.expect_value(t, len(out.columns), 3)
	for col in out.columns {
		testing.expect_value(t, col.nullable, true)
	}
}

@(test)
compact_is_identity :: proc(t: ^testing.T) {
	src := make_table("tab", 3, make_string_col("name", []string{"alice", "bob", "carol"}))
	defer snout_core.free_table(&src)

	out, err := snout_merge.compact_table(&src)
	defer snout_core.free_table(&out)
	testing.expect_value(t, err, snout_core.Error.None)
	testing.expect_value(t, out.row_count, src.row_count)
	testing.expect_value(t, out.name, src.name)
	testing.expect_value(t, len(out.columns), len(src.columns))
	testing.expect_value(t, out.columns[0].strings[0], "alice")
	testing.expect_value(t, out.columns[0].strings[2], "carol")
}

// ---- .snout round-trip ------------------------------------------------------

@(test)
merge_roundtrip_via_snout_file :: proc(t: ^testing.T) {
	src := make_table("rt", 3, make_int_col("n", []i64{10, 20, 30}))
	defer snout_core.free_table(&src)

	path_a := write_tmp_snout(t, &src, "rt_a")
	defer os.remove(path_a)
	defer delete(path_a)

	ta := read_tmp_snout(t, path_a)
	defer snout_core.free_table(&ta)

	out, err := snout_merge.append_tables(&ta, []^snout_core.Table{&ta})
	defer snout_core.free_table(&out)
	testing.expect_value(t, err, snout_core.Error.None)
	testing.expect_value(t, out.row_count, 6)

	path_out := write_tmp_snout(t, &out, "rt_out")
	defer os.remove(path_out)
	defer delete(path_out)

	tb := read_tmp_snout(t, path_out)
	defer snout_core.free_table(&tb)
	testing.expect_value(t, tb.row_count, 6)
	testing.expect_value(t, tb.columns[0].int64s[0], i64(10))
	testing.expect_value(t, tb.columns[0].int64s[3], i64(10))
}

@(test)
compact_roundtrip_via_snout_file :: proc(t: ^testing.T) {
	src := make_table("ct", 2, make_string_col("s", []string{"x", "y"}))
	defer snout_core.free_table(&src)

	path_in := write_tmp_snout(t, &src, "compact_in")
	defer os.remove(path_in)
	defer delete(path_in)

	loaded := read_tmp_snout(t, path_in)
	defer snout_core.free_table(&loaded)

	out, err := snout_merge.compact_table(&loaded)
	defer snout_core.free_table(&out)
	testing.expect_value(t, err, snout_core.Error.None)

	path_out := write_tmp_snout(t, &out, "compact_out")
	defer os.remove(path_out)
	defer delete(path_out)

	reloaded := read_tmp_snout(t, path_out)
	defer snout_core.free_table(&reloaded)
	testing.expect_value(t, reloaded.row_count, 2)
	testing.expect_value(t, reloaded.columns[0].strings[0], "x")
	testing.expect_value(t, reloaded.columns[0].strings[1], "y")
}

// ---- regression: complex_metrics_500 fixture --------------------------------

@(test)
merge_complex_metrics_500_self_append :: proc(t: ^testing.T) {
	table, load_err := ingest.read_csv_table(
		"tests/fixtures/complex_metrics_500.csv",
		"complex_metrics",
	)
	testing.expect_value(t, load_err, snout_core.Error.None)
	if load_err != .None {
		return
	}
	defer snout_core.free_table(&table)

	snout_path := write_tmp_snout(t, &table, "cm500_merge")
	defer os.remove(snout_path)
	defer delete(snout_path)

	loaded := read_tmp_snout(t, snout_path)
	defer snout_core.free_table(&loaded)

	out, err := snout_merge.append_tables(&loaded, []^snout_core.Table{&loaded})
	defer snout_core.free_table(&out)
	testing.expect_value(t, err, snout_core.Error.None)
	testing.expect_value(t, out.row_count, 1000)
	testing.expect_value(t, len(out.columns), len(table.columns))
}

@(test)
merge_output_is_writable_and_readable :: proc(t: ^testing.T) {
	table, load_err := ingest.read_csv_table(
		"tests/fixtures/complex_metrics_500.csv",
		"complex_metrics",
	)
	testing.expect_value(t, load_err, snout_core.Error.None)
	if load_err != .None {
		return
	}
	defer snout_core.free_table(&table)

	snout_a := write_tmp_snout(t, &table, "wr_a")
	defer os.remove(snout_a)
	defer delete(snout_a)

	ta := read_tmp_snout(t, snout_a)
	defer snout_core.free_table(&ta)

	out, err := snout_merge.append_tables(&ta, []^snout_core.Table{&ta})
	defer snout_core.free_table(&out)
	testing.expect_value(t, err, snout_core.Error.None)

	snout_out := write_tmp_snout(t, &out, "wr_out")
	defer os.remove(snout_out)
	defer delete(snout_out)

	reloaded := read_tmp_snout(t, snout_out)
	defer snout_core.free_table(&reloaded)
	testing.expect_value(t, reloaded.row_count, 1000)
	testing.expect_value(t, len(reloaded.columns), len(table.columns))
}

// ---- error: missing file ----------------------------------------------------

@(test)
merge_source_file_not_found :: proc(t: ^testing.T) {
	_, err := storage.read_snout_file("/nonexistent/path.snout")
	testing.expect_value(t, err, snout_core.Error.Io)
}
