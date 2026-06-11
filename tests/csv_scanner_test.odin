package tests

import "core:fmt"
import "core:os"
import "core:strings"
import "core:testing"
import snout_core "../core"
import ingest "../ingest"

@(private = "file")
write_temp_csv :: proc(t: ^testing.T, name, content: string) -> string {
	path := fmt.aprintf("tests/fixtures/.tmp_%s.csv", name)
	err := os.write_entire_file(path, transmute([]byte)content)
	testing.expect(t, err == nil, "could not write temp fixture")
	return path
}

@(private = "file")
remove_temp_csv :: proc(path: string) {
	os.remove(path)
	delete(path)
}

@(private = "file")
collect_records :: proc(
	t: ^testing.T,
	path: string,
	buffer_size: int,
) -> (rows: [dynamic][]string, scan_err: snout_core.Error) {
	scanner, open_err := ingest.open_csv_scanner(path, buffer_size)
	testing.expect_value(t, open_err, snout_core.Error.None)
	if open_err != .None {
		return nil, open_err
	}
	defer ingest.close_csv_scanner(&scanner)

	rows = make([dynamic][]string)
	for {
		record, done, err := ingest.next_csv_record(&scanner)
		if err != .None {
			return rows, err
		}
		if done {
			break
		}
		cloned := make([]string, len(record.fields))
		for field, index in record.fields {
			cloned[index] = strings.clone(field)
		}
		append(&rows, cloned)
	}
	return rows, .None
}

@(private = "file")
free_rows :: proc(rows: ^[dynamic][]string) {
	for row in rows {
		for field in row {
			delete(field)
		}
		delete(row)
	}
	delete(rows^)
}

@(private = "file")
expect_rows :: proc(t: ^testing.T, rows: [][]string, expected: [][]string) {
	testing.expect_value(t, len(rows), len(expected))
	if len(rows) != len(expected) {
		return
	}
	for row, row_index in expected {
		testing.expect_value(t, len(rows[row_index]), len(row))
		if len(rows[row_index]) != len(row) {
			continue
		}
		for field, field_index in row {
			testing.expect_value(t, rows[row_index][field_index], field)
		}
	}
}

TINY_BUFFER_SIZES :: [3]int{4, 7, 16}

@(test)
scanner_lf_rows :: proc(t: ^testing.T) {
	path := write_temp_csv(t, "lf", "a,b\n1,2\n3,4\n")
	defer remove_temp_csv(path)
	for size in TINY_BUFFER_SIZES {
		rows, err := collect_records(t, path, size)
		defer free_rows(&rows)
		testing.expect_value(t, err, snout_core.Error.None)
		expect_rows(t, rows[:], {{"a", "b"}, {"1", "2"}, {"3", "4"}})
	}
}

@(test)
scanner_crlf_rows :: proc(t: ^testing.T) {
	path := write_temp_csv(t, "crlf", "a,b\r\n1,2\r\n")
	defer remove_temp_csv(path)
	for size in TINY_BUFFER_SIZES {
		rows, err := collect_records(t, path, size)
		defer free_rows(&rows)
		testing.expect_value(t, err, snout_core.Error.None)
		expect_rows(t, rows[:], {{"a", "b"}, {"1", "2"}})
	}
}

@(test)
scanner_final_row_without_newline :: proc(t: ^testing.T) {
	path := write_temp_csv(t, "nonewline", "a,b\n1,2")
	defer remove_temp_csv(path)
	for size in TINY_BUFFER_SIZES {
		rows, err := collect_records(t, path, size)
		defer free_rows(&rows)
		testing.expect_value(t, err, snout_core.Error.None)
		expect_rows(t, rows[:], {{"a", "b"}, {"1", "2"}})
	}
}

@(test)
scanner_empty_fields :: proc(t: ^testing.T) {
	path := write_temp_csv(t, "empty_fields", "a,b,c\n1,,3\n,,\n")
	defer remove_temp_csv(path)
	for size in TINY_BUFFER_SIZES {
		rows, err := collect_records(t, path, size)
		defer free_rows(&rows)
		testing.expect_value(t, err, snout_core.Error.None)
		expect_rows(t, rows[:], {{"a", "b", "c"}, {"1", "", "3"}, {"", "", ""}})
	}
}

