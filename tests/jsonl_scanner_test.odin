package tests

import "core:os"
import "core:strings"
import "core:testing"
import snout_core "../core"
import ingest "../ingest"

@(private = "file")
write_jsonl_tmp :: proc(t: ^testing.T, name, content: string) -> string {
	path := strings.concatenate({"tests/fixtures/.tmp_jsonl_", name, ".jsonl"})
	err := os.write_entire_file(path, transmute([]byte)content)
	testing.expect(t, err == nil, "could not write temp jsonl fixture")
	return path
}

@(private = "file")
remove_jsonl_tmp :: proc(path: string) {
	os.remove(path)
	delete(path)
}

@(private = "file")
collect_jsonl_lines :: proc(
	t: ^testing.T,
	path: string,
	buffer_size: int,
) -> (lines: [dynamic]string, scan_err: snout_core.Error) {
	scanner, open_err := ingest.open_jsonl_scanner(path, buffer_size)
	testing.expect_value(t, open_err, snout_core.Error.None)
	if open_err != .None {
		return nil, open_err
	}
	defer ingest.close_jsonl_scanner(&scanner)
	lines = make([dynamic]string)
	for {
		line, done, err := ingest.next_jsonl_line(&scanner)
		if err != .None {
			return lines, err
		}
		if done {
			break
		}
		append(&lines, strings.clone(line))
	}
	return lines, .None
}

@(private = "file")
free_jsonl_lines :: proc(lines: ^[dynamic]string) {
	for line in lines {
		delete(line)
	}
	delete(lines^)
}

@(test)
jsonl_scanner_simple_lf :: proc(t: ^testing.T) {
	path := write_jsonl_tmp(t, "lf", "{\"a\":1}\n{\"b\":2}\n")
	defer remove_jsonl_tmp(path)
	lines, err := collect_jsonl_lines(t, path, ingest.JSONL_SCANNER_BUFFER_SIZE)
	defer free_jsonl_lines(&lines)
	testing.expect_value(t, err, snout_core.Error.None)
	testing.expect_value(t, len(lines), 2)
	if len(lines) == 2 {
		testing.expect_value(t, lines[0], `{"a":1}`)
		testing.expect_value(t, lines[1], `{"b":2}`)
	}
}

@(test)
jsonl_scanner_crlf :: proc(t: ^testing.T) {
	path := write_jsonl_tmp(t, "crlf", "{\"a\":1}\r\n{\"b\":2}\r\n")
	defer remove_jsonl_tmp(path)
	lines, err := collect_jsonl_lines(t, path, ingest.JSONL_SCANNER_BUFFER_SIZE)
	defer free_jsonl_lines(&lines)
	testing.expect_value(t, err, snout_core.Error.None)
	testing.expect_value(t, len(lines), 2)
	if len(lines) == 2 {
		testing.expect_value(t, lines[0], `{"a":1}`)
		testing.expect_value(t, lines[1], `{"b":2}`)
	}
}

@(test)
jsonl_scanner_no_trailing_newline :: proc(t: ^testing.T) {
	path := write_jsonl_tmp(t, "no_nl", "{\"a\":1}\n{\"b\":2}")
	defer remove_jsonl_tmp(path)
	lines, err := collect_jsonl_lines(t, path, ingest.JSONL_SCANNER_BUFFER_SIZE)
	defer free_jsonl_lines(&lines)
	testing.expect_value(t, err, snout_core.Error.None)
	testing.expect_value(t, len(lines), 2)
}

@(test)
jsonl_scanner_blank_lines_skipped :: proc(t: ^testing.T) {
	path := write_jsonl_tmp(t, "blank", "\n{\"a\":1}\n\n   \n{\"b\":2}\n\n")
	defer remove_jsonl_tmp(path)
	lines, err := collect_jsonl_lines(t, path, ingest.JSONL_SCANNER_BUFFER_SIZE)
	defer free_jsonl_lines(&lines)
	testing.expect_value(t, err, snout_core.Error.None)
	testing.expect_value(t, len(lines), 2)
}

@(test)
jsonl_scanner_empty_file :: proc(t: ^testing.T) {
	path := write_jsonl_tmp(t, "empty", "")
	defer remove_jsonl_tmp(path)
	lines, err := collect_jsonl_lines(t, path, ingest.JSONL_SCANNER_BUFFER_SIZE)
	defer free_jsonl_lines(&lines)
	testing.expect_value(t, err, snout_core.Error.None)
	testing.expect_value(t, len(lines), 0)
}

@(test)
jsonl_scanner_only_blank_lines :: proc(t: ^testing.T) {
	path := write_jsonl_tmp(t, "allblank", "\n\n   \n\r\n")
	defer remove_jsonl_tmp(path)
	lines, err := collect_jsonl_lines(t, path, ingest.JSONL_SCANNER_BUFFER_SIZE)
	defer free_jsonl_lines(&lines)
	testing.expect_value(t, err, snout_core.Error.None)
	testing.expect_value(t, len(lines), 0)
}

