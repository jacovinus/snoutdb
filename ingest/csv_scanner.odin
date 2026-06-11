package ingest

import "base:runtime"
import "core:os"
import snout_core "../core"

CSV_SCANNER_BUFFER_SIZE :: 1 * 1024 * 1024
CSV_MAX_FIELD_SIZE :: 64 * 1024 * 1024
CSV_MAX_RECORD_SIZE :: 256 * 1024 * 1024
CSV_MAX_FIELDS_PER_RECORD :: 65_535

Csv_Scanner :: struct {
	file:            ^os.File,
	buffer:          []byte,
	start:           int,
	end:             int,
	eof:             bool,
	line:            int,
	scratch:         [dynamic]u8,
	field_ends:      [dynamic]int,
	fields:          [dynamic]string,
	max_field_size:  int,
	max_record_size: int,
	allocator:       runtime.Allocator,
}

Csv_Record :: struct {
	fields: []string,
	line:   int,
}

open_csv_scanner :: proc(
	path: string,
	buffer_size := CSV_SCANNER_BUFFER_SIZE,
	allocator := context.allocator,
) -> (scanner: Csv_Scanner, err: snout_core.Error) {
	if buffer_size <= 0 {
		return {}, .Io
	}
	file, open_err := os.open(path)
	if open_err != nil {
		return {}, .Io
	}
	buffer, alloc_err := make([]byte, buffer_size, allocator)
	if alloc_err != nil {
		os.close(file)
		return {}, .Out_Of_Memory
	}
	scanner.file = file
	scanner.buffer = buffer
	scanner.line = 1
	scanner.max_field_size = CSV_MAX_FIELD_SIZE
	scanner.max_record_size = CSV_MAX_RECORD_SIZE
	scanner.allocator = allocator
	scanner.scratch = make([dynamic]u8, 0, allocator = allocator)
	scanner.field_ends = make([dynamic]int, 0, allocator = allocator)
	scanner.fields = make([dynamic]string, 0, allocator = allocator)
	return scanner, .None
}

close_csv_scanner :: proc(scanner: ^Csv_Scanner) {
	if scanner.file != nil {
		os.close(scanner.file)
		scanner.file = nil
	}
	if scanner.buffer != nil {
		delete(scanner.buffer, scanner.allocator)
		scanner.buffer = nil
	}
	delete(scanner.scratch)
	delete(scanner.field_ends)
	delete(scanner.fields)
	scanner.scratch = nil
	scanner.field_ends = nil
	scanner.fields = nil
	scanner.start = 0
	scanner.end = 0
}

@(private = "file")
refill_scanner :: proc(scanner: ^Csv_Scanner) -> (refilled: bool, err: snout_core.Error) {
	if scanner.eof {
		return false, .None
	}
	bytes_read, read_err := os.read(scanner.file, scanner.buffer)
	if read_err == .EOF || (read_err == nil && bytes_read == 0) {
		scanner.eof = true
		return false, .None
	}
	if read_err != nil {
		return false, .Io
	}
	scanner.start = 0
	scanner.end = bytes_read
	return true, .None
}

@(private = "file")
peek_scanner_byte :: proc(scanner: ^Csv_Scanner) -> (value: byte, ok: bool, err: snout_core.Error) {
	if scanner.start >= scanner.end {
		refilled, refill_err := refill_scanner(scanner)
		if refill_err != .None {
			return 0, false, refill_err
		}
		if !refilled {
			return 0, false, .None
		}
	}
	return scanner.buffer[scanner.start], true, .None
}

