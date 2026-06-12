package main

import "core:fmt"
import "core:io"
import "core:os"
import "core:strconv"
import "core:strings"
import snout_core "../../core"
import hunt "../../hunt"
import ingest "../../ingest"
import sniff "../../sniff"

// Exit codes for `snout hunt` (matches SPEC-0015 conventions):
//   0 — success (findings may be empty)
//   1 — invalid CLI usage / flag validation error
//   2 — input read error (file missing, malformed)
//   3 — parse error (log format mismatch, etc.)
//   4 — unsupported source kind
//   5 — internal error (sniff/engine failure)

HUNT_EXIT_USAGE        :: 1
HUNT_EXIT_INPUT        :: 2
HUNT_EXIT_PARSE        :: 3
HUNT_EXIT_UNSUPPORTED  :: 4
HUNT_EXIT_INTERNAL     :: 5

run_hunt_command :: proc(args: []string) {
	if len(args) < 2 {
		print_usage()
		os.exit(HUNT_EXIT_USAGE)
	}

	input_path := args[1]
	if input_path == "-" {
		fmt.eprintln("error: hunt does not yet support stdin; import to .snout first")
		os.exit(HUNT_EXIT_UNSUPPORTED)
	}

	config := hunt.DEFAULT_HUNT_CONFIG
	config.source_path = input_path
	config.source_kind = hunt.source_kind_from_path(input_path)

	output_format := hunt.Output_Format.Table
	output_path   := ""
	color_mode    := hunt.Color_Mode.Auto
	verbose       := false

	log_format_name := ""
	log_pattern     := ""
	log_strict      := false

	// Duplicate-flag detection.
	seen_limit, seen_min_score, seen_format := false, false, false
	seen_logformat, seen_logpattern         := false, false
	seen_verbose, seen_strict                := false, false
	seen_color                               := false
	seen_output                              := false

	cursor := 2
	for cursor < len(args) {
		option := args[cursor]
		switch option {
		case "--limit":
			if seen_limit { hunt_die_duplicate(option) }
			value, ok := consume_int_arg(args, &cursor, option)
			if !ok { os.exit(HUNT_EXIT_USAGE) }
			if value < 0 {
				fmt.eprintfln("error: --limit must be >= 0 (got %d)", value)
				os.exit(HUNT_EXIT_USAGE)
			}
			config.limit = value
			seen_limit = true
		case "--min-score":
			if seen_min_score { hunt_die_duplicate(option) }
			value, ok := consume_int_arg(args, &cursor, option)
			if !ok { os.exit(HUNT_EXIT_USAGE) }
			if value < 0 || value > 100 {
				fmt.eprintfln("error: --min-score must be 0..100 (got %d)", value)
				os.exit(HUNT_EXIT_USAGE)
			}
			config.min_score = value
			seen_min_score = true
		case "--format":
			if seen_format { hunt_die_duplicate(option) }
			value, ok := consume_string_arg(args, &cursor, option)
			if !ok { os.exit(HUNT_EXIT_USAGE) }
			switch value {
			case "table": output_format = .Table
			case "json":  output_format = .JSON
			case "jsonl": output_format = .JSONL
			case:
				fmt.eprintfln("error: --format must be table|json|jsonl (got %q)", value)
				os.exit(HUNT_EXIT_USAGE)
			}
			seen_format = true
		case "-o", "--output":
			if seen_output { hunt_die_duplicate(option) }
			value, ok := consume_string_arg(args, &cursor, option)
			if !ok { os.exit(HUNT_EXIT_USAGE) }
			if !strings.has_suffix(value, ".txt") && !strings.has_suffix(value, ".md") {
				fmt.eprintfln("error: output path must end in .txt or .md (got %q)", value)
				os.exit(HUNT_EXIT_USAGE)
			}
			output_path = value
			seen_output = true
		case "--logformat":
			if seen_logformat { hunt_die_duplicate(option) }
			value, ok := consume_string_arg(args, &cursor, option)
			if !ok { os.exit(HUNT_EXIT_USAGE) }
			if !is_valid_log_format(value) {
				fmt.eprintfln("error: --logformat must be clf|combined|logfmt|syslog|app|bracketed|regex (got %q)", value)
				os.exit(HUNT_EXIT_USAGE)
			}
			log_format_name = value
			seen_logformat = true
		case "--logpattern":
			if seen_logpattern { hunt_die_duplicate(option) }
			value, ok := consume_string_arg(args, &cursor, option)
			if !ok { os.exit(HUNT_EXIT_USAGE) }
			log_pattern = value
			seen_logpattern = true
		case "--strict":
			if seen_strict { hunt_die_duplicate(option) }
			log_strict = true
			cursor += 1
			seen_strict = true
		case "--verbose":
			if seen_verbose { hunt_die_duplicate(option) }
			verbose = true
			cursor += 1
			seen_verbose = true
		case "--color":
			if seen_color { hunt_die_duplicate(option) }
			value, ok := consume_string_arg(args, &cursor, option)
			if !ok { os.exit(HUNT_EXIT_USAGE) }
			switch value {
			case "auto":   color_mode = .Auto
			case "always": color_mode = .Always
			case "never":  color_mode = .Never
			case:
				fmt.eprintfln("error: --color must be auto|always|never (got %q)", value)
				os.exit(HUNT_EXIT_USAGE)
			}
			seen_color = true
		case:
			fmt.eprintfln("error: unknown hunt option %q", option)
			os.exit(HUNT_EXIT_USAGE)
		}
	}

	// Cross-flag validation: --logpattern only with --logformat regex.
	if log_pattern != "" && log_format_name != "regex" {
		fmt.eprintln("error: --logpattern requires --logformat regex")
		os.exit(HUNT_EXIT_USAGE)
	}
	if log_format_name == "regex" && log_pattern == "" {
		fmt.eprintln("error: --logformat regex requires --logpattern")
		os.exit(HUNT_EXIT_USAGE)
	}
	if seen_output && seen_format {
		fmt.eprintln("error: --format cannot be combined with -o/--output; the file extension selects txt or md")
		os.exit(HUNT_EXIT_USAGE)
	}
	// --logformat / --logpattern only make sense for log inputs.
	if (log_format_name != "" || log_pattern != "") && config.source_kind != .Log {
		fmt.eprintln("error: --logformat/--logpattern only apply to .log/.access/.error inputs")
		os.exit(HUNT_EXIT_USAGE)
	}
	if !hunt.validate_config(config) {
		fmt.eprintln("error: invalid hunt configuration")
		os.exit(HUNT_EXIT_USAGE)
	}

	config.log_format_name = log_format_name
	config.log_pattern     = log_pattern
	config.include_info_patterns = verbose

	log_opts := build_log_opts(log_format_name, log_pattern, log_strict)

	// Load + profile + run engine.
	table := load_hunt_table_or_exit(input_path, log_opts)
	defer snout_core.free_table(&table)

	report, profile_err := sniff.profile_table(&table, sniff.DEFAULT_SNIFF_CONFIG)
	if profile_err != .None {
		fmt.eprintfln("error: %s", snout_core.error_message(profile_err))
		os.exit(HUNT_EXIT_INTERNAL)
	}
	defer sniff.free_sniff_report(&report)

	hunt_report, hunt_err := hunt.run_engine(&report, &table, config)
	if hunt_err != .None {
		fmt.eprintfln("error: %s", snout_core.error_message(hunt_err))
		os.exit(HUNT_EXIT_INTERNAL)
	}
	defer hunt.free_hunt_report(&hunt_report)

	if output_path != "" {
		if strings.has_suffix(output_path, ".md") {
			output_format = .Markdown
		} else {
			output_format = .Table
		}
		builder := strings.builder_make()
		defer strings.builder_destroy(&builder)
		write_err := hunt.render_report(
			strings.to_writer(&builder),
			&hunt_report,
			output_format,
			.Never,
			verbose,
		)
		if write_err != .None {
			fmt.eprintfln("error: %s", snout_core.error_message(write_err))
			os.exit(HUNT_EXIT_INTERNAL)
		}
		content := strings.to_string(builder)
		if file_err := os.write_entire_file(output_path, transmute([]byte)content); file_err != nil {
			fmt.eprintfln("error: could not write report to %q", output_path)
			os.exit(HUNT_EXIT_INTERNAL)
		}
		fmt.printfln("Report written to %s", output_path)
		return
	}

	stdout, ok := io.to_writer(os.to_stream(os.stdout))
	if !ok {
		fmt.eprintln("error: could not write output")
		os.exit(HUNT_EXIT_INTERNAL)
	}
	write_err := hunt.render_report(stdout, &hunt_report, output_format, color_mode, verbose)
	if write_err != .None {
		fmt.eprintfln("error: %s", snout_core.error_message(write_err))
		os.exit(HUNT_EXIT_INTERNAL)
	}
}

