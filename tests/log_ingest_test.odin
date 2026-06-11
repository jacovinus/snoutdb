package tests

import "core:testing"
import ingest "../ingest"
import snout_core "../core"

// ---- CLF tests --------------------------------------------------------------

@(test)
clf_inspect_schema :: proc(t: ^testing.T) {
	opts := ingest.Log_Read_Options{format = .CLF}
	schema, err := ingest.inspect_log_file("tests/fixtures/access.log", "access", opts)
	defer ingest.free_log_file_schema(&schema)
	testing.expect_value(t, err, snout_core.Error.None)
	testing.expect_value(t, schema.row_count, 4)
	testing.expect_value(t, schema.parse_errors, 0)
	testing.expect_value(t, len(schema.columns), 9)
	testing.expect_value(t, schema.columns[0].name, "remote_host")
	testing.expect_value(t, schema.columns[0].kind, snout_core.Column_Type.String)
	testing.expect_value(t, schema.columns[3].name, "time")
	testing.expect_value(t, schema.columns[3].kind, snout_core.Column_Type.Timestamp)
	testing.expect_value(t, schema.columns[7].name, "status")
	testing.expect_value(t, schema.columns[7].kind, snout_core.Column_Type.Int64)
	testing.expect_value(t, schema.columns[8].name, "bytes")
	testing.expect_value(t, schema.columns[8].nullable, true)
}

@(test)
clf_populate_table :: proc(t: ^testing.T) {
	opts := ingest.Log_Read_Options{format = .CLF}
	table, err := ingest.read_log_table("tests/fixtures/access.log", "access", opts)
	defer snout_core.free_table(&table)
	testing.expect_value(t, err, snout_core.Error.None)
	testing.expect_value(t, table.row_count, 4)
	testing.expect_value(t, len(table.columns), 9)

	// Check remote_host column
	host_col, host_found := snout_core.get_column(&table, "remote_host")
	testing.expect(t, host_found, "remote_host column missing")
	if host_found {
		testing.expect_value(t, host_col.strings[0], "127.0.0.1")
		testing.expect_value(t, host_col.strings[1], "192.168.1.1")
		testing.expect_value(t, host_col.null_mask[0], false)
	}
}

@(test)
clf_timestamp_utc_conversion :: proc(t: ^testing.T) {
	opts := ingest.Log_Read_Options{format = .CLF}
	table, err := ingest.read_log_table("tests/fixtures/access.log", "access", opts)
	defer snout_core.free_table(&table)
	testing.expect_value(t, err, snout_core.Error.None)

	time_col, found := snout_core.get_column(&table, "time")
	testing.expect(t, found, "time column missing")
	if found {
		// 10/Oct/2000:13:55:36 -0700 → UTC = 20:55:36
		testing.expect_value(t, time_col.strings[0], "2000-10-10T20:55:36Z")
	}
}

@(test)
clf_null_bytes_column :: proc(t: ^testing.T) {
	opts := ingest.Log_Read_Options{format = .CLF}
	table, err := ingest.read_log_table("tests/fixtures/access.log", "access", opts)
	defer snout_core.free_table(&table)
	testing.expect_value(t, err, snout_core.Error.None)

	bytes_col, found := snout_core.get_column(&table, "bytes")
	testing.expect(t, found, "bytes column missing")
	if found {
		testing.expect_value(t, bytes_col.null_mask[0], false)
		testing.expect_value(t, bytes_col.int64s[0], i64(2326))
		// Row 3 (404): bytes is "-" → null
		testing.expect_value(t, bytes_col.null_mask[3], true)
	}
}

@(test)
clf_status_int64 :: proc(t: ^testing.T) {
	opts := ingest.Log_Read_Options{format = .CLF}
	table, err := ingest.read_log_table("tests/fixtures/access.log", "access", opts)
	defer snout_core.free_table(&table)
	testing.expect_value(t, err, snout_core.Error.None)

	status_col, found := snout_core.get_column(&table, "status")
	testing.expect(t, found, "status column missing")
	if found {
		testing.expect_value(t, status_col.int64s[0], i64(200))
		testing.expect_value(t, status_col.int64s[1], i64(401))
		testing.expect_value(t, status_col.int64s[3], i64(404))
	}
}

// ---- Combined tests ---------------------------------------------------------