@(test)
scanner_quoted_comma :: proc(t: ^testing.T) {
	path := write_temp_csv(t, "quoted_comma", "name,message\npig,\"hello, world\"\n")
	defer remove_temp_csv(path)
	for size in TINY_BUFFER_SIZES {
		rows, err := collect_records(t, path, size)
		defer free_rows(&rows)
		testing.expect_value(t, err, snout_core.Error.None)
		expect_rows(t, rows[:], {{"name", "message"}, {"pig", "hello, world"}})
	}
}

@(test)
scanner_escaped_quote :: proc(t: ^testing.T) {
	path := write_temp_csv(t, "escaped_quote", "name,message\nboar,\"he said \"\"snout\"\"\"\n")
	defer remove_temp_csv(path)
	for size in TINY_BUFFER_SIZES {
		rows, err := collect_records(t, path, size)
		defer free_rows(&rows)
		testing.expect_value(t, err, snout_core.Error.None)
		expect_rows(t, rows[:], {{"name", "message"}, {"boar", "he said \"snout\""}})
	}
}

@(test)
scanner_empty_quoted_field :: proc(t: ^testing.T) {
	path := write_temp_csv(t, "empty_quoted", "a,b\n\"\",2\n")
	defer remove_temp_csv(path)
	for size in TINY_BUFFER_SIZES {
		rows, err := collect_records(t, path, size)
		defer free_rows(&rows)
		testing.expect_value(t, err, snout_core.Error.None)
		expect_rows(t, rows[:], {{"a", "b"}, {"", "2"}})
	}
}

@(test)
scanner_field_crossing_buffer_boundary :: proc(t: ^testing.T) {
	path := write_temp_csv(t, "boundary_field", "header\nabcdefghijklmnopqrstuvwxyz\n")
	defer remove_temp_csv(path)
	for size in TINY_BUFFER_SIZES {
		rows, err := collect_records(t, path, size)
		defer free_rows(&rows)
		testing.expect_value(t, err, snout_core.Error.None)
		expect_rows(t, rows[:], {{"header"}, {"abcdefghijklmnopqrstuvwxyz"}})
	}
}

@(test)
scanner_escaped_quote_crossing_boundary :: proc(t: ^testing.T) {
	input := "m\n\"aaa\"\"bbb\"\n"
	path := write_temp_csv(t, "boundary_escape", input)
	defer remove_temp_csv(path)
	for size in 4 ..= 13 {
		rows, err := collect_records(t, path, size)
		defer free_rows(&rows)
		testing.expect_value(t, err, snout_core.Error.None)
		expect_rows(t, rows[:], {{"m"}, {"aaa\"bbb"}})
	}
}

@(test)
scanner_crlf_split_across_boundary :: proc(t: ^testing.T) {
	input := "ab,cd\r\nef,gh\r\n"
	path := write_temp_csv(t, "boundary_crlf", input)
	defer remove_temp_csv(path)
	for size in 4 ..= 15 {
		rows, err := collect_records(t, path, size)
		defer free_rows(&rows)
		testing.expect_value(t, err, snout_core.Error.None)
		expect_rows(t, rows[:], {{"ab", "cd"}, {"ef", "gh"}})
	}
}

@(test)
scanner_utf8_crossing_boundary :: proc(t: ^testing.T) {
	input := "col\naño está bien 🐷\n"
	path := write_temp_csv(t, "boundary_utf8", input)
	defer remove_temp_csv(path)
	for size in 4 ..= 24 {
		rows, err := collect_records(t, path, size)
		defer free_rows(&rows)
		testing.expect_value(t, err, snout_core.Error.None)
		expect_rows(t, rows[:], {{"col"}, {"año está bien 🐷"}})
	}
}