// hunt_die_duplicate is the single duplicate-flag error path. Exits with the
// usage code so callers do not have to remember the constant.
@(private="file")
hunt_die_duplicate :: proc(flag: string) {
	fmt.eprintfln("error: %s specified more than once", flag)
	os.exit(HUNT_EXIT_USAGE)
}

@(private="file")
consume_int_arg :: proc(args: []string, cursor: ^int, flag: string) -> (int, bool) {
	if cursor^+1 >= len(args) {
		fmt.eprintfln("error: %s requires a value", flag)
		return 0, false
	}
	raw := args[cursor^+1]
	value, ok := strconv.parse_int(raw)
	if !ok {
		fmt.eprintfln("error: %s expects an integer (got %q)", flag, raw)
		return 0, false
	}
	cursor^ += 2
	return value, true
}

@(private="file")
consume_string_arg :: proc(args: []string, cursor: ^int, flag: string) -> (string, bool) {
	if cursor^+1 >= len(args) {
		fmt.eprintfln("error: %s requires a value", flag)
		return "", false
	}
	value := args[cursor^+1]
	cursor^ += 2
	return value, true
}

@(private="file")
is_valid_log_format :: proc(name: string) -> bool {
	switch name {
	case "clf", "combined", "logfmt", "syslog", "app", "bracketed", "regex":
		return true
	}
	return false
}

