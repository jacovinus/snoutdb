package tests

import "core:strings"
import "core:testing"
import tablefmt "../terminal"

@(test)
terminal_table_aligns_text_and_numbers :: proc(t: ^testing.T) {
	headers := [?]string{"region", "count", "avg(mos)"}
	cells := [?]string{
		"ap-south", "20", "3.784000",
		"eu-central", "6", "3.798846",
	}
	alignments := [?]tablefmt.Alignment{.Left, .Right, .Right}

	rendered, ok := tablefmt.render_table(headers[:], cells[:], alignments[:])
	testing.expect(t, ok)
	if !ok {
		return
	}
	defer delete(rendered)

	expected :=
		"region      count  avg(mos)\n" +
		"----------  -----  --------\n" +
		"ap-south       20  3.784000\n" +
		"eu-central      6  3.798846\n"
	testing.expect_value(t, rendered, expected)
}

@(test)
terminal_table_handles_nulls_and_unicode_width :: proc(t: ^testing.T) {
	headers := [?]string{"región", "value"}
	cells := [?]string{
		"España", "NULL",
		"日本", "42",
	}
	alignments := [?]tablefmt.Alignment{.Left, .Right}

	rendered, ok := tablefmt.render_table(headers[:], cells[:], alignments[:])
	testing.expect(t, ok)
	if !ok {
		return
	}
	defer delete(rendered)

	expected :=
		"región  value\n" +
		"------  -----\n" +
		"España   NULL\n" +
		"日本       42\n"
	testing.expect_value(t, rendered, expected)
}

@(test)
terminal_table_rejects_invalid_shapes :: proc(t: ^testing.T) {
	headers := [?]string{"a", "b"}
	cells := [?]string{"only-one-cell"}
	alignments := [?]tablefmt.Alignment{.Left, .Right}

	rendered, ok := tablefmt.render_table(headers[:], cells[:], alignments[:])
	testing.expect(t, !ok)
	testing.expect_value(t, rendered, "")
}

@(test)
terminal_table_wraps_cells_and_keeps_row_columns_aligned :: proc(t: ^testing.T) {
	headers := [?]string{"name", "details", "count"}
	cells := [?]string{
		"diagnostic",
		"one two three four five six seven eight nine ten eleven twelve thirteen fourteen",
		"6",
	}
	alignments := [?]tablefmt.Alignment{.Left, .Left, .Right}

	rendered, ok := tablefmt.render_table(headers[:], cells[:], alignments[:])
	testing.expect(t, ok)
	if !ok {
		return
	}
	defer delete(rendered)

	expected :=
		"name        details                                                         count\n" +
		"----------  --------------------------------------------------------------  -----\n" +
		"diagnostic  one two three four five six seven eight nine ten eleven twelve      6\n" +
		"            thirteen fourteen                                                    \n"
	testing.expect_value(t, rendered, expected)
}

@(test)
terminal_table_wraps_every_cell_to_the_same_row_height :: proc(t: ^testing.T) {
	headers := [?]string{"left", "right"}
	cells := [?]string{
		"one two three four five six seven eight nine ten eleven twelve thirteen",
		"a b c d e f g h i j k l m n o",
	}
	alignments := [?]tablefmt.Alignment{.Left, .Right}

	rendered, ok := tablefmt.render_table(headers[:], cells[:], alignments[:])
	testing.expect(t, ok)
	if !ok {
		return
	}
	defer delete(rendered)

	expected :=
		"left                                                                                    right\n" +
		"--------------------------------------------------------------  -----------------------------\n" +
		"one two three four five six seven eight nine ten eleven twelve  a b c d e f g h i j k l m n o\n" +
		"thirteen                                                                                     \n"
	testing.expect_value(t, rendered, expected)
}

@(test)
terminal_table_hard_wraps_long_tokens :: proc(t: ^testing.T) {
	headers := [?]string{"level", "message", "count"}
	cells := [?]string{
		"WARN",
		"https://securetoken.googleapis.com/v1/token?key=abcdefghijklmnopqrstuvwxyz0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZ",
		"11",
	}
	alignments := [?]tablefmt.Alignment{.Left, .Left, .Right}

	rendered, ok := tablefmt.render_table(headers[:], cells[:], alignments[:])
	testing.expect(t, ok)
	if !ok {
		return
	}
	defer delete(rendered)

	remaining := rendered
	for line in strings.split_lines_iterator(&remaining) {
		testing.expect(t, tablefmt.display_width(line) <= 82, "rendered row exceeds table width")
	}
}