@(test)
combined_inspect_schema :: proc(t: ^testing.T) {
	opts := ingest.Log_Read_Options{format = .Combined}
	schema, err := ingest.inspect_log_file("tests/fixtures/combined.log", "combined", opts)
	defer ingest.free_log_file_schema(&schema)
	testing.expect_value(t, err, snout_core.Error.None)
	testing.expect_value(t, schema.row_count, 3)
	testing.expect_value(t, len(schema.columns), 11)
	testing.expect_value(t, schema.columns[9].name, "referer")
	testing.expect_value(t, schema.columns[10].name, "user_agent")
}

@(test)
combined_populate_user_agent :: proc(t: ^testing.T) {
	opts := ingest.Log_Read_Options{format = .Combined}
	table, err := ingest.read_log_table("tests/fixtures/combined.log", "combined", opts)
	defer snout_core.free_table(&table)
	testing.expect_value(t, err, snout_core.Error.None)

	ua_col, found := snout_core.get_column(&table, "user_agent")
	testing.expect(t, found, "user_agent column missing")
	if found {
		testing.expect_value(t, ua_col.strings[0], "Mozilla/5.0")
		testing.expect_value(t, ua_col.strings[1], "curl/7.68.0")
	}

	ref_col, ref_found := snout_core.get_column(&table, "referer")
	testing.expect(t, ref_found, "referer column missing")
	if ref_found {
		testing.expect_value(t, ref_col.null_mask[1], true) // "-" → null
	}
}

// ---- Logfmt tests -----------------------------------------------------------

@(test)
logfmt_inspect_schema :: proc(t: ^testing.T) {
	opts := ingest.Log_Read_Options{format = .Logfmt}
	schema, err := ingest.inspect_log_file("tests/fixtures/app.log", "app", opts)
	defer ingest.free_log_file_schema(&schema)
	testing.expect_value(t, err, snout_core.Error.None)
	testing.expect_value(t, schema.row_count, 4)
	testing.expect_value(t, schema.parse_errors, 0)

	// ts key should be Timestamp type
	ts_idx, ts_found := schema.column_indexes["ts"]
	testing.expect(t, ts_found, "ts column missing from schema")
	if ts_found {
		testing.expect_value(t, schema.columns[ts_idx].kind, snout_core.Column_Type.Timestamp)
	}

	// latency_ms should be Int64
	lat_idx, lat_found := schema.column_indexes["latency_ms"]
	testing.expect(t, lat_found, "latency_ms column missing")
	if lat_found {
		testing.expect_value(t, schema.columns[lat_idx].kind, snout_core.Column_Type.Int64)
	}

	// ok should be Bool
	ok_idx, ok_found := schema.column_indexes["ok"]
	testing.expect(t, ok_found, "ok column missing")
	if ok_found {
		testing.expect_value(t, schema.columns[ok_idx].kind, snout_core.Column_Type.Bool)
	}
}

@(test)
logfmt_populate_values :: proc(t: ^testing.T) {
	opts := ingest.Log_Read_Options{format = .Logfmt}
	table, err := ingest.read_log_table("tests/fixtures/app.log", "app", opts)
	defer snout_core.free_table(&table)
	testing.expect_value(t, err, snout_core.Error.None)
	testing.expect_value(t, table.row_count, 4)

	lat_col, lat_found := snout_core.get_column(&table, "latency_ms")
	testing.expect(t, lat_found, "latency_ms missing")
	if lat_found {
		testing.expect_value(t, lat_col.int64s[1], i64(1240))
		testing.expect_value(t, lat_col.int64s[2], i64(850))
	}

	ok_col, ok_found := snout_core.get_column(&table, "ok")
	testing.expect(t, ok_found, "ok column missing")
	if ok_found {
		testing.expect_value(t, ok_col.bools[1], false)
		testing.expect_value(t, ok_col.bools[2], true)
	}
}

@(test)
logfmt_nullable_absent_key :: proc(t: ^testing.T) {
	opts := ingest.Log_Read_Options{format = .Logfmt}
	schema, err := ingest.inspect_log_file("tests/fixtures/app.log", "app", opts)
	defer ingest.free_log_file_schema(&schema)
	testing.expect_value(t, err, snout_core.Error.None)

	// pid only appears in some lines — first line has port=8080 pid=1234, others don't
	pid_idx, pid_found := schema.column_indexes["pid"]
	if pid_found {
		testing.expect(t, schema.columns[pid_idx].nullable, "pid column should be nullable")
	}
}