@(private="file")
build_log_opts :: proc(name, pattern: string, strict: bool) -> ingest.Log_Read_Options {
	opts: ingest.Log_Read_Options
	opts.strict = strict
	switch name {
	case "clf":       opts.format = .CLF
	case "combined":  opts.format = .Combined
	case "logfmt":    opts.format = .Logfmt
	case "syslog":    opts.format = .Syslog
	case "app":       opts.format = .App
	case "bracketed": opts.format = .Bracketed
	case "regex":     opts.format = .Regex
	case "":
		return opts
	}
	opts.has_format = true
	opts.pattern    = pattern
	return opts
}

// load_hunt_table_or_exit loads any supported input (CSV, JSONL, LOG, .snout)
// into an in-memory core.Table.
load_hunt_table_or_exit :: proc(input_path: string, log_opts: ingest.Log_Read_Options) -> snout_core.Table {
	if strings.has_suffix(input_path, ".csv") {
		return load_csv_or_exit(input_path)
	}
	if strings.has_suffix(input_path, ".jsonl") || strings.has_suffix(input_path, ".ndjson") {
		return load_jsonl_or_exit(input_path)
	}
	if strings.has_suffix(input_path, ".log") ||
	   strings.has_suffix(input_path, ".access") ||
	   strings.has_suffix(input_path, ".error") {
		suffix := log_ext_suffix(input_path)
		table_name := table_name_from_path(input_path, suffix)
		table, err := ingest.read_log_table(input_path, table_name, log_opts)
		if err != .None {
			fmt.eprintfln("error: %s", snout_core.error_message(err))
			if err == .Parse {
				os.exit(HUNT_EXIT_PARSE)
			}
			os.exit(HUNT_EXIT_INPUT)
		}
		return table
	}
	return load_snout_or_exit(input_path)
}
