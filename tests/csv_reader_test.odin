package tests

import "core:testing"
import snout_core "../core"
import aggregate "../exec"
import ingest "../ingest"

FIXTURE_PATH :: "tests/fixtures/simple_metrics.csv"

@(test)
csv_loads_successfully :: proc(t: ^testing.T) {
	table, err := ingest.read_csv_table(FIXTURE_PATH, "simple_metrics")
	testing.expect_value(t, err, snout_core.Error.None)
	if err != .None {
		return
	}
	defer snout_core.free_table(&table)

	testing.expect_value(t, table.row_count, 5)
	testing.expect_value(t, len(table.columns), 5)
}

@(test)
header_names_are_parsed :: proc(t: ^testing.T) {
	table, err := ingest.read_csv_table(FIXTURE_PATH, "simple_metrics")
	testing.expect_value(t, err, snout_core.Error.None)
	if err != .None {
		return
	}
	defer snout_core.free_table(&table)

	names := [?]string{"timestamp", "endpoint", "status", "latency_ms", "bytes"}
	for name in names {
		_, found := snout_core.get_column(&table, name)
		testing.expectf(t, found, "expected column %q", name)
	}
}

@(test)
types_are_inferred :: proc(t: ^testing.T) {
	table, err := ingest.read_csv_table(FIXTURE_PATH, "simple_metrics")
	testing.expect_value(t, err, snout_core.Error.None)
	if err != .None {
		return
	}
	defer snout_core.free_table(&table)

	expected := []struct {
		name: string,
		kind: snout_core.Column_Type,
	}{
		{"timestamp", .Timestamp},
		{"endpoint", .String},
		{"status", .Int64},
		{"latency_ms", .Int64},
		{"bytes", .Int64},
	}
	for item in expected {
		column, found := snout_core.get_column(&table, item.name)
		testing.expectf(t, found, "expected column %q", item.name)
		if found {
			testing.expect_value(t, column.kind, item.kind)
		}
	}
}

@(test)
average_latency_is_computed :: proc(t: ^testing.T) {
	table, err := ingest.read_csv_table(FIXTURE_PATH, "simple_metrics")
	testing.expect_value(t, err, snout_core.Error.None)
	if err != .None {
		return
	}
	defer snout_core.free_table(&table)

	average, avg_err := aggregate.avg_f64_or_i64(&table, "latency_ms")
	testing.expect_value(t, avg_err, snout_core.Error.None)
	difference := average - 53.2
	if difference < 0 {
		difference = -difference
	}
	testing.expect(t, difference < 0.000001)
}

@(test)
status_sum_is_computed :: proc(t: ^testing.T) {
	table, err := ingest.read_csv_table(FIXTURE_PATH, "simple_metrics")
	testing.expect_value(t, err, snout_core.Error.None)
	if err != .None {
		return
	}
	defer snout_core.free_table(&table)

	total, sum_err := aggregate.sum_i64(&table, "status")
	testing.expect_value(t, sum_err, snout_core.Error.None)
	testing.expect_value(t, total, i64(1300))
}

@(test)
integer_stats_ignore_nulls :: proc(t: ^testing.T) {
	input := "name,value\na,10\nb,\nc,30\nd,-5\n"
	table, err := ingest.read_csv_string(input, "integer_stats")
	testing.expect_value(t, err, snout_core.Error.None)
	if err != .None {
		return
	}
	defer snout_core.free_table(&table)

	stats, stats_err := aggregate.numeric_stats(&table, "value")
	testing.expect_value(t, stats_err, snout_core.Error.None)
	testing.expect_value(t, stats.kind, snout_core.Column_Type.Int64)
	testing.expect_value(t, stats.count, 3)
	testing.expect_value(t, stats.null_count, 1)
	testing.expect_value(t, stats.sum, 35.0)
	testing.expect_value(t, stats.min, -5.0)
	testing.expect_value(t, stats.max, 30.0)
	testing.expect(t, stats.avg > 11.666666 && stats.avg < 11.666667)
}

@(test)
float_stats_are_computed :: proc(t: ^testing.T) {
	input := "value\n1.5\n2.25\n-0.75\n"
	table, err := ingest.read_csv_string(input, "float_stats")
	testing.expect_value(t, err, snout_core.Error.None)
	if err != .None {
		return
	}
	defer snout_core.free_table(&table)

	stats, stats_err := aggregate.numeric_stats(&table, "value")
	testing.expect_value(t, stats_err, snout_core.Error.None)
	testing.expect_value(t, stats.kind, snout_core.Column_Type.Float64)
	testing.expect_value(t, stats.count, 3)
	testing.expect_value(t, stats.null_count, 0)
	testing.expect_value(t, stats.sum, 3.0)
	testing.expect_value(t, stats.avg, 1.0)
	testing.expect_value(t, stats.min, -0.75)
	testing.expect_value(t, stats.max, 2.25)
}

@(test)
stats_reject_non_numeric_columns :: proc(t: ^testing.T) {
	input := "name\npig\nboar\n"
	table, err := ingest.read_csv_string(input, "string_stats")
	testing.expect_value(t, err, snout_core.Error.None)
	if err != .None {
		return
	}
	defer snout_core.free_table(&table)

	_, stats_err := aggregate.numeric_stats(&table, "name")
	testing.expect_value(t, stats_err, snout_core.Error.Wrong_Column_Type)
}

@(test)
quoted_fields_are_parsed :: proc(t: ^testing.T) {
	input := "name,message\npig,\"hello, world\"\nboar,\"he said \"\"snout\"\"\"\n"
	table, err := ingest.read_csv_string(input, "quoted")
	testing.expect_value(t, err, snout_core.Error.None)
	if err != .None {
		return
	}
	defer snout_core.free_table(&table)

	message, found := snout_core.get_column(&table, "message")
	testing.expect(t, found)
	if found {
		testing.expect_value(t, message.strings[0], "hello, world")
		testing.expect_value(t, message.strings[1], "he said \"snout\"")
	}
}

@(test)
empty_cells_make_column_nullable :: proc(t: ^testing.T) {
	input := "name,latency\na,10\nb,\nc,30\n"
	table, err := ingest.read_csv_string(input, "nullable")
	testing.expect_value(t, err, snout_core.Error.None)
	if err != .None {
		return
	}
	defer snout_core.free_table(&table)

	latency, found := snout_core.get_column(&table, "latency")
	testing.expect(t, found)
	if found {
		testing.expect(t, latency.nullable)
		testing.expect(t, latency.null_mask[1])
		testing.expect_value(t, latency.kind, snout_core.Column_Type.Int64)
	}
}

@(test)
crlf_line_endings_are_supported :: proc(t: ^testing.T) {
	input := "name,value\r\nfirst,10\r\nsecond,20\r\n"
	table, err := ingest.read_csv_string(input, "crlf")
	testing.expect_value(t, err, snout_core.Error.None)
	if err != .None {
		return
	}
	defer snout_core.free_table(&table)

	testing.expect_value(t, table.row_count, 2)
	value, found := snout_core.get_column(&table, "value")
	testing.expect(t, found)
	if found {
		testing.expect_value(t, value.int64s[1], i64(20))
	}
}

@(test)
multiline_quoted_fields_are_rejected :: proc(t: ^testing.T) {
	input := "name,message\npig,\"hello\nworld\"\n"
	_, err := ingest.read_csv_string(input, "multiline")
	testing.expect_value(t, err, snout_core.Error.Multiline_Quoted_Field)
}
