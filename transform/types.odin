package transform

import snout_core "../core"

// Date_Trunc_Unit controls the precision to which a Timestamp column is truncated.
Date_Trunc_Unit :: enum {
	Year,
	Month,
	Day,
	Hour,
	Minute,
}

// Rename_Op renames a column without touching its data.
Rename_Op :: struct {
	from: string,
	to:   string,
}

// Drop_Op removes a column from the table.
Drop_Op :: struct {
	column: string,
}

// Cast_Op converts a column to a different type.
// Rows that fail to parse become null; the output column is always nullable
// when casting from String.
Cast_Op :: struct {
	column: string,
	to:     snout_core.Column_Type,
}

// Derive_Op appends a new column computed from a binary expression.
// expr is "left op right" where left and right are column names or numeric
// literals, and op is one of + - * /.  Division always produces Float64.
// Division by zero produces null.
Derive_Op :: struct {
	out_name: string,
	expr:     string,
}

// Bucket_Op bins a numeric (Int64 or Float64) column into labeled string
// ranges and appends the result as a new column.
// edges defines N boundary values; labels must have exactly N-1 entries.
// [edges[i], edges[i+1]) maps to labels[i]. Values outside [edges[0],
// edges[N-1]) become null.
Bucket_Op :: struct {
	column:     string,
	out_column: string,
	edges:      []f64,
	labels:     []string,
}

// Date_Trunc_Op truncates a Timestamp or String column to the given unit
// and writes the result into out_column (appended if out_column != column,
// replaced in-place if equal).
// Input strings must be ISO-8601 (YYYY-MM-DDTHH:MM:SSZ). Malformed rows
// become null in the output.
Date_Trunc_Op :: struct {
	column:     string,
	out_column: string,
	unit:       Date_Trunc_Unit,
}

// Regex_Extract_Op applies a compiled regex to a String column and writes
// capture group `capture` (1-based) into out_column.
// Non-matching rows produce null. capture=0 returns the full match.
Regex_Extract_Op :: struct {
	column:     string,
	pattern:    string,
	out_column: string,
	capture:    int,
}

// Json_Extract_Op parses each cell of a String column as a JSON object and
// extracts the value at `key` (top-level only) as a String.
// Null, missing keys, or parse errors produce null.
Json_Extract_Op :: struct {
	column:     string,
	key:        string,
	out_column: string,
}

// Transform_Op is the discriminated union of all supported transforms.
Transform_Op :: union {
	Rename_Op,
	Drop_Op,
	Cast_Op,
	Derive_Op,
	Bucket_Op,
	Date_Trunc_Op,
	Regex_Extract_Op,
	Json_Extract_Op,
}