@(test)
scanner_header_larger_than_buffer :: proc(t: ^testing.T) {
	path := write_temp_csv(
		t,
		"big_header",
		"first_long_column_name,second_long_column_name\n1,2\n",
	)
	defer remove_temp_csv(path)
	rows, err := collect_records(t, path, 8)
	defer free_rows(&rows)
	testing.expect_value(t, err, snout_core.Error.None)
	expect_rows(
		t,
		rows[:],
		{{"first_long_column_name", "second_long_column_name"}, {"1", "2"}},
	)
}

@(test)
scanner_field_larger_than_buffer_below_limit :: proc(t: ^testing.T) {
	builder := strings.builder_make()
	defer strings.builder_destroy(&builder)
	strings.write_string(&builder, "value\n")
	for _ in 0 ..< 1000 {
		strings.write_byte(&builder, 'x')
	}
	strings.write_byte(&builder, '\n')
	path := write_temp_csv(t, "big_field", strings.to_string(builder))
	defer remove_temp_csv(path)
	rows, err := collect_records(t, path, 16)
	defer free_rows(&rows)
	testing.expect_value(t, err, snout_core.Error.None)
	testing.expect_value(t, len(rows), 2)
	if len(rows) == 2 {
		testing.expect_value(t, len(rows[1][0]), 1000)
	}
}

@(test)
scanner_field_above_limit :: proc(t: ^testing.T) {
	path := write_temp_csv(t, "field_limit", "value\nabcdefghijklmnop\n")
	defer remove_temp_csv(path)
	scanner, open_err := ingest.open_csv_scanner(path, 8)
	testing.expect_value(t, open_err, snout_core.Error.None)
	defer ingest.close_csv_scanner(&scanner)
	scanner.max_field_size = 10

	_, _, header_err := ingest.next_csv_record(&scanner)
	testing.expect_value(t, header_err, snout_core.Error.None)
	_, _, row_err := ingest.next_csv_record(&scanner)
	testing.expect_value(t, row_err, snout_core.Error.Csv_Field_Too_Large)
}

@(test)
scanner_record_above_limit :: proc(t: ^testing.T) {
	path := write_temp_csv(t, "record_limit", "a,b\n12345,67890\n")
	defer remove_temp_csv(path)
	scanner, open_err := ingest.open_csv_scanner(path, 8)
	testing.expect_value(t, open_err, snout_core.Error.None)
	defer ingest.close_csv_scanner(&scanner)
	scanner.max_record_size = 6

	_, _, header_err := ingest.next_csv_record(&scanner)
	testing.expect_value(t, header_err, snout_core.Error.None)
	_, _, row_err := ingest.next_csv_record(&scanner)
	testing.expect_value(t, row_err, snout_core.Error.Csv_Record_Too_Large)
}

@(test)
scanner_malformed_quote :: proc(t: ^testing.T) {
	path := write_temp_csv(t, "malformed_quote", "a\nab\"c\n")
	defer remove_temp_csv(path)
	for size in TINY_BUFFER_SIZES {
		rows, err := collect_records(t, path, size)
		defer free_rows(&rows)
		testing.expect_value(t, err, snout_core.Error.Parse)
	}
}

@(test)
scanner_text_after_closing_quote :: proc(t: ^testing.T) {
	path := write_temp_csv(t, "after_quote", "a\n\"ab\"cd\n")
	defer remove_temp_csv(path)
	for size in TINY_BUFFER_SIZES {
		rows, err := collect_records(t, path, size)
		defer free_rows(&rows)
		testing.expect_value(t, err, snout_core.Error.Parse)
	}
}

@(test)
scanner_multiline_quoted_rejected :: proc(t: ^testing.T) {
	path := write_temp_csv(t, "multiline", "a\n\"hello\nworld\"\n")
	defer remove_temp_csv(path)
	for size in TINY_BUFFER_SIZES {
		rows, err := collect_records(t, path, size)
		defer free_rows(&rows)
		testing.expect_value(t, err, snout_core.Error.Multiline_Quoted_Field)
	}
}

