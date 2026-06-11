package ingest

import "base:runtime"
import "core:os"
import "core:strings"
import snout_core "../core"

JSONL_SCANNER_BUFFER_SIZE :: 1 * 1024 * 1024

Jsonl_Scanner :: struct {
	file:          ^os.File,
	buffer:        []byte,
	start:         int,
	end:           int,
	eof:           bool,
	line:          int,
	scratch:       [dynamic]u8,
	max_line_size: int,
	allocator:     runtime.Allocator,
}

open_jsonl_scanner :: proc(
	path: string,
	buffer_size := JSONL_SCANNER_BUFFER_SIZE,
	allocator := context.allocator,
) -> (scanner: Jsonl_Scanner, err: snout_core.Error) {
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
	scanner.max_line_size = JSONL_MAX_LINE_SIZE
	scanner.allocator = allocator
	scanner.scratch = make([dynamic]u8, 0, allocator = allocator)
	return scanner, .None
}

close_jsonl_scanner :: proc(scanner: ^Jsonl_Scanner) {
	if scanner.file != nil {
		os.close(scanner.file)
		scanner.file = nil
	}
	if scanner.buffer != nil {
		delete(scanner.buffer, scanner.allocator)
		scanner.buffer = nil
	}
	delete(scanner.scratch)
	scanner.scratch = nil
	scanner.start = 0
	scanner.end = 0
}

@(private = "file")
refill_jsonl_scanner :: proc(scanner: ^Jsonl_Scanner) -> (refilled: bool, err: snout_core.Error) {
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

// next_jsonl_line returns the next non-blank content line. The returned string
// is a view into the scanner's scratch buffer, valid only until the next call
// to next_jsonl_line or close_jsonl_scanner. Blank and whitespace-only lines
// are skipped. done is true when the input is exhausted.
next_jsonl_line :: proc(
	scanner: ^Jsonl_Scanner,
) -> (line: string, done: bool, err: snout_core.Error) {
	for {
		clear(&scanner.scratch)
		at_eof := false

		// Collect bytes for one line.
		collect_loop: for {
			if scanner.start >= scanner.end {
				refilled, refill_err := refill_jsonl_scanner(scanner)
				if refill_err != .None {
					return "", false, refill_err
				}
				if !refilled {
					at_eof = true
					break collect_loop
				}
			}

			span_end := scanner.start
			for span_end < scanner.end {
				ch := scanner.buffer[span_end]
				if ch == '\n' || ch == '\r' {
					break
				}
				span_end += 1
			}

			if span_end > scanner.start {
				append(&scanner.scratch, ..scanner.buffer[scanner.start:span_end])
				scanner.start = span_end
				if len(scanner.scratch) > scanner.max_line_size {
					return "", false, .Line_Too_Large
				}
			}

			if scanner.start >= scanner.end {
				continue collect_loop
			}

			// Consume the newline character.
			ch := scanner.buffer[scanner.start]
			scanner.start += 1
			if ch == '\r' {
				// Consume optional \n after \r.
				if scanner.start < scanner.end {
					if scanner.buffer[scanner.start] == '\n' {
						scanner.start += 1
					}
				} else {
					// \r at buffer boundary — peek next chunk.
					refilled, refill_err := refill_jsonl_scanner(scanner)
					if refill_err != .None {
						return "", false, refill_err
					}
					if refilled && scanner.buffer[scanner.start] == '\n' {
						scanner.start += 1
					}
				}
			}
			scanner.line += 1
			break collect_loop
		}

		// at_eof with nothing in scratch → truly exhausted.
		if at_eof && len(scanner.scratch) == 0 {
			return "", true, .None
		}

		// Size check for files without a trailing newline.
		if len(scanner.scratch) > scanner.max_line_size {
			return "", false, .Line_Too_Large
		}

		trimmed := strings.trim_space(string(scanner.scratch[:]))
		if trimmed != "" {
			return trimmed, false, .None
		}
		// Blank line: if at EOF nothing more to read, otherwise loop.
		if at_eof {
			return "", true, .None
		}
	}
}
