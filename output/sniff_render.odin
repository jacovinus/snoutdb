package result_output

import "base:runtime"
import "core:fmt"
import "core:io"
import "core:math"
import "core:strings"
import snout_core "../core"
import query "../query"
import sniff "../sniff"
import tablefmt "../terminal"

write_sniff_report :: proc(
	writer: io.Writer,
	report: ^sniff.Sniff_Report,
	source_path: string,
	format: Sniff_Output_Format,
) -> snout_core.Error {
	rendered, err := render_sniff_report(
		report,
		source_path,
		format,
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

render_sniff_report :: proc(
	report: ^sniff.Sniff_Report,
	source_path: string,
	format: Sniff_Output_Format,
	allocator := context.allocator,
) -> (string, snout_core.Error) {
	switch format {
	case .Table:
		return render_sniff_table(report, source_path, allocator)
	case .JSON:
		return render_sniff_json(report, source_path, allocator)
	}
	return "", .Invalid_Output_Format
}

render_sniff_table :: proc(
	report: ^sniff.Sniff_Report,
	source_path: string,
	allocator: runtime.Allocator,
) -> (string, snout_core.Error) {
	builder, builder_err := strings.builder_make(allocator)
	if builder_err != nil {
		return "", .Out_Of_Memory
	}
	defer strings.builder_destroy(&builder)

	fmt.sbprintfln(&builder, "table: %s", report.table_name)
	fmt.sbprintfln(&builder, "rows: %d", report.row_count)
	fmt.sbprintfln(&builder, "columns: %d", report.column_count)
	fmt.sbprintfln(&builder, "profile_version: %d", report.version)
	strings.write_byte(&builder, '\n')

	role_counts := count_roles(report.columns)
	fmt.sbprintln(&builder, "roles")
	fmt.sbprintln(&builder, "-----")
	fmt.sbprintfln(&builder, "timestamps:  %d", role_counts.timestamp)
	fmt.sbprintfln(&builder, "identifiers: %d", role_counts.identifier)
	fmt.sbprintfln(&builder, "dimensions:  %d", role_counts.dimension)
	fmt.sbprintfln(&builder, "metrics:     %d", role_counts.metric)
	fmt.sbprintfln(&builder, "unknown:     %d", role_counts.unknown)
	strings.write_byte(&builder, '\n')

	headers := []string{"column", "type", "role", "nulls", "distinct", "details"}
	alignments := []tablefmt.Alignment{
		.Left, .Left, .Left, .Right, .Right, .Left,
	}
	cells := make([dynamic]string, 0, len(report.columns)*6, context.temp_allocator)
	for &column in report.columns {
		append(&cells, column.name)
		append(&cells, snout_core.column_type_name(column.kind))
		append(&cells, sniff.role_display_name(column.role))
		append(&cells, fmt.tprintf("%d", column.null_count))
		append(&cells, format_distinct(column.cardinality))
		append(&cells, format_column_details(&column))
	}
	table_text, table_ok := tablefmt.render_table(headers, cells[:], alignments, context.temp_allocator)
	if !table_ok {
		return "", .Out_Of_Memory
	}
	strings.write_string(&builder, table_text)
	strings.write_byte(&builder, '\n')

	if len(report.suggestions) > 0 {
		fmt.sbprintln(&builder, "suggested queries")
		fmt.sbprintln(&builder, "-----------------")
		for &suggestion, index in report.suggestions {
			fmt.sbprintfln(&builder, "%d. %s", index+1, suggestion.reason)
			fmt.sbprintfln(
				&builder,
				"   %s",
				render_suggestion_command(source_path, &suggestion),
			)
		}
		strings.write_byte(&builder, '\n')
	}

	if len(report.warnings) > 0 {
		fmt.sbprintln(&builder, "warnings")
		fmt.sbprintln(&builder, "--------")
		for warning in report.warnings {
			fmt.sbprintfln(&builder, "- %s", warning)
		}
	}

	return clone_builder_string(&builder, allocator)
}

Role_Counts :: struct {
	timestamp:  int,
	identifier: int,
	dimension:  int,
	metric:     int,
	unknown:    int,
}

count_roles :: proc(columns: []sniff.Column_Profile) -> Role_Counts {
	counts: Role_Counts
	for &column in columns {
		switch column.role {
		case .Timestamp:  counts.timestamp += 1
		case .Identifier: counts.identifier += 1
		case .Dimension:  counts.dimension += 1
		case .Metric:     counts.metric += 1
		case .Unknown:    counts.unknown += 1
		}
	}
	return counts
}

format_distinct :: proc(cardinality: sniff.Cardinality_Profile) -> string {
	if cardinality.exact {
		return fmt.tprintf("%d", cardinality.distinct_count)
	}
	return fmt.tprintf(">%d", cardinality.lower_bound-1)
}

format_column_details :: proc(column: ^sniff.Column_Profile) -> string {
	switch column.role {
	case .Timestamp:
		if column.timestamp.valid {
			return fmt.tprintf(
				"min=%s max=%s",
				column.timestamp.min,
				column.timestamp.max,
			)
		}
	case .Identifier:
		if column.cardinality.exact && column.non_null_count > 0 {
			ratio := f64(column.cardinality.distinct_count) / f64(column.non_null_count)
			return fmt.tprintf("%.2f%% unique", ratio*100.0)
		}
	case .Dimension:
		if len(column.top_values) > 0 {
			parts := make([dynamic]string, 0, len(column.top_values), context.temp_allocator)
			for top in column.top_values {
				append(&parts, fmt.tprintf("%s (%d)", format_profile_value(top.value), top.count))
			}
			return fmt.tprintf("top: %s", strings.join(parts[:], ", ", context.temp_allocator))
		}
	case .Metric:
		if column.numeric.valid {
			base: string
			if column.numeric.kind == .Int64 {
				base = fmt.tprintf(
					"min=%d mean=%.2f max=%d σ=%.2f",
					column.numeric.int_min,
					column.numeric.mean,
					column.numeric.int_max,
					column.numeric.std_dev,
				)
			} else {
				base = fmt.tprintf(
					"min=%.2f mean=%.2f max=%.2f σ=%.2f",
					column.numeric.float_min,
					column.numeric.mean,
					column.numeric.float_max,
					column.numeric.std_dev,
				)
			}
			if column.numeric.outlier_count > 0 {
				return fmt.tprintf("%s  outliers=%d", base, column.numeric.outlier_count)
			}
			return base
		}
	case .Unknown:
		return column.role_reason
	}
	return column.role_reason
}

format_profile_value :: proc(value: sniff.Profile_Value) -> string {
	#partial switch value.kind {
	case .String:
		return value.string_value
	case .Int64:
		return fmt.tprintf("%d", value.int_value)
	case .Bool:
		return "true" if value.bool_value else "false"
	case:
		return ""
	}
	return ""
}

render_suggestion_command :: proc(source_path: string, suggestion: ^sniff.Query_Suggestion) -> string {
	builder: strings.Builder
	strings.builder_init(&builder, context.temp_allocator)
	defer strings.builder_destroy(&builder)

	fmt.sbprintf(&builder, "./snout -f %s", source_path)
	if len(suggestion.group_columns) > 0 {
		fmt.sbprintf(&builder, " group=%s", strings.join(suggestion.group_columns[:], ",", context.temp_allocator))
	}
	if len(suggestion.aggregates) > 0 {
		strings.write_string(&builder, " --")
		for aggregate in suggestion.aggregates {
			column_name := aggregate.column_name
			if aggregate.kind == .Count && column_name == "*" {
				column_name = "rows"
			}
			fmt.sbprintf(
				&builder,
				" %s=%s",
				query.aggregate_name(aggregate),
				column_name,
			)
		}
	}
	for sort_term in suggestion.sort_terms {
		fmt.sbprintf(&builder, " --sort %s %s", sort_term.target, sort_direction_name(sort_term.direction))
	}
	if suggestion.limit > 0 {
		fmt.sbprintf(&builder, " --limit %d", suggestion.limit)
	}
	return strings.to_string(builder)
}

sort_direction_name :: proc(direction: query.Sort_Direction) -> string {
	switch direction {
	case .Ascending:  return "asc"
	case .Descending: return "desc"
	}
	return "asc"
}

render_sniff_json :: proc(
	report: ^sniff.Sniff_Report,
	source_path: string,
	allocator: runtime.Allocator,
) -> (string, snout_core.Error) {
	builder, builder_err := strings.builder_make(allocator)
	if builder_err != nil {
		return "", .Out_Of_Memory
	}
	defer strings.builder_destroy(&builder)

	role_counts := count_roles(report.columns)
	strings.write_string(&builder, "{\n")
	write_json_field_name(&builder, "version")
	fmt.sbprintf(&builder, "%d,\n", report.version)
	write_json_field_name(&builder, "table")
	strings.write_string(&builder, "{\n")
	write_json_field_name(&builder, "name")
	write_json_string(&builder, report.table_name)
	strings.write_string(&builder, ",\n")
	write_json_field_name(&builder, "rows")
	fmt.sbprintf(&builder, "%d,\n", report.row_count)
	write_json_field_name(&builder, "columns")
	fmt.sbprintf(&builder, "%d\n", report.column_count)
	strings.write_string(&builder, "},\n")
	write_json_field_name(&builder, "role_counts")
	strings.write_string(&builder, "{\n")
	write_json_field_name(&builder, "timestamp")
	fmt.sbprintf(&builder, "%d,\n", role_counts.timestamp)
	write_json_field_name(&builder, "identifier")
	fmt.sbprintf(&builder, "%d,\n", role_counts.identifier)
	write_json_field_name(&builder, "dimension")
	fmt.sbprintf(&builder, "%d,\n", role_counts.dimension)
	write_json_field_name(&builder, "metric")
	fmt.sbprintf(&builder, "%d,\n", role_counts.metric)
	write_json_field_name(&builder, "unknown")
	fmt.sbprintf(&builder, "%d\n", role_counts.unknown)
	strings.write_string(&builder, "},\n")
	write_json_field_name(&builder, "columns")
	strings.write_string(&builder, "[\n")
	for &column, index in report.columns {
		if index > 0 {
			strings.write_byte(&builder, ',')
		}
		write_json_column(&builder, &column)
	}
	strings.write_string(&builder, "],\n")
	write_json_field_name(&builder, "suggestions")
	strings.write_string(&builder, "[\n")
	for &suggestion, index in report.suggestions {
		if index > 0 {
			strings.write_byte(&builder, ',')
		}
		write_json_suggestion(&builder, source_path, &suggestion)
	}
	strings.write_string(&builder, "],\n")
	write_json_field_name(&builder, "warnings")
	strings.write_string(&builder, "[\n")
	for warning, index in report.warnings {
		if index > 0 {
			strings.write_byte(&builder, ',')
		}
		strings.write_byte(&builder, '\n')
		write_json_string(&builder, warning)
	}
	strings.write_string(&builder, "\n]\n}\n")
	return clone_builder_string(&builder, allocator)
}

write_json_field_name :: proc(builder: ^strings.Builder, name: string) {
	strings.write_byte(builder, ' ')
	write_json_string(builder, name)
	strings.write_string(builder, ": ")
}

write_json_column :: proc(builder: ^strings.Builder, column: ^sniff.Column_Profile) {
	strings.write_string(builder, "{\n")
	write_json_field_name(builder, "name")
	write_json_string(builder, column.name)
	strings.write_string(builder, ",\n")
	write_json_field_name(builder, "type")
	write_json_string(builder, snout_core.column_type_name(column.kind))
	strings.write_string(builder, ",\n")
	write_json_field_name(builder, "role")
	write_json_string(builder, sniff.role_name(column.role))
	strings.write_string(builder, ",\n")
	write_json_field_name(builder, "role_reason")
	write_json_string(builder, column.role_reason)
	strings.write_string(builder, ",\n")
	write_json_field_name(builder, "rows")
	fmt.sbprintf(builder, "%d,\n", column.row_count)
	write_json_field_name(builder, "nulls")
	fmt.sbprintf(builder, "%d,\n", column.null_count)
	write_json_field_name(builder, "non_nulls")
	fmt.sbprintf(builder, "%d,\n", column.non_null_count)
	write_json_field_name(builder, "null_ratio")
	write_json_float(builder, column.null_ratio)
	strings.write_string(builder, ",\n")
	write_json_field_name(builder, "cardinality")
	write_json_cardinality(builder, column.cardinality)
	strings.write_string(builder, ",\n")
	write_json_field_name(builder, "numeric")
	write_json_numeric(builder, column.numeric)
	strings.write_string(builder, ",\n")
	write_json_field_name(builder, "timestamp")
	write_json_timestamp(builder, column.timestamp)
	strings.write_string(builder, ",\n")
	write_json_field_name(builder, "top_values")
	write_json_top_values(builder, column.top_values)
	strings.write_string(builder, "\n}")
}

write_json_cardinality :: proc(builder: ^strings.Builder, cardinality: sniff.Cardinality_Profile) {
	strings.write_string(builder, "{\n")
	write_json_field_name(builder, "exact")
	fmt.sbprintf(builder, "%s,\n", "true" if cardinality.exact else "false")
	write_json_field_name(builder, "distinct_count")
	if cardinality.exact {
		fmt.sbprintf(builder, "%d,\n", cardinality.distinct_count)
	} else {
		strings.write_string(builder, "null,\n")
	}
	write_json_field_name(builder, "lower_bound")
	if cardinality.exact {
		strings.write_string(builder, "null\n")
	} else {
		fmt.sbprintf(builder, "%d\n", cardinality.lower_bound)
	}
	strings.write_string(builder, "}")
}

write_json_numeric :: proc(builder: ^strings.Builder, numeric: sniff.Numeric_Profile) {
	if !numeric.valid {
		strings.write_string(builder, "null")
		return
	}
	strings.write_string(builder, "{\n")
	write_json_field_name(builder, "count")
	fmt.sbprintf(builder, "%d,\n", numeric.count)
	write_json_field_name(builder, "min")
	if numeric.kind == .Int64 {
		fmt.sbprintf(builder, "%d,\n", numeric.int_min)
	} else {
		if err := write_json_finite_float(builder, numeric.float_min); err != .None {
			return
		}
		strings.write_byte(builder, ',')
		strings.write_byte(builder, '\n')
	}
	write_json_field_name(builder, "max")
	if numeric.kind == .Int64 {
		fmt.sbprintf(builder, "%d,\n", numeric.int_max)
	} else {
		if err := write_json_finite_float(builder, numeric.float_max); err != .None {
			return
		}
		strings.write_byte(builder, ',')
		strings.write_byte(builder, '\n')
	}
	write_json_field_name(builder, "mean")
	write_json_float(builder, numeric.mean)
	strings.write_string(builder, ",\n")
	write_json_field_name(builder, "std_dev")
	write_json_float(builder, numeric.std_dev)
	strings.write_string(builder, ",\n")
	write_json_field_name(builder, "outlier_count")
	fmt.sbprintf(builder, "%d\n", numeric.outlier_count)
	strings.write_string(builder, "}")
}

write_json_timestamp :: proc(builder: ^strings.Builder, timestamp: sniff.Timestamp_Profile) {
	if !timestamp.valid {
		strings.write_string(builder, "null")
		return
	}
	strings.write_string(builder, "{\n")
	write_json_field_name(builder, "min")
	write_json_string(builder, timestamp.min)
	strings.write_string(builder, ",\n")
	write_json_field_name(builder, "max")
	write_json_string(builder, timestamp.max)
	strings.write_string(builder, "\n}")
}

write_json_top_values :: proc(builder: ^strings.Builder, top_values: []sniff.Top_Value) {
	strings.write_string(builder, "[\n")
	for top, index in top_values {
		if index > 0 {
			strings.write_byte(builder, ',')
		}
		strings.write_string(builder, "{\n")
		write_json_field_name(builder, "value")
		write_json_profile_value(builder, top.value)
		strings.write_string(builder, ",\n")
		write_json_field_name(builder, "count")
		fmt.sbprintf(builder, "%d\n", top.count)
		strings.write_string(builder, "}")
	}
	strings.write_string(builder, "\n]")
}

write_json_profile_value :: proc(builder: ^strings.Builder, value: sniff.Profile_Value) {
	#partial switch value.kind {
	case .String:
		write_json_string(builder, value.string_value)
	case .Int64:
		fmt.sbprintf(builder, "%d", value.int_value)
	case .Bool:
		strings.write_string(builder, "true" if value.bool_value else "false")
	case:
		strings.write_string(builder, "null")
	}
}

