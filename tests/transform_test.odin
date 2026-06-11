package tests

import "core:strings"
import "core:testing"
import snout_core "../core"
import xform "../transform"

// ---- helpers ----------------------------------------------------------------

@(private = "file")
make_str_col_xf :: proc(name: string, values: []string, allocator := context.allocator) -> snout_core.Column {
	col: snout_core.Column
	col.name = strings.clone(name, allocator)
	col.kind = .String
	col.nullable = false
	col.null_mask, _ = make([]bool, len(values), allocator)
	col.strings, _ = make([]string, len(values), allocator)
	for v, i in values { col.strings[i] = strings.clone(v, allocator) }
	return col
}

@(private = "file")
make_i64_col_xf :: proc(name: string, values: []i64, allocator := context.allocator) -> snout_core.Column {
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
make_f64_col_xf :: proc(name: string, values: []f64, allocator := context.allocator) -> snout_core.Column {
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
make_ts_col_xf :: proc(name: string, values: []string, allocator := context.allocator) -> snout_core.Column {
	col: snout_core.Column
	col.name = strings.clone(name, allocator)
	col.kind = .Timestamp
	col.nullable = false
	col.null_mask, _ = make([]bool, len(values), allocator)
	col.strings, _ = make([]string, len(values), allocator)
	for v, i in values { col.strings[i] = strings.clone(v, allocator) }
	return col
}

@(private = "file")
build_xf_table :: proc(name: string, cols: []snout_core.Column) -> snout_core.Table {
	t: snout_core.Table
	t.allocator = context.allocator
	t.row_count = len(cols[0].null_mask)
	t.name, _ = strings.clone(name)
	t.columns, _ = make([]snout_core.Column, len(cols))
	copy(t.columns, cols)
	return t
}

// ---- rename ----------------------------------------------------------------

@(test)
transform_rename_changes_column_name :: proc(t: ^testing.T) {
	src := build_xf_table("t", {make_i64_col_xf("old_name", {1, 2, 3})})
	defer snout_core.free_table(&src)

	result, err := xform.apply_transform(&src, xform.Rename_Op{from = "old_name", to = "new_name"})
	testing.expect(t, err == .None)
	defer snout_core.free_table(&result)

	testing.expect_value(t, result.columns[0].name, "new_name")
	testing.expect_value(t, result.columns[0].int64s[1], i64(2))
}

@(test)
transform_rename_missing_column_errors :: proc(t: ^testing.T) {
	src := build_xf_table("t", {make_i64_col_xf("a", {1})})
	defer snout_core.free_table(&src)

	_, err := xform.apply_transform(&src, xform.Rename_Op{from = "nope", to = "x"})
	testing.expect_value(t, err, snout_core.Error.Column_Not_Found)
}

// ---- drop ------------------------------------------------------------------

@(test)
transform_drop_removes_column :: proc(t: ^testing.T) {
	src := build_xf_table("t", {
		make_i64_col_xf("keep", {10, 20}),
		make_str_col_xf("remove", {"a", "b"}),
	})
	defer snout_core.free_table(&src)

	result, err := xform.apply_transform(&src, xform.Drop_Op{column = "remove"})
	testing.expect(t, err == .None)
	defer snout_core.free_table(&result)

	testing.expect_value(t, len(result.columns), 1)
	testing.expect_value(t, result.columns[0].name, "keep")
}

@(test)
transform_drop_missing_column_errors :: proc(t: ^testing.T) {
	src := build_xf_table("t", {make_i64_col_xf("a", {1})})
	defer snout_core.free_table(&src)

	_, err := xform.apply_transform(&src, xform.Drop_Op{column = "nope"})
	testing.expect_value(t, err, snout_core.Error.Column_Not_Found)
}

// ---- cast ------------------------------------------------------------------

@(test)
transform_cast_string_to_int64 :: proc(t: ^testing.T) {
	src := build_xf_table("t", {make_str_col_xf("n", {"10", "20", "30"})})
	defer snout_core.free_table(&src)

	result, err := xform.apply_transform(&src, xform.Cast_Op{column = "n", to = .Int64})
	testing.expect(t, err == .None)
	defer snout_core.free_table(&result)

	testing.expect_value(t, result.columns[0].kind, snout_core.Column_Type.Int64)
	testing.expect_value(t, result.columns[0].int64s[0], i64(10))
	testing.expect_value(t, result.columns[0].int64s[2], i64(30))
}

@(test)
transform_cast_string_to_float64 :: proc(t: ^testing.T) {
	src := build_xf_table("t", {make_str_col_xf("v", {"1.5", "2.5"})})
	defer snout_core.free_table(&src)

	result, err := xform.apply_transform(&src, xform.Cast_Op{column = "v", to = .Float64})
	testing.expect(t, err == .None)
	defer snout_core.free_table(&result)

	testing.expect_value(t, result.columns[0].kind, snout_core.Column_Type.Float64)
	testing.expect_value(t, result.columns[0].float64s[0], f64(1.5))
}

@(test)
transform_cast_invalid_string_becomes_null :: proc(t: ^testing.T) {
	src := build_xf_table("t", {make_str_col_xf("n", {"42", "bad", "7"})})
	defer snout_core.free_table(&src)

	result, err := xform.apply_transform(&src, xform.Cast_Op{column = "n", to = .Int64})
	testing.expect(t, err == .None)
	defer snout_core.free_table(&result)

	testing.expect_value(t, result.columns[0].nullable, true)
	testing.expect_value(t, result.columns[0].null_mask[0], false)
	testing.expect_value(t, result.columns[0].null_mask[1], true)
	testing.expect_value(t, result.columns[0].int64s[0], i64(42))
	testing.expect_value(t, result.columns[0].int64s[2], i64(7))
}

@(test)
transform_cast_int64_to_float64 :: proc(t: ^testing.T) {
	src := build_xf_table("t", {make_i64_col_xf("v", {1, 2, 3})})
	defer snout_core.free_table(&src)

	result, err := xform.apply_transform(&src, xform.Cast_Op{column = "v", to = .Float64})
	testing.expect(t, err == .None)
	defer snout_core.free_table(&result)

	testing.expect_value(t, result.columns[0].kind, snout_core.Column_Type.Float64)
	testing.expect_value(t, result.columns[0].float64s[1], f64(2.0))
}

@(test)
transform_cast_int64_to_string :: proc(t: ^testing.T) {
	src := build_xf_table("t", {make_i64_col_xf("id", {100, 200})})
	defer snout_core.free_table(&src)

	result, err := xform.apply_transform(&src, xform.Cast_Op{column = "id", to = .String})
	testing.expect(t, err == .None)
	defer snout_core.free_table(&result)

	testing.expect_value(t, result.columns[0].kind, snout_core.Column_Type.String)
	testing.expect_value(t, result.columns[0].strings[0], "100")
	testing.expect_value(t, result.columns[0].strings[1], "200")
}

@(test)
transform_cast_string_to_bool :: proc(t: ^testing.T) {
	src := build_xf_table("t", {make_str_col_xf("flag", {"true", "false", "yes", "no", "bad"})})
	defer snout_core.free_table(&src)

	result, err := xform.apply_transform(&src, xform.Cast_Op{column = "flag", to = .Bool})
	testing.expect(t, err == .None)
	defer snout_core.free_table(&result)

	testing.expect_value(t, result.columns[0].bools[0], true)
	testing.expect_value(t, result.columns[0].bools[1], false)
	testing.expect_value(t, result.columns[0].bools[2], true)
	testing.expect_value(t, result.columns[0].bools[3], false)
	testing.expect_value(t, result.columns[0].null_mask[4], true)
}

// ---- derive ----------------------------------------------------------------

@(test)
transform_derive_add_two_int_columns :: proc(t: ^testing.T) {
	src := build_xf_table("t", {
		make_i64_col_xf("a", {1, 2, 3}),
		make_i64_col_xf("b", {10, 20, 30}),
	})
	defer snout_core.free_table(&src)

	result, err := xform.apply_transform(&src, xform.Derive_Op{out_name = "total", expr = "a+b"})
	testing.expect(t, err == .None)
	defer snout_core.free_table(&result)

	testing.expect_value(t, len(result.columns), 3)
	testing.expect_value(t, result.columns[2].name, "total")
	testing.expect_value(t, result.columns[2].kind, snout_core.Column_Type.Int64)
	testing.expect_value(t, result.columns[2].int64s[0], i64(11))
	testing.expect_value(t, result.columns[2].int64s[2], i64(33))
}

@(test)
transform_derive_multiply_col_by_literal :: proc(t: ^testing.T) {
	src := build_xf_table("t", {make_i64_col_xf("price", {10, 20, 30})})
	defer snout_core.free_table(&src)

	result, err := xform.apply_transform(&src, xform.Derive_Op{out_name = "doubled", expr = "price*2"})
	testing.expect(t, err == .None)
	defer snout_core.free_table(&result)

	testing.expect_value(t, result.columns[1].int64s[0], i64(20))
	testing.expect_value(t, result.columns[1].int64s[2], i64(60))
}

@(test)
transform_derive_division_produces_float :: proc(t: ^testing.T) {
	src := build_xf_table("t", {
		make_i64_col_xf("total", {10, 20}),
		make_i64_col_xf("count", {4, 5}),
	})
	defer snout_core.free_table(&src)

	result, err := xform.apply_transform(&src, xform.Derive_Op{out_name = "avg", expr = "total/count"})
	testing.expect(t, err == .None)
	defer snout_core.free_table(&result)

	testing.expect_value(t, result.columns[2].kind, snout_core.Column_Type.Float64)
	testing.expect_value(t, result.columns[2].float64s[0], f64(2.5))
	testing.expect_value(t, result.columns[2].float64s[1], f64(4.0))
}

@(test)
transform_derive_division_by_zero_is_null :: proc(t: ^testing.T) {
	src := build_xf_table("t", {
		make_i64_col_xf("a", {10, 20}),
		make_i64_col_xf("b", {0, 4}),
	})
	defer snout_core.free_table(&src)

	result, err := xform.apply_transform(&src, xform.Derive_Op{out_name = "r", expr = "a/b"})
	testing.expect(t, err == .None)
	defer snout_core.free_table(&result)

	testing.expect_value(t, result.columns[2].null_mask[0], true)
	testing.expect_value(t, result.columns[2].null_mask[1], false)
	testing.expect_value(t, result.columns[2].float64s[1], f64(5.0))
}

@(test)
transform_derive_float_operand_upgrades_result :: proc(t: ^testing.T) {
	src := build_xf_table("t", {make_f64_col_xf("x", {1.5, 2.5})})
	defer snout_core.free_table(&src)

	result, err := xform.apply_transform(&src, xform.Derive_Op{out_name = "y", expr = "x*2"})
	testing.expect(t, err == .None)
	defer snout_core.free_table(&result)

	testing.expect_value(t, result.columns[1].kind, snout_core.Column_Type.Float64)
	testing.expect_value(t, result.columns[1].float64s[0], f64(3.0))
}

// ---- bucket ----------------------------------------------------------------

@(test)
transform_bucket_bins_values :: proc(t: ^testing.T) {
	src := build_xf_table("t", {make_i64_col_xf("latency", {5, 50, 200, 600})})
	defer snout_core.free_table(&src)

	op := xform.Bucket_Op{
		column     = "latency",
		out_column = "tier",
		edges      = {0, 100, 500},
		labels     = {"fast", "medium"},
	}
	result, err := xform.apply_transform(&src, op)
	testing.expect(t, err == .None)
	defer snout_core.free_table(&result)

	testing.expect_value(t, result.columns[1].strings[0], "fast")
	testing.expect_value(t, result.columns[1].strings[1], "fast")
	testing.expect_value(t, result.columns[1].strings[2], "medium")
	// 600 >= 500 → out of range → null
	testing.expect_value(t, result.columns[1].null_mask[3], true)
}

@(test)
transform_bucket_wrong_edge_label_count_errors :: proc(t: ^testing.T) {
	src := build_xf_table("t", {make_i64_col_xf("v", {1})})
	defer snout_core.free_table(&src)

	op := xform.Bucket_Op{
		column = "v", out_column = "b",
		edges  = {0, 100},
		labels = {"a", "b"}, // should be 1 label for 2 edges
	}
	_, err := xform.apply_transform(&src, op)
	testing.expect_value(t, err, snout_core.Error.Malformed_Query_Arguments)
}

// ---- date_trunc ------------------------------------------------------------

@(test)
transform_date_trunc_to_day :: proc(t: ^testing.T) {
	src := build_xf_table("t", {
		make_ts_col_xf("ts", {"2026-06-11T10:30:00Z", "2026-06-12T23:59:59Z"}),
	})
	defer snout_core.free_table(&src)

	op := xform.Date_Trunc_Op{column = "ts", out_column = "ts", unit = .Day}
	result, err := xform.apply_transform(&src, op)
	testing.expect(t, err == .None)
	defer snout_core.free_table(&result)

	testing.expect_value(t, result.columns[0].strings[0], "2026-06-11T00:00:00Z")
	testing.expect_value(t, result.columns[0].strings[1], "2026-06-12T00:00:00Z")
}

@(test)
transform_date_trunc_to_month_new_column :: proc(t: ^testing.T) {
	src := build_xf_table("t", {
		make_ts_col_xf("ts", {"2026-06-11T10:30:00Z"}),
		make_i64_col_xf("v", {42}),
	})
	defer snout_core.free_table(&src)

	op := xform.Date_Trunc_Op{column = "ts", out_column = "month", unit = .Month}
	result, err := xform.apply_transform(&src, op)
	testing.expect(t, err == .None)
	defer snout_core.free_table(&result)

	testing.expect_value(t, len(result.columns), 3)
	testing.expect_value(t, result.columns[2].name, "month")
	testing.expect_value(t, result.columns[2].strings[0], "2026-06-01T00:00:00Z")
}

@(test)
transform_date_trunc_to_year :: proc(t: ^testing.T) {
	src := build_xf_table("t", {make_ts_col_xf("ts", {"2026-06-11T10:30:00Z"})})
	defer snout_core.free_table(&src)

	op := xform.Date_Trunc_Op{column = "ts", out_column = "ts", unit = .Year}
	result, err := xform.apply_transform(&src, op)
	testing.expect(t, err == .None)
	defer snout_core.free_table(&result)

	testing.expect_value(t, result.columns[0].strings[0], "2026-01-01T00:00:00Z")
}

@(test)
transform_date_trunc_to_hour :: proc(t: ^testing.T) {
	src := build_xf_table("t", {make_ts_col_xf("ts", {"2026-06-11T10:30:45Z"})})
	defer snout_core.free_table(&src)

	op := xform.Date_Trunc_Op{column = "ts", out_column = "ts", unit = .Hour}
	result, err := xform.apply_transform(&src, op)
	testing.expect(t, err == .None)
	defer snout_core.free_table(&result)

	testing.expect_value(t, result.columns[0].strings[0], "2026-06-11T10:00:00Z")
}

// ---- regex_extract ---------------------------------------------------------

@(test)
transform_regex_extract_capture_group :: proc(t: ^testing.T) {
	src := build_xf_table("t", {
		make_str_col_xf("url", {"/users/42/profile", "/users/7/settings", "/home"}),
	})
	defer snout_core.free_table(&src)

	op := xform.Regex_Extract_Op{
		column     = "url",
		pattern    = `/users/([0-9]+)/`,
		out_column = "user_id",
		capture    = 1,
	}
	result, err := xform.apply_transform(&src, op)
	testing.expect(t, err == .None)
	defer snout_core.free_table(&result)

	testing.expect_value(t, result.columns[1].strings[0], "42")
	testing.expect_value(t, result.columns[1].strings[1], "7")
	testing.expect_value(t, result.columns[1].null_mask[2], true) // no match
}

@(test)
transform_regex_extract_full_match :: proc(t: ^testing.T) {
	src := build_xf_table("t", {make_str_col_xf("s", {"hello world", "foo"})})
	defer snout_core.free_table(&src)

	op := xform.Regex_Extract_Op{
		column = "s", pattern = `[a-z]+`, out_column = "word", capture = 0,
	}
	result, err := xform.apply_transform(&src, op)
	testing.expect(t, err == .None)
	defer snout_core.free_table(&result)

	testing.expect_value(t, result.columns[1].strings[0], "hello")
	testing.expect_value(t, result.columns[1].strings[1], "foo")
}

@(test)
transform_regex_invalid_pattern_errors :: proc(t: ^testing.T) {
	src := build_xf_table("t", {make_str_col_xf("s", {"a"})})
	defer snout_core.free_table(&src)

	op := xform.Regex_Extract_Op{column = "s", pattern = `[invalid`, out_column = "x", capture = 1}
	_, err := xform.apply_transform(&src, op)
	testing.expect_value(t, err, snout_core.Error.Malformed_Query_Arguments)
}

// ---- json_extract ----------------------------------------------------------

@(test)
transform_json_extract_string_value :: proc(t: ^testing.T) {
	src := build_xf_table("t", {
		make_str_col_xf("payload", {
			`{"user":"alice","status":"ok"}`,
			`{"user":"bob","status":"error"}`,
		}),
	})
	defer snout_core.free_table(&src)

	op := xform.Json_Extract_Op{column = "payload", key = "user", out_column = "user"}
	result, err := xform.apply_transform(&src, op)
	testing.expect(t, err == .None)
	defer snout_core.free_table(&result)

	testing.expect_value(t, result.columns[1].strings[0], "alice")
	testing.expect_value(t, result.columns[1].strings[1], "bob")
}

@(test)
transform_json_extract_numeric_value :: proc(t: ^testing.T) {
	src := build_xf_table("t", {make_str_col_xf("j", {`{"code":200}`, `{"code":404}`})})
	defer snout_core.free_table(&src)

	op := xform.Json_Extract_Op{column = "j", key = "code", out_column = "code"}
	result, err := xform.apply_transform(&src, op)
	testing.expect(t, err == .None)
	defer snout_core.free_table(&result)

	testing.expect_value(t, result.columns[1].strings[0], "200")
	testing.expect_value(t, result.columns[1].strings[1], "404")
}

@(test)
transform_json_extract_missing_key_is_null :: proc(t: ^testing.T) {
	src := build_xf_table("t", {
		make_str_col_xf("j", {`{"a":1}`, `{"b":2}`}),
	})
	defer snout_core.free_table(&src)

	op := xform.Json_Extract_Op{column = "j", key = "a", out_column = "a"}
	result, err := xform.apply_transform(&src, op)
	testing.expect(t, err == .None)
	defer snout_core.free_table(&result)

	testing.expect_value(t, result.columns[1].strings[0], "1")
	testing.expect_value(t, result.columns[1].null_mask[1], true)
}

// ---- apply_transforms (chaining) -------------------------------------------

@(test)
transform_chain_rename_then_cast :: proc(t: ^testing.T) {
	src := build_xf_table("t", {make_str_col_xf("raw_score", {"10", "20", "30"})})
	defer snout_core.free_table(&src)

	ops := []xform.Transform_Op{
		xform.Rename_Op{from = "raw_score", to = "score"},
		xform.Cast_Op{column = "score", to = .Int64},
	}
	result, err := xform.apply_transforms(&src, ops)
	testing.expect(t, err == .None)
	defer snout_core.free_table(&result)

	testing.expect_value(t, result.columns[0].name, "score")
	testing.expect_value(t, result.columns[0].kind, snout_core.Column_Type.Int64)
	testing.expect_value(t, result.columns[0].int64s[1], i64(20))
}

@(test)
transform_chain_drop_then_derive :: proc(t: ^testing.T) {
	src := build_xf_table("t", {
		make_i64_col_xf("price", {10, 20}),
		make_i64_col_xf("qty", {3, 5}),
		make_str_col_xf("note", {"x", "y"}),
	})
	defer snout_core.free_table(&src)

	ops := []xform.Transform_Op{
		xform.Drop_Op{column = "note"},
		xform.Derive_Op{out_name = "revenue", expr = "price*qty"},
	}
	result, err := xform.apply_transforms(&src, ops)
	testing.expect(t, err == .None)
	defer snout_core.free_table(&result)

	testing.expect_value(t, len(result.columns), 3)
	testing.expect_value(t, result.columns[2].name, "revenue")
	testing.expect_value(t, result.columns[2].int64s[0], i64(30))
	testing.expect_value(t, result.columns[2].int64s[1], i64(100))
}

@(test)
transform_empty_ops_returns_copy :: proc(t: ^testing.T) {
	src := build_xf_table("t", {make_i64_col_xf("v", {1, 2})})
	defer snout_core.free_table(&src)

	result, err := xform.apply_transforms(&src, {})
	testing.expect(t, err == .None)
	defer snout_core.free_table(&result)

	testing.expect_value(t, result.columns[0].int64s[0], i64(1))
}

// ---- parse_transform_op ----------------------------------------------------

@(test)
transform_parse_rename :: proc(t: ^testing.T) {
	op, ok := xform.parse_transform_op("rename=old:new")
	testing.expect(t, ok)
	r, is_rename := op.(xform.Rename_Op)
	testing.expect(t, is_rename)
	testing.expect_value(t, r.from, "old")
	testing.expect_value(t, r.to, "new")
}

@(test)
transform_parse_cast :: proc(t: ^testing.T) {
	op, ok := xform.parse_transform_op("cast=price:float64")
	testing.expect(t, ok)
	c, is_cast := op.(xform.Cast_Op)
	testing.expect(t, is_cast)
	testing.expect_value(t, c.column, "price")
	testing.expect_value(t, c.to, snout_core.Column_Type.Float64)
}

@(test)
transform_parse_derive :: proc(t: ^testing.T) {
	op, ok := xform.parse_transform_op("derive=revenue:price*qty")
	testing.expect(t, ok)
	d, is_derive := op.(xform.Derive_Op)
	testing.expect(t, is_derive)
	testing.expect_value(t, d.out_name, "revenue")
	testing.expect_value(t, d.expr, "price*qty")
}

@(test)
transform_parse_bucket :: proc(t: ^testing.T) {
	op, ok := xform.parse_transform_op("bucket=latency:0,100,500:fast,medium:tier")
	testing.expect(t, ok)
	b, is_bucket := op.(xform.Bucket_Op)
	testing.expect(t, is_bucket)
	testing.expect_value(t, b.column, "latency")
	testing.expect_value(t, b.out_column, "tier")
	testing.expect_value(t, len(b.edges), 3)
	testing.expect_value(t, len(b.labels), 2)
}

@(test)
transform_parse_date_trunc_inplace :: proc(t: ^testing.T) {
	op, ok := xform.parse_transform_op("date_trunc=ts:day")
	testing.expect(t, ok)
	d, is_dt := op.(xform.Date_Trunc_Op)
	testing.expect(t, is_dt)
	testing.expect_value(t, d.column, "ts")
	testing.expect_value(t, d.out_column, "ts")
	testing.expect_value(t, d.unit, xform.Date_Trunc_Unit.Day)
}

@(test)
transform_parse_date_trunc_new_col :: proc(t: ^testing.T) {
	op, ok := xform.parse_transform_op("date_trunc=ts:month:month_col")
	testing.expect(t, ok)
	d, is_dt := op.(xform.Date_Trunc_Op)
	testing.expect(t, is_dt)
	testing.expect_value(t, d.out_column, "month_col")
}

@(test)
transform_parse_regex_extract :: proc(t: ^testing.T) {
	op, ok := xform.parse_transform_op(`regex_extract=url:/users/([0-9]+)/:1:uid`)
	testing.expect(t, ok)
	r, is_re := op.(xform.Regex_Extract_Op)
	testing.expect(t, is_re)
	testing.expect_value(t, r.column, "url")
	testing.expect_value(t, r.capture, 1)
	testing.expect_value(t, r.out_column, "uid")
}

@(test)
transform_parse_json_extract :: proc(t: ^testing.T) {
	op, ok := xform.parse_transform_op("json_extract=payload:user:user_id")
	testing.expect(t, ok)
	j, is_jx := op.(xform.Json_Extract_Op)
	testing.expect(t, is_jx)
	testing.expect_value(t, j.column, "payload")
	testing.expect_value(t, j.key, "user")
	testing.expect_value(t, j.out_column, "user_id")
}

@(test)
transform_parse_invalid_returns_false :: proc(t: ^testing.T) {
	_, ok1 := xform.parse_transform_op("notanop=x")
	testing.expect(t, !ok1)
	_, ok2 := xform.parse_transform_op("rename=only_one_part")
	testing.expect(t, !ok2)
	_, ok3 := xform.parse_transform_op("cast=col:badtype")
	testing.expect(t, !ok3)
}
