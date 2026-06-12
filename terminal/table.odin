package tablefmt

import "base:runtime"
import "core:strings"
import "core:unicode/utf8"

MAX_CELL_WIDTH :: 64

Alignment :: enum {
	Left,
	Right,
}

render_table :: proc(
	headers: []string,
	cells: []string,
	alignments: []Alignment,
	allocator := context.allocator,
) -> (string, bool) {
	column_count := len(headers)
	if column_count == 0 ||
	   len(alignments) != column_count ||
	   len(cells)%column_count != 0 {
		return "", false
	}

	wrapped_headers, headers_ok := wrap_values(headers, context.temp_allocator)
	if !headers_ok {
		return "", false
	}
	wrapped_cells, cells_ok := wrap_values(cells, context.temp_allocator)
	if !cells_ok {
		return "", false
	}

	widths, allocation_error := make([]int, column_count, context.temp_allocator)
	if allocation_error != nil {
		return "", false
	}
	for header, column_index in wrapped_headers {
		widths[column_index] = multiline_display_width(header)
	}
	for cell, cell_index in wrapped_cells {
		column_index := cell_index%column_count
		widths[column_index] = max(widths[column_index], multiline_display_width(cell))
	}

	builder, builder_error := strings.builder_make(allocator)
	if builder_error != nil {
		return "", false
	}
	defer strings.builder_destroy(&builder)

	write_row(&builder, wrapped_headers, widths, alignments)
	write_separator(&builder, widths)
	for row_start := 0; row_start < len(wrapped_cells); row_start += column_count {
		write_row(
			&builder,
			wrapped_cells[row_start:row_start+column_count],
			widths,
			alignments,
		)
	}

	rendered, clone_error := strings.clone(strings.to_string(builder), allocator)
	if clone_error != nil {
		return "", false
	}
	return rendered, true
}

write_row :: proc(
	builder: ^strings.Builder,
	values: []string,
	widths: []int,
	alignments: []Alignment,
) {
	row_height := 1
	for value in values {
		row_height = max(row_height, line_count(value))
	}

	for line_index in 0..<row_height {
		for value, column_index in values {
			if column_index > 0 {
				strings.write_string(builder, "  ")
			}
			line, found := line_at(value, line_index)
			if !found {
				line = ""
			}
			padding := widths[column_index]-display_width(line)
			if alignments[column_index] == .Right {
				write_repeat(builder, ' ', padding)
			}
			strings.write_string(builder, line)
			if alignments[column_index] == .Left {
				write_repeat(builder, ' ', padding)
			}
		}
		strings.write_byte(builder, '\n')
	}
}

write_separator :: proc(builder: ^strings.Builder, widths: []int) {
	for width, column_index in widths {
		if column_index > 0 {
			strings.write_string(builder, "  ")
		}
		write_repeat(builder, '-', width)
	}
	strings.write_byte(builder, '\n')
}

write_repeat :: proc(builder: ^strings.Builder, value: byte, count: int) {
	for _ in 0..<count {
		strings.write_byte(builder, value)
	}
}

display_width :: proc(value: string) -> int {
	_, _, width := utf8.grapheme_count(value)
	return width
}

wrap_values :: proc(
	values: []string,
	allocator: runtime.Allocator,
) -> ([]string, bool) {
	result, allocation_error := make([]string, len(values), allocator)
	if allocation_error != nil {
		return nil, false
	}
	for value, index in values {
		wrapped, ok := wrap_words(value, MAX_CELL_WIDTH, allocator)
		if !ok {
			return nil, false
		}
		result[index] = wrapped
	}
	return result, true
}

wrap_words :: proc(
	value: string,
	max_width: int,
	allocator: runtime.Allocator,
) -> (string, bool) {
	if max_width < 1 {
		return "", false
	}
	words, fields_error := strings.fields(value, context.temp_allocator)
	if fields_error != nil {
		return "", false
	}
	if display_width(value) <= max_width {
		return value, true
	}

	builder, builder_error := strings.builder_make(allocator)
	if builder_error != nil {
		return "", false
	}
	defer strings.builder_destroy(&builder)

	line_width := 0
	for word in words {
		word_width := display_width(word)
		if line_width > 0 && line_width+1+word_width <= max_width {
			strings.write_byte(&builder, ' ')
			line_width += 1
		} else if line_width > 0 {
			strings.write_byte(&builder, '\n')
			line_width = 0
		}

		if word_width <= max_width {
			strings.write_string(&builder, word)
			line_width += word_width
			continue
		}

		for ch in word {
			if line_width >= max_width {
				strings.write_byte(&builder, '\n')
				line_width = 0
			}
			strings.write_rune(&builder, ch)
			line_width += 1
		}
	}
	wrapped, clone_error := strings.clone(strings.to_string(builder), allocator)
	if clone_error != nil {
		return "", false
	}
	return wrapped, true
}

multiline_display_width :: proc(value: string) -> int {
	width := 0
	remaining := value
	for {
		line, found := next_line(&remaining)
		width = max(width, display_width(line))
		if !found {
			break
		}
	}
	return width
}

line_count :: proc(value: string) -> int {
	count := 1
	for ch in value {
		if ch == '\n' {
			count += 1
		}
	}
	return count
}

line_at :: proc(value: string, target: int) -> (string, bool) {
	remaining := value
	for index in 0..=target {
		line, has_more := next_line(&remaining)
		if index == target {
			return line, true
		}
		if !has_more {
			return "", false
		}
	}
	return "", false
}

next_line :: proc(value: ^string) -> (string, bool) {
	if newline := strings.index_byte(value^, '\n'); newline >= 0 {
		line := value^[:newline]
		value^ = value^[newline+1:]
		return line, true
	}
	line := value^
	value^ = ""
	return line, false
}
