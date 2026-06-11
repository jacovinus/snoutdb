package result_output

import "base:runtime"
import "core:fmt"
import "core:io"
import "core:math"
import "core:strings"
import snout_core "../core"
import query "../query"
import tablefmt "../terminal"

render_group_results :: proc(
	result: ^query.Group_Result_Set,
	groups: []query.Group_Result,
	format: Output_Format,
	has_limit := false,
	allocator := context.allocator,
) -> (string, snout_core.Error) {
	switch format {
	case .Table:
		return render_table(result, groups, has_limit, allocator)
	case .CSV:
		return render_csv(result, groups, allocator)
	case .JSON:
		return render_json(result, groups, allocator)
	case .JSONL:
		return render_jsonl(result, groups, allocator)
	}
	return "", .Invalid_Output_Format
}

write_group_results :: proc(
	writer: io.Writer,
	result: ^query.Group_Result_Set,
	groups: []query.Group_Result,
	format: Output_Format,
	has_limit := false,
) -> snout_core.Error {
	rendered, err := render_group_results(
		result,
		groups,
		format,
		has_limit,
		context.temp_allocator,
	)
	if err != .None {
		return err
	}
	written, write_err := io.write_string(writer, rendered)
	if write_err != nil || written != len(rendered) {
		return .Output_Write_Failed
	}
	return .None
}

render_table :: proc(
	result: ^query.Group_Result_Set,
	groups: []query.Group_Result,
	has_limit: bool,
	allocator: runtime.Allocator,
) -> (string, snout_core.Error) {
	headers, alignments := make_schema(result)
	cells := make(
		[dynamic]string,
		0,
		len(groups)*len(headers),
		allocator=context.temp_allocator,
	)
	for group in groups {
		for key in group.keys {
			append(&cells, format_group_key(key, true))
		}
		for value in group.values {
			formatted, err := format_aggregate_value(value, true)
			if err != .None {
				return "", err
			}
			append(&cells, formatted)
		}
	}
	table, ok := tablefmt.render_table(
		headers[:],
		cells[:],
		alignments[:],
		context.temp_allocator,
	)
	if !ok {
		return "", .Out_Of_Memory
	}
	builder, builder_err := strings.builder_make(allocator)
	if builder_err != nil {
		return "", .Out_Of_Memory
	}
	defer strings.builder_destroy(&builder)

	group_text := strings.join(result.group_columns, ",", context.temp_allocator)
	fmt.sbprintfln(&builder, "group: %s", group_text)
	fmt.sbprintfln(&builder, "aggregates: %d", len(result.aggregates))
	fmt.sbprintfln(&builder, "filters: %d", result.filter_count)
	fmt.sbprintfln(&builder, "selected_rows: %d", result.selected_rows)
	fmt.sbprintfln(&builder, "groups: %d", len(result.groups))
	if has_limit {
		fmt.sbprintfln(&builder, "shown: %d", len(groups))
	}
	strings.write_byte(&builder, '\n')
	strings.write_string(&builder, table)
	return clone_builder_string(&builder, allocator)
}

render_csv :: proc(
	result: ^query.Group_Result_Set,
	groups: []query.Group_Result,
	allocator: runtime.Allocator,
) -> (string, snout_core.Error) {
	builder, builder_err := strings.builder_make(allocator)
	if builder_err != nil {
		return "", .Out_Of_Memory
	}
	defer strings.builder_destroy(&builder)
	headers, _ := make_schema(result)
	for header, index in headers {
		if index > 0 {
			strings.write_byte(&builder, ',')
		}
		write_csv_string(&builder, header, false)
	}
	strings.write_byte(&builder, '\n')

	for group in groups {
		column_index := 0
		for key in group.keys {
			if column_index > 0 {
				strings.write_byte(&builder, ',')
			}
			write_csv_group_key(&builder, key)
			column_index += 1
		}
		for value in group.values {
			if column_index > 0 {
				strings.write_byte(&builder, ',')
			}
			if value.valid {
				formatted, err := format_aggregate_value(value, false)
				if err != .None {
					return "", err
				}
				strings.write_string(&builder, formatted)
			}
			column_index += 1
		}
		strings.write_byte(&builder, '\n')
	}
	return clone_builder_string(&builder, allocator)
}

render_jsonl :: proc(
	result: ^query.Group_Result_Set,
	groups: []query.Group_Result,
	allocator: runtime.Allocator,
) -> (string, snout_core.Error) {
	builder, builder_err := strings.builder_make(allocator)
	if builder_err != nil {
		return "", .Out_Of_Memory
	}
	defer strings.builder_destroy(&builder)
	headers, _ := make_schema(result)

	for group in groups {
		strings.write_byte(&builder, '{')
		column_index := 0
		for key in group.keys {
			if column_index > 0 {
				strings.write_byte(&builder, ',')
			}
			write_json_string(&builder, headers[column_index])
			strings.write_byte(&builder, ':')
			write_json_group_key(&builder, key)
			column_index += 1
		}
		for value in group.values {
			if column_index > 0 {
				strings.write_byte(&builder, ',')
			}
			write_json_string(&builder, headers[column_index])
			strings.write_byte(&builder, ':')
			if !value.valid {
				strings.write_string(&builder, "null")
			} else {
				formatted, err := format_aggregate_value(value, false)
				if err != .None {
					return "", err
				}
				strings.write_string(&builder, formatted)
			}
			column_index += 1
		}
		strings.write_string(&builder, "}\n")
	}
	return clone_builder_string(&builder, allocator)
}