@(test)
scanner_unterminated_quote_at_eof :: proc(t: ^testing.T) {
	path := write_temp_csv(t, "unterminated", "a\n\"hello")
	defer remove_temp_csv(path)
	for size in TINY_BUFFER_SIZES {
		rows, err := collect_records(t, path, size)
		defer free_rows(&rows)
		testing.expect_value(t, err, snout_core.Error.Parse)
	}
}

@(test)
scanner_bare_cr_rejected :: proc(t: ^testing.T) {
	path := write_temp_csv(t, "bare_cr", "a\nb\rc\n")
	defer remove_temp_csv(path)
	for size in TINY_BUFFER_SIZES {
		rows, err := collect_records(t, path, size)
		defer free_rows(&rows)
		testing.expect_value(t, err, snout_core.Error.Parse)
	}
}

@(test)
scanner_empty_input :: proc(t: ^testing.T) {
	path := write_temp_csv(t, "empty", "")
	defer remove_temp_csv(path)
	for size in TINY_BUFFER_SIZES {
		rows, err := collect_records(t, path, size)
		defer free_rows(&rows)
		testing.expect_value(t, err, snout_core.Error.None)
		testing.expect_value(t, len(rows), 0)
	}
}

@(test)
scanner_header_only_input :: proc(t: ^testing.T) {
	path := write_temp_csv(t, "header_only", "a,b,c\n")
	defer remove_temp_csv(path)
	for size in TINY_BUFFER_SIZES {
		rows, err := collect_records(t, path, size)
		defer free_rows(&rows)
		testing.expect_value(t, err, snout_core.Error.None)
		expect_rows(t, rows[:], {{"a", "b", "c"}})
	}
}

@(test)
scanner_trailing_empty_quoted_field :: proc(t: ^testing.T) {
	path := write_temp_csv(t, "trailing_quoted", "a,b\n1,\"\"")
	defer remove_temp_csv(path)
	for size in TINY_BUFFER_SIZES {
		rows, err := collect_records(t, path, size)
		defer free_rows(&rows)
		testing.expect_value(t, err, snout_core.Error.None)
		expect_rows(t, rows[:], {{"a", "b"}, {"1", ""}})
	}
}

@(test)
scanner_open_missing_file_fails :: proc(t: ^testing.T) {
	_, err := ingest.open_csv_scanner("tests/fixtures/.does_not_exist.csv", 16)
	testing.expect_value(t, err, snout_core.Error.Io)
}

@(test)
scanner_close_after_error_is_safe :: proc(t: ^testing.T) {
	path := write_temp_csv(t, "close_after_error", "a\n\"bad\nrow\"\n")
	defer remove_temp_csv(path)
	scanner, open_err := ingest.open_csv_scanner(path, 4)
	testing.expect_value(t, open_err, snout_core.Error.None)

	_, _, header_err := ingest.next_csv_record(&scanner)
	testing.expect_value(t, header_err, snout_core.Error.None)
	_, _, row_err := ingest.next_csv_record(&scanner)
	testing.expect_value(t, row_err, snout_core.Error.Multiline_Quoted_Field)

	ingest.close_csv_scanner(&scanner)
	ingest.close_csv_scanner(&scanner)
}

@(test)
scanner_record_line_numbers :: proc(t: ^testing.T) {
	path := write_temp_csv(t, "line_numbers", "a\n1\n2\n")
	defer remove_temp_csv(path)
	scanner, open_err := ingest.open_csv_scanner(path, 4)
	testing.expect_value(t, open_err, snout_core.Error.None)
	defer ingest.close_csv_scanner(&scanner)

	expected_lines := [3]int{1, 2, 3}
	for expected in expected_lines {
		record, done, err := ingest.next_csv_record(&scanner)
		testing.expect_value(t, err, snout_core.Error.None)
		testing.expect_value(t, done, false)
		testing.expect_value(t, record.line, expected)
	}
	_, done, _ := ingest.next_csv_record(&scanner)
	testing.expect_value(t, done, true)
}