// ---- Syslog tests -----------------------------------------------------------

@(test)
syslog_inspect_schema :: proc(t: ^testing.T) {
	opts := ingest.Log_Read_Options{format = .Syslog}
	schema, err := ingest.inspect_log_file("tests/fixtures/syslog.log", "syslog", opts)
	defer ingest.free_log_file_schema(&schema)
	testing.expect_value(t, err, snout_core.Error.None)
	testing.expect_value(t, schema.row_count, 4)
	testing.expect_value(t, len(schema.columns), 5)
	testing.expect_value(t, schema.columns[0].name, "timestamp")
	testing.expect_value(t, schema.columns[0].kind, snout_core.Column_Type.Timestamp)
	testing.expect_value(t, schema.columns[3].name, "pid")
	testing.expect_value(t, schema.columns[3].kind, snout_core.Column_Type.Int64)
	testing.expect_value(t, schema.columns[3].nullable, true)
}

@(test)
syslog_populate_pid_nullable :: proc(t: ^testing.T) {
	opts := ingest.Log_Read_Options{format = .Syslog}
	table, err := ingest.read_log_table("tests/fixtures/syslog.log", "syslog", opts)
	defer snout_core.free_table(&table)
	testing.expect_value(t, err, snout_core.Error.None)

	pid_col, found := snout_core.get_column(&table, "pid")
	testing.expect(t, found, "pid column missing")
	if found {
		testing.expect_value(t, pid_col.null_mask[0], false)
		testing.expect_value(t, pid_col.int64s[0], i64(1234))
		// Row 3: "myapp:" with no pid → null
		testing.expect_value(t, pid_col.null_mask[3], true)
	}
}

@(test)
syslog_timestamp_format :: proc(t: ^testing.T) {
	opts := ingest.Log_Read_Options{format = .Syslog}
	table, err := ingest.read_log_table("tests/fixtures/syslog.log", "syslog", opts)
	defer snout_core.free_table(&table)
	testing.expect_value(t, err, snout_core.Error.None)

	ts_col, found := snout_core.get_column(&table, "timestamp")
	testing.expect(t, found, "timestamp column missing")
	if found {
		// Jun 11 10:00:01 → 0000-06-11T10:00:01
		testing.expect_value(t, ts_col.strings[0], "0000-06-11T10:00:01")
	}
}

// ---- Auto-detection tests ---------------------------------------------------

@(test)
detect_clf_format :: proc(t: ^testing.T) {
	format, err := ingest.detect_log_format("tests/fixtures/access.log")
	testing.expect_value(t, err, snout_core.Error.None)
	testing.expect_value(t, format, ingest.Log_Format.CLF)
}

@(test)
detect_combined_format :: proc(t: ^testing.T) {
	format, err := ingest.detect_log_format("tests/fixtures/combined.log")
	testing.expect_value(t, err, snout_core.Error.None)
	testing.expect_value(t, format, ingest.Log_Format.Combined)
}

@(test)
detect_logfmt_format :: proc(t: ^testing.T) {
	format, err := ingest.detect_log_format("tests/fixtures/app.log")
	testing.expect_value(t, err, snout_core.Error.None)
	testing.expect_value(t, format, ingest.Log_Format.Logfmt)
}

@(test)
detect_syslog_format :: proc(t: ^testing.T) {
	format, err := ingest.detect_log_format("tests/fixtures/syslog.log")
	testing.expect_value(t, err, snout_core.Error.None)
	testing.expect_value(t, format, ingest.Log_Format.Syslog)
}

// ---- Non-strict parse error tests ------------------------------------------

@(test)
clf_non_strict_bad_line :: proc(t: ^testing.T) {
	// Write a temp file with one bad line (using existing test infrastructure)
	// Access non-strict: bad lines are null-padded
	opts := ingest.Log_Read_Options{format = .CLF, strict = false, has_format = true}
	// The syslog fixture has no CLF lines — all 4 lines will fail to parse as CLF
	schema, err := ingest.inspect_log_file("tests/fixtures/syslog.log", "t", opts)
	defer ingest.free_log_file_schema(&schema)
	testing.expect_value(t, err, snout_core.Error.None)
	testing.expect_value(t, schema.row_count, 4)
	testing.expect_value(t, schema.parse_errors, 4)
}