write_json_suggestion :: proc(
	builder: ^strings.Builder,
	source_path: string,
	suggestion: ^sniff.Query_Suggestion,
) {
	strings.write_string(builder, "{\n")
	write_json_field_name(builder, "reason")
	write_json_string(builder, suggestion.reason)
	strings.write_string(builder, ",\n")
	write_json_field_name(builder, "group")
	strings.write_string(builder, "[")
	for column_name, index in suggestion.group_columns {
		if index > 0 {
			strings.write_byte(builder, ',')
		}
		write_json_string(builder, column_name)
	}
	strings.write_string(builder, "],\n")
	write_json_field_name(builder, "aggregates")
	strings.write_string(builder, "[")
	for aggregate, index in suggestion.aggregates {
		if index > 0 {
			strings.write_byte(builder, ',')
		}
		column_name := aggregate.column_name
		if aggregate.kind == .Count && column_name == "*" {
			column_name = "rows"
		}
		write_json_string(builder, fmt.tprintf("%s=%s", query.aggregate_name(aggregate), column_name))
	}
	strings.write_string(builder, "],\n")
	write_json_field_name(builder, "sort")
	strings.write_string(builder, "[\n")
	for sort_term, index in suggestion.sort_terms {
		if index > 0 {
			strings.write_byte(builder, ',')
		}
		strings.write_string(builder, "{\n")
		write_json_field_name(builder, "target")
		write_json_string(builder, sort_term.target)
		strings.write_string(builder, ",\n")
		write_json_field_name(builder, "direction")
		write_json_string(builder, sort_direction_name(sort_term.direction))
		strings.write_string(builder, "\n}")
	}
	strings.write_string(builder, "\n],\n")
	write_json_field_name(builder, "limit")
	fmt.sbprintf(builder, "%d,\n", suggestion.limit)
	write_json_field_name(builder, "command")
	write_json_string(builder, render_suggestion_command(source_path, suggestion))
	strings.write_string(builder, "\n}")
}

write_json_float :: proc(builder: ^strings.Builder, value: f64) {
	if math.is_nan(value) || math.is_inf(value) {
		strings.write_string(builder, "null")
		return
	}
	fmt.sbprintf(builder, "%g", value)
}

write_json_finite_float :: proc(builder: ^strings.Builder, value: f64) -> snout_core.Error {
	if math.is_nan(value) || math.is_inf(value) {
		return .Invalid_Numeric_Output
	}
	fmt.sbprintf(builder, "%g", value)
	return .None
}
