package main

import "core:fmt"
import "core:io"
import "core:os"
import "core:strings"
import snout_core "../../core"
import ingest "../../ingest"
import result_output "../../output"
import query "../../query"

Pending_Sort :: struct {
	target:    string,
	direction: query.Sort_Direction,
}

run_group_command :: proc(args: []string) {
	if len(args) < 4 {
		print_usage()
		os.exit(1)
	}
	input_path := args[0]
	stdin_tmp := ""
	if input_path == "-" {
		tmp, stdin_ok := resolve_stdin_path()
		if !stdin_ok {
			fmt.eprintln("error: failed to read from stdin")
			os.exit(1)
		}
		stdin_tmp = tmp
		input_path = tmp
	}
	defer if stdin_tmp != "" {
		os.remove(stdin_tmp)
		delete(stdin_tmp)
	}

	group_expression := args[1]
	if !strings.has_prefix(group_expression, "group=") ||
	   len(group_expression) == len("group=") {
		fmt.eprintln("error: expected group=<column>[,<column>...]")
		os.exit(1)
	}
	group_text := group_expression[len("group="):]
	group_columns := strings.split(group_text, ",", context.allocator)
	defer delete(group_columns, context.allocator)
	if len(group_columns) == 0 || len(group_columns) > query.MAX_GROUP_COLUMNS {
		fmt.eprintln("error: invalid group column list")
		os.exit(1)
	}
	for column_name in group_columns {
		if column_name == "" {
			fmt.eprintln("error: group columns cannot be empty")
			os.exit(1)
		}
	}
	if args[2] != "--" {
		fmt.eprintln("error: expected -- before aggregate expressions")
		os.exit(1)
	}

	log_opts: ingest.Log_Read_Options
	has_logformat := false
	for i := 3; i < len(args); i += 1 {
		switch args[i] {
		case "--logformat":
			if has_logformat || i+1 >= len(args) {
				fmt.eprintln("error: malformed or duplicate --logformat")
				os.exit(1)
			}
			switch args[i+1] {
			case "clf":      log_opts.format = .CLF
			case "combined": log_opts.format = .Combined
			case "logfmt":   log_opts.format = .Logfmt
			case "syslog":   log_opts.format = .Syslog
			case "app":      log_opts.format = .App
			case "regex":    log_opts.format = .Regex
			case:
				fmt.eprintfln("error: unsupported log format %q", args[i+1])
				os.exit(1)
			}
			log_opts.has_format = true
			has_logformat = true
			i += 1
		case "--logpattern":
			if i+1 >= len(args) {
				fmt.eprintln("error: --logpattern requires a value")
				os.exit(1)
			}
			log_opts.pattern = args[i+1]
			i += 1
		case "--strict":
			log_opts.strict = true
		}
	}

	table: snout_core.Table
	if has_logformat ||
	   strings.has_suffix(input_path, ".log") ||
	   strings.has_suffix(input_path, ".access") ||
	   strings.has_suffix(input_path, ".error") {
		table_name := "stdin"
		if stdin_tmp == "" {
			table_name = table_name_from_path(input_path, log_ext_suffix(input_path))
		}
		load_err: snout_core.Error
		table, load_err = ingest.read_log_table(input_path, table_name, log_opts)
		if load_err != .None {
			fmt.eprintfln("error: %s", snout_core.error_message(load_err))
			os.exit(1)
		}
	} else {
		table = load_table_or_exit(input_path)
	}
	defer snout_core.free_table(&table)

	cursor := 3
	aggregates := make([dynamic]query.Aggregate_Spec, 0, allocator = context.temp_allocator)
	for cursor < len(args) && !strings.has_prefix(args[cursor], "--") {
		expression := args[cursor]
		separator := strings.index_byte(expression, '=')
		if separator <= 0 || separator == len(expression)-1 {
			fmt.eprintfln("error: invalid aggregate expression %q", expression)
			os.exit(1)
		}
		aggregate_text := expression[:separator]
		column_name    := expression[separator+1:]
		spec_partial, aggregate_ok := query.parse_aggregate_spec_kind(aggregate_text)
		if !aggregate_ok {
			fmt.eprintfln("error: invalid aggregate %q", aggregate_text)
			os.exit(1)
		}
		if spec_partial.kind == .Count && column_name == "rows" {
			column_name = "*"
		}
		if column_name == "*" && spec_partial.kind != .Count {
			fmt.eprintfln("error: only count=rows accepts a row wildcard")
			os.exit(1)
		}
		append(&aggregates, query.Aggregate_Spec{
			kind        = spec_partial.kind,
			column_name = column_name,
			percentile  = spec_partial.percentile,
		})
		cursor += 1
	}
	if len(aggregates) == 0 || len(aggregates) > query.MAX_AGGREGATES {
		fmt.eprintln("error: at least one aggregate expression is required")
		os.exit(1)
	}

	predicates    := make([dynamic]query.Filter_Predicate, 0, allocator = context.temp_allocator)
	pending_sorts := make([dynamic]Pending_Sort, 0, allocator = context.temp_allocator)
	output_format := result_output.Output_Format.Table
	has_format    := false
	limit         := 0
	has_limit     := false
	for cursor < len(args) {
		switch args[cursor] {
		case "--where":
			if cursor+2 >= len(args) {
				fmt.eprintln("error: malformed --where arguments")
				os.exit(1)
			}
			column_name   := args[cursor+1]
			operator_text := args[cursor+2]
			operator, operator_ok := query.parse_filter_operator(operator_text)
			if !operator_ok {
				fmt.eprintfln("error: invalid filter operator %q", operator_text)
				os.exit(1)
			}
			cursor += 3
			literal := ""
			if operator != .Is_Null && operator != .Is_Not_Null {
				if cursor >= len(args) || strings.has_prefix(args[cursor], "--") {
					fmt.eprintfln("error: filter value required for column %q", column_name)
					os.exit(1)
				}
				literal = args[cursor]
				cursor += 1
			}
			predicate, predicate_err := query.make_filter_predicate(
				&table,
				column_name,
				operator,
				literal,
			)
			if predicate_err != .None {
				fmt.eprintfln(
					"error: %s for column %q and value %q",
					snout_core.error_message(predicate_err),
					column_name,
					literal,
				)
				os.exit(1)
			}
			append(&predicates, predicate)
		case "--sort":
			if cursor+2 >= len(args) {
				fmt.eprintln("error: malformed --sort arguments")
				os.exit(1)
			}
			direction, direction_ok := query.parse_sort_direction(args[cursor+2])
			if !direction_ok {
				fmt.eprintfln("error: invalid sort direction %q", args[cursor+2])
				os.exit(1)
			}
			append(&pending_sorts, Pending_Sort{
				target    = args[cursor+1],
				direction = direction,
			})
			if len(pending_sorts) > query.MAX_SORT_TERMS {
				fmt.eprintln("error: query contains too many sort terms")
				os.exit(1)
			}
			cursor += 3
		case "--limit":
			if has_limit || cursor+1 >= len(args) {
				fmt.eprintln("error: malformed or duplicate --limit")
				os.exit(1)
			}
			limit_err: snout_core.Error
			limit, limit_err = query.parse_result_limit(args[cursor+1])
			if limit_err != .None {
				fmt.eprintfln("error: %s %q", snout_core.error_message(limit_err), args[cursor+1])
				os.exit(1)
			}
			has_limit = true
			cursor += 2
		case "--format":
			if has_format || cursor+1 >= len(args) {
				fmt.eprintln("error: malformed or duplicate --format")
				os.exit(1)
			}
			format_ok: bool
			output_format, format_ok = result_output.parse_output_format(args[cursor+1])
			if !format_ok {
				fmt.eprintfln("error: invalid output format %q", args[cursor+1])
				os.exit(1)
			}
			has_format = true
			cursor += 2
		case "--logformat", "--logpattern":
			if cursor+1 >= len(args) {
				fmt.eprintfln("error: %s requires a value", args[cursor])
				os.exit(1)
			}
			cursor += 2
		case "--strict":
			cursor += 1
		case:
			fmt.eprintfln("error: unknown query option %q", args[cursor])
			os.exit(1)
		}
	}

	group_query := query.Group_Query{
		group_columns = group_columns,
		aggregates    = aggregates[:],
		filters       = predicates[:],
	}
	result, query_err := query.execute_group_query(&table, group_query)
	if query_err != .None {
		fmt.eprintfln("error: %s", snout_core.error_message(query_err))
		os.exit(1)
	}
	defer query.free_group_result_set(&result)

	sort_terms := make([]query.Sort_Term, len(pending_sorts), context.temp_allocator)
	for pending, index in pending_sorts {
		term, resolve_err := query.resolve_sort_target(&result, pending.target)
		if resolve_err != .None {
			fmt.eprintfln("error: sort target %q is not part of the result", pending.target)
			os.exit(1)
		}
		term.direction   = pending.direction
		sort_terms[index] = term
	}
	if sort_err := query.sort_group_results(&result, sort_terms); sort_err != .None {
		fmt.eprintfln("error: %s", snout_core.error_message(sort_err))
		os.exit(1)
	}

	shown_count := len(result.groups)
	if has_limit {
		shown_count = min(shown_count, limit)
	}
	stdout, writer_ok := io.to_writer(os.to_stream(os.stdout))
	if !writer_ok {
		fmt.eprintln("error: could not write output")
		os.exit(1)
	}
	render_err := result_output.write_group_results(
		stdout,
		&result,
		result.groups[:shown_count],
		output_format,
		has_limit,
	)
	if render_err != .None {
		fmt.eprintfln("error: %s", snout_core.error_message(render_err))
		os.exit(1)
	}
}