render_json :: proc(
	result: ^query.Group_Result_Set,
	groups: []query.Group_Result,
	allocator: runtime.Allocator,
) -> (string, snout_core.Error) {
	builder, builder_err := strings.builder_make(allocator)
	if builder_err != nil {
		return "", .Out_Of_Memory
	}
	defer strings.builder_destroy(&builder)
	headers, _ := make_schema(result)

	strings.write_byte(&builder, '[')
	for group, group_index in groups {
		if group_index > 0 {
			strings.write_byte(&builder, ',')
		}
		strings.write_byte(&builder, '{')
		column_index := 0
		for key in group.keys {
			if column_index > 0 {
				strings.write_byte(&builder, ',')
			}
			write_json_string(&builder, headers[column_index])
			strings.write_byte(&builder, ':')
			write_json_group_key(&builder, key)
			column_index += 1
		}
		for value in group.values {
			if column_index > 0 {
				strings.write_byte(&builder, ',')
			}
			write_json_string(&builder, headers[column_index])
			strings.write_byte(&builder, ':')
			if !value.valid {
				strings.write_string(&builder, "null")
			} else {
				formatted, err := format_aggregate_value(value, false)
				if err != .None {
					return "", err
				}
				strings.write_string(&builder, formatted)
			}
			column_index += 1
		}
		strings.write_byte(&builder, '}')
	}
	strings.write_string(&builder, "]\n")
	return clone_builder_string(&builder, allocator)
}

make_schema :: proc(
	result: ^query.Group_Result_Set,
) -> ([dynamic]string, [dynamic]tablefmt.Alignment) {
	column_count := len(result.group_columns)+len(result.aggregates)
	headers := make(
		[dynamic]string,
		0,
		column_count,
		allocator=context.temp_allocator,
	)
	alignments := make(
		[dynamic]tablefmt.Alignment,
		0,
		column_count,
		allocator=context.temp_allocator,
	)
	for column_name in result.group_columns {
		append(&headers, column_name)
		append(&alignments, tablefmt.Alignment.Left)
	}
	for spec in result.aggregates {
		append(&headers, aggregate_label(spec))
		append(&alignments, tablefmt.Alignment.Right)
	}
	return headers, alignments
}

aggregate_label :: proc(spec: query.Aggregate_Spec) -> string {
	column_name := spec.column_name
	if spec.kind == .Count && column_name == "*" {
		column_name = "*"
	}
	return fmt.tprintf(
		"%s(%s)",
		query.aggregate_name(spec),
		column_name,
	)
}

format_group_key :: proc(key: query.Group_Key, table_format: bool) -> string {
	if key.is_null {
		return "NULL" if table_format else ""
	}
	switch key.kind {
	case .String, .Timestamp:
		return key.string_value
	case .Int64:
		return fmt.tprintf("%d", key.int_value)
	case .Bool:
		return "true" if key.bool_value else "false"
	case .Float64, .Unknown:
		return ""
	}
	return ""
}

format_aggregate_value :: proc(
	value: query.Aggregate_Value,
	table_format: bool,
) -> (string, snout_core.Error) {
	if !value.valid {
		return "NULL" if table_format else "", .None
	}
	switch value.kind {
	case .Int64:
		return fmt.tprintf("%d", value.int_value), .None
	case .Float64:
		if math.is_nan(value.float_value) || math.is_inf(value.float_value) {
			return "", .Invalid_Numeric_Output
		}
		if table_format {
			return fmt.tprintf("%.6f", value.float_value), .None
		}
		return fmt.tprintf("%g", value.float_value), .None
	case .String, .Timestamp, .Bool, .Unknown:
	}
	return "", .Invalid_Numeric_Output
}

write_csv_group_key :: proc(builder: ^strings.Builder, key: query.Group_Key) {
	if key.is_null {
		return
	}
	switch key.kind {
	case .String, .Timestamp:
		write_csv_string(builder, key.string_value, key.string_value == "")
	case .Int64:
		fmt.sbprintf(builder, "%d", key.int_value)
	case .Bool:
		strings.write_string(builder, "true" if key.bool_value else "false")
	case .Float64, .Unknown:
	}
}

write_csv_string :: proc(
	builder: ^strings.Builder,
	value: string,
	force_quotes: bool,
) {
	needs_quotes := force_quotes
	for character in value {
		if character == ',' || character == '"' ||
		   character == '\r' || character == '\n' {
			needs_quotes = true
			break
		}
	}
	if !needs_quotes {
		strings.write_string(builder, value)
		return
	}
	strings.write_byte(builder, '"')
	for character in value {
		if character == '"' {
			strings.write_string(builder, "\"\"")
		} else {
			strings.write_rune(builder, character)
		}
	}
	strings.write_byte(builder, '"')
}

write_json_group_key :: proc(builder: ^strings.Builder, key: query.Group_Key) {
	if key.is_null {
		strings.write_string(builder, "null")
		return
	}
	switch key.kind {
	case .String, .Timestamp:
		write_json_string(builder, key.string_value)
	case .Int64:
		fmt.sbprintf(builder, "%d", key.int_value)
	case .Bool:
		strings.write_string(builder, "true" if key.bool_value else "false")
	case .Float64, .Unknown:
		strings.write_string(builder, "null")
	}
}

write_json_string :: proc(builder: ^strings.Builder, value: string) {
	writer := strings.to_writer(builder)
	_, _ = io.write_quoted_string(writer, value, '"', nil, true)
}

clone_builder_string :: proc(
	builder: ^strings.Builder,
	allocator: runtime.Allocator,
) -> (string, snout_core.Error) {
	result, err := strings.clone(strings.to_string(builder^), allocator)
	if err != nil {
		return "", .Out_Of_Memory
	}
	return result, .None
}