// next_csv_record returns the next record. The returned fields and their
// backing bytes are valid only until the next call to next_csv_record or
// close_csv_scanner. done is true when the input is exhausted.
next_csv_record :: proc(
	scanner: ^Csv_Scanner,
) -> (record: Csv_Record, done: bool, err: snout_core.Error) {
	clear(&scanner.scratch)
	clear(&scanner.field_ends)
	in_quotes := false
	field_quoted := false
	field_start := 0
	record_line := scanner.line

	finish_field :: proc(
		scanner: ^Csv_Scanner,
		field_start: ^int,
		field_quoted: ^bool,
	) -> snout_core.Error {
		if len(scanner.field_ends) >= CSV_MAX_FIELDS_PER_RECORD {
			return .Too_Many_Columns
		}
		append(&scanner.field_ends, len(scanner.scratch))
		field_start^ = len(scanner.scratch)
		field_quoted^ = false
		return .None
	}

	check_limits :: proc(scanner: ^Csv_Scanner, field_start: int) -> snout_core.Error {
		if len(scanner.scratch) - field_start > scanner.max_field_size {
			return .Csv_Field_Too_Large
		}
		if len(scanner.scratch) > scanner.max_record_size {
			return .Csv_Record_Too_Large
		}
		return .None
	}

	emit_record :: proc(scanner: ^Csv_Scanner, record_line: int) -> Csv_Record {
		clear(&scanner.fields)
		previous := 0
		for field_end in scanner.field_ends {
			append(&scanner.fields, string(scanner.scratch[previous:field_end]))
			previous = field_end
		}
		return Csv_Record{fields = scanner.fields[:], line = record_line}
	}

	for {
		if scanner.start >= scanner.end {
			refilled, refill_err := refill_scanner(scanner)
			if refill_err != .None {
				return {}, false, refill_err
			}
			if !refilled {
				if in_quotes {
					return {}, false, .Parse
				}
				if len(scanner.field_ends) > 0 ||
				   len(scanner.scratch) > field_start ||
				   field_quoted {
					finish_err := finish_field(scanner, &field_start, &field_quoted)
					if finish_err != .None {
						return {}, false, finish_err
					}
					return emit_record(scanner, record_line), false, .None
				}
				return {}, true, .None
			}
		}

		if in_quotes {
			span_end := scanner.start
			for span_end < scanner.end {
				ch := scanner.buffer[span_end]
				if ch == '"' || ch == '\n' || ch == '\r' {
					break
				}
				span_end += 1
			}
			if span_end > scanner.start {
				append(&scanner.scratch, ..scanner.buffer[scanner.start:span_end])
				scanner.start = span_end
				limit_err := check_limits(scanner, field_start)
				if limit_err != .None {
					return {}, false, limit_err
				}
			}
			if span_end >= scanner.end {
				continue
			}
			ch := scanner.buffer[span_end]
			if ch == '\n' || ch == '\r' {
				return {}, false, .Multiline_Quoted_Field
			}
			scanner.start = span_end + 1
			next_byte, has_next, peek_err := peek_scanner_byte(scanner)
			if peek_err != .None {
				return {}, false, peek_err
			}
			if has_next && next_byte == '"' {
				append(&scanner.scratch, byte('"'))
				scanner.start += 1
				limit_err := check_limits(scanner, field_start)
				if limit_err != .None {
					return {}, false, limit_err
				}
			} else {
				in_quotes = false
			}
			continue
		}

		span_end := scanner.start
		for span_end < scanner.end {
			ch := scanner.buffer[span_end]
			if ch == ',' || ch == '\n' || ch == '\r' || ch == '"' {
				break
			}
			span_end += 1
		}
		if span_end > scanner.start {
			if field_quoted {
				return {}, false, .Parse
			}
			append(&scanner.scratch, ..scanner.buffer[scanner.start:span_end])
			scanner.start = span_end
			limit_err := check_limits(scanner, field_start)
			if limit_err != .None {
				return {}, false, limit_err
			}
		}
		if span_end >= scanner.end {
			continue
		}
		ch := scanner.buffer[span_end]
		scanner.start = span_end + 1
		switch ch {
		case '"':
			if len(scanner.scratch) > field_start || field_quoted {
				return {}, false, .Parse
			}
			in_quotes = true
			field_quoted = true
		case ',':
			finish_err := finish_field(scanner, &field_start, &field_quoted)
			if finish_err != .None {
				return {}, false, finish_err
			}
		case '\n':
			finish_err := finish_field(scanner, &field_start, &field_quoted)
			if finish_err != .None {
				return {}, false, finish_err
			}
			scanner.line += 1
			return emit_record(scanner, record_line), false, .None
		case '\r':
			next_byte, has_next, peek_err := peek_scanner_byte(scanner)
			if peek_err != .None {
				return {}, false, peek_err
			}
			if !has_next || next_byte != '\n' {
				return {}, false, .Parse
			}
		}
	}
}
