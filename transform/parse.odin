package transform

import "core:strconv"
import "core:strings"
import snout_core "../core"

// parse_transform_op parses a single CLI argument of the form "op=args".
// Supported forms:
//
//	rename=old:new
//	drop=col
//	cast=col:type          (type: int64 float64 bool string timestamp)
//	derive=out:left+right  (expr: left op right, op one of + - * /)
//	bucket=col:e0,e1,...:l0,l1,...:out_col
//	date_trunc=col:unit               (unit: year month day hour minute)
//	date_trunc=col:unit:out_col
//	regex_extract=col:pattern:N:out_col   (N is capture group index, 0=full match)
//	json_extract=col:key:out_col
parse_transform_op :: proc(arg: string) -> (op: Transform_Op, ok: bool) {
	eq := strings.index_byte(arg, '=')
	if eq <= 0 || eq == len(arg) - 1 {
		return nil, false
	}
	name := arg[:eq]
	rest := arg[eq + 1:]

	switch name {
	case "rename":
		parts := strings.split_n(rest, ":", 2, context.temp_allocator)
		if len(parts) != 2 || len(parts[0]) == 0 || len(parts[1]) == 0 {
			return nil, false
		}
		return Rename_Op{from = parts[0], to = parts[1]}, true

	case "drop":
		if len(rest) == 0 {return nil, false}
		return Drop_Op{column = rest}, true

	case "cast":
		parts := strings.split_n(rest, ":", 2, context.temp_allocator)
		if len(parts) != 2 {return nil, false}
		col_type, type_ok := parse_column_type(parts[1])
		if !type_ok {return nil, false}
		return Cast_Op{column = parts[0], to = col_type}, true

	case "derive":
		colon := strings.index_byte(rest, ':')
		if colon <= 0 || colon == len(rest) - 1 {return nil, false}
		out_name := rest[:colon]
		expr := rest[colon + 1:]
		return Derive_Op{out_name = out_name, expr = expr}, true

	case "bucket":
		// bucket=col:edges:labels:out_col
		parts := strings.split_n(rest, ":", 4, context.temp_allocator)
		if len(parts) != 4 {return nil, false}
		col := parts[0]
		out_col := parts[3]
		edge_strs := strings.split(parts[1], ",", context.temp_allocator)
		label_strs := strings.split(parts[2], ",", context.temp_allocator)
		if len(edge_strs) < 2 || len(label_strs) != len(edge_strs) - 1 {
			return nil, false
		}
		edges := make([]f64, len(edge_strs), context.temp_allocator)
		for s, i in edge_strs {
			v, parse_ok := strconv.parse_f64(s)
			if !parse_ok {return nil, false}
			edges[i] = v
		}
		return Bucket_Op{
			column     = col,
			out_column = out_col,
			edges      = edges,
			labels     = label_strs,
		}, true

	case "date_trunc":
		parts := strings.split_n(rest, ":", 3, context.temp_allocator)
		if len(parts) < 2 {return nil, false}
		col := parts[0]
		unit, unit_ok := parse_date_trunc_unit(parts[1])
		if !unit_ok {return nil, false}
		out_col := col if len(parts) < 3 else parts[2]
		return Date_Trunc_Op{column = col, out_column = out_col, unit = unit}, true

	case "regex_extract":
		// regex_extract=col:pattern:N:out_col
		// Pattern may not contain ':' in this simple parser.
		parts := strings.split_n(rest, ":", 4, context.temp_allocator)
		if len(parts) != 4 {return nil, false}
		n, n_ok := strconv.parse_int(parts[2])
		if !n_ok || n < 0 {return nil, false}
		return Regex_Extract_Op{
			column     = parts[0],
			pattern    = parts[1],
			out_column = parts[3],
			capture    = n,
		}, true

	case "json_extract":
		parts := strings.split_n(rest, ":", 3, context.temp_allocator)
		if len(parts) != 3 {return nil, false}
		return Json_Extract_Op{column = parts[0], key = parts[1], out_column = parts[2]}, true
	}
	return nil, false
}

@(private = "file")
parse_column_type :: proc(s: string) -> (snout_core.Column_Type, bool) {
	switch s {
	case "int64", "int":     return .Int64, true
	case "float64", "float": return .Float64, true
	case "bool":             return .Bool, true
	case "string":           return .String, true
	case "timestamp":        return .Timestamp, true
	}
	return .Unknown, false
}

@(private = "file")
parse_date_trunc_unit :: proc(s: string) -> (Date_Trunc_Unit, bool) {
	switch s {
	case "year":   return .Year, true
	case "month":  return .Month, true
	case "day":    return .Day, true
	case "hour":   return .Hour, true
	case "minute": return .Minute, true
	}
	return .Year, false
}