@(test)
clf_strict_bad_line :: proc(t: ^testing.T) {
	// Strict mode with wrong-format file should return Log_Parse_Error
	opts := ingest.Log_Read_Options{format = .CLF, strict = true, has_format = true}
	schema, err := ingest.inspect_log_file("tests/fixtures/syslog.log", "t", opts)
	defer ingest.free_log_file_schema(&schema)
	testing.expect_value(t, err, snout_core.Error.Log_Parse_Error)
}

// ---- Utility tests ----------------------------------------------------------

@(test)
clf_time_to_iso8601_plus_offset :: proc(t: ^testing.T) {
	result, ok := ingest.clf_time_to_iso8601("10/Oct/2000:13:55:36 +0500")
	testing.expect(t, ok, "conversion failed")
	// UTC = 13:55:36 - 05:00 = 08:55:36
	testing.expect_value(t, result, "2000-10-10T08:55:36Z")
}

@(test)
clf_time_to_iso8601_no_tz :: proc(t: ^testing.T) {
	result, ok := ingest.clf_time_to_iso8601("10/Oct/2000:13:55:36")
	testing.expect(t, ok, "conversion failed without tz")
	testing.expect_value(t, result, "2000-10-10T13:55:36Z")
}

@(test)
month_abbrev_to_num_all :: proc(t: ^testing.T) {
	names := []string{
		"Jan", "Feb", "Mar", "Apr", "May", "Jun",
		"Jul", "Aug", "Sep", "Oct", "Nov", "Dec",
	}
	for name, i in names {
		n, ok := ingest.month_abbrev_to_num(name)
		testing.expect(t, ok, "month parse failed")
		testing.expect_value(t, n, i + 1)
	}
	_, bad_ok := ingest.month_abbrev_to_num("Xyz")
	testing.expect(t, !bad_ok, "invalid month should fail")
}

@(test)
parse_named_groups_basic :: proc(t: ^testing.T) {
	pattern := `(?P<ip>\S+) (?P<path>/\S+)`
	names, modified, ok := ingest.parse_named_groups(pattern)
	testing.expect(t, ok, "parse_named_groups failed")
	testing.expect_value(t, len(names), 2)
	testing.expect_value(t, names[0], "ip")
	testing.expect_value(t, names[1], "path")
	testing.expect_value(t, modified, `(\S+) (/\S+)`)
}

@(test)
syslog_pri_prefix_stripped :: proc(t: ^testing.T) {
	opts := ingest.Log_Read_Options{format = .Syslog}
	table, err := ingest.read_log_table("tests/fixtures/syslog_pri.log", "syslog_pri", opts)
	defer snout_core.free_table(&table)
	testing.expect_value(t, err, snout_core.Error.None)
	testing.expect_value(t, table.row_count, 4)

	ts_col, found := snout_core.get_column(&table, "timestamp")
	testing.expect(t, found, "timestamp column missing")
	if found {
		testing.expect_value(t, ts_col.strings[0], "0000-06-11T10:00:01")
	}

	pid_col, pid_found := snout_core.get_column(&table, "pid")
	testing.expect(t, pid_found, "pid column missing")
	if pid_found {
		testing.expect_value(t, pid_col.null_mask[0], false)
		testing.expect_value(t, pid_col.int64s[0], i64(1234))
		testing.expect_value(t, pid_col.null_mask[3], true)
	}
}

@(test)
detect_syslog_with_pri :: proc(t: ^testing.T) {
	format, err := ingest.detect_log_format("tests/fixtures/syslog_pri.log")
	testing.expect_value(t, err, snout_core.Error.None)
	testing.expect_value(t, format, ingest.Log_Format.Syslog)
}

@(test)
free_log_file_schema_idempotent :: proc(t: ^testing.T) {
	opts := ingest.Log_Read_Options{format = .CLF}
	schema, err := ingest.inspect_log_file("tests/fixtures/access.log", "access", opts)
	testing.expect_value(t, err, snout_core.Error.None)
	ingest.free_log_file_schema(&schema)
	// Second free should be safe (schema^ = {})
	ingest.free_log_file_schema(&schema)
}