@(test)
jsonl_scanner_line_too_large :: proc(t: ^testing.T) {
	content := strings.repeat("x", 100)
	defer delete(content)
	path := write_jsonl_tmp(t, "toolarge", content)
	defer remove_jsonl_tmp(path)

	scanner, open_err := ingest.open_jsonl_scanner(path)
	testing.expect_value(t, open_err, snout_core.Error.None)
	scanner.max_line_size = 50
	defer ingest.close_jsonl_scanner(&scanner)

	_, _, scan_err := ingest.next_jsonl_line(&scanner)
	testing.expect_value(t, scan_err, snout_core.Error.Line_Too_Large)
}

@(test)
jsonl_scanner_missing_file :: proc(t: ^testing.T) {
	_, err := ingest.open_jsonl_scanner("/nonexistent/path/file.jsonl")
	testing.expect_value(t, err, snout_core.Error.Io)
}

@(test)
jsonl_scanner_buffer_boundary_crossing :: proc(t: ^testing.T) {
	// Line crosses a tiny buffer boundary.
	path := write_jsonl_tmp(t, "boundary", "{\"hello\":\"world\"}\n{\"x\":1}\n")
	defer remove_jsonl_tmp(path)
	lines, err := collect_jsonl_lines(t, path, 4)
	defer free_jsonl_lines(&lines)
	testing.expect_value(t, err, snout_core.Error.None)
	testing.expect_value(t, len(lines), 2)
	if len(lines) == 2 {
		testing.expect_value(t, lines[0], `{"hello":"world"}`)
		testing.expect_value(t, lines[1], `{"x":1}`)
	}
}

@(test)
jsonl_scanner_crlf_at_buffer_boundary :: proc(t: ^testing.T) {
	// With 4-byte buffer: "abc\r" fills one read, "\ndef\r\n" the next.
	path := write_jsonl_tmp(t, "crlf_boundary", "abc\r\ndef\r\n")
	defer remove_jsonl_tmp(path)
	lines, err := collect_jsonl_lines(t, path, 4)
	defer free_jsonl_lines(&lines)
	testing.expect_value(t, err, snout_core.Error.None)
	testing.expect_value(t, len(lines), 2)
	if len(lines) == 2 {
		testing.expect_value(t, lines[0], "abc")
		testing.expect_value(t, lines[1], "def")
	}
}

@(test)
jsonl_scanner_utf8_across_boundary :: proc(t: ^testing.T) {
	// UTF-8 snowman (3 bytes: E2 98 83) crosses a 4-byte buffer.
	path := write_jsonl_tmp(t, "utf8_boundary", "{\"e\":\"☃\"}\n{\"f\":\"ok\"}\n")
	defer remove_jsonl_tmp(path)
	lines, err := collect_jsonl_lines(t, path, 8)
	defer free_jsonl_lines(&lines)
	testing.expect_value(t, err, snout_core.Error.None)
	testing.expect_value(t, len(lines), 2)
	if len(lines) == 2 {
		testing.expect_value(t, lines[0], "{\"e\":\"☃\"}")
		testing.expect_value(t, lines[1], "{\"f\":\"ok\"}")
	}
}

@(test)
jsonl_scanner_single_line_no_newline :: proc(t: ^testing.T) {
	path := write_jsonl_tmp(t, "single_no_nl", "{\"only\":true}")
	defer remove_jsonl_tmp(path)
	lines, err := collect_jsonl_lines(t, path, ingest.JSONL_SCANNER_BUFFER_SIZE)
	defer free_jsonl_lines(&lines)
	testing.expect_value(t, err, snout_core.Error.None)
	testing.expect_value(t, len(lines), 1)
	if len(lines) == 1 {
		testing.expect_value(t, lines[0], `{"only":true}`)
	}
}

@(test)
jsonl_scanner_line_numbers_advance :: proc(t: ^testing.T) {
	path := write_jsonl_tmp(t, "linenum", "\n{\"a\":1}\n\n{\"b\":2}\n")
	defer remove_jsonl_tmp(path)

	scanner, err := ingest.open_jsonl_scanner(path)
	testing.expect_value(t, err, snout_core.Error.None)
	defer ingest.close_jsonl_scanner(&scanner)

	testing.expect_value(t, scanner.line, 1)

	_, _, _ = ingest.next_jsonl_line(&scanner) // skips blank line 1, returns line 2
	testing.expect_value(t, scanner.line, 3)   // advanced past lines 1 and 2

	_, _, _ = ingest.next_jsonl_line(&scanner) // skips blank line 3, returns line 4
	testing.expect_value(t, scanner.line, 5)   // advanced past lines 3 and 4

	_, done, _ := ingest.next_jsonl_line(&scanner)
	testing.expect_value(t, done, true)
}

@(test)
jsonl_scanner_close_clears_state :: proc(t: ^testing.T) {
	path := write_jsonl_tmp(t, "close_state", "{\"a\":1}\n")
	defer remove_jsonl_tmp(path)

	scanner, err := ingest.open_jsonl_scanner(path)
	testing.expect_value(t, err, snout_core.Error.None)
	ingest.close_jsonl_scanner(&scanner)

	testing.expect_value(t, scanner.file, nil)
	testing.expect(t, scanner.buffer == nil, "expected scanner.buffer to be nil after close")
}
