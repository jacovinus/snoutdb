package main

import "core:fmt"
import "core:io"
import "core:os"
import "core:strings"
import snout_core "../../core"
import ingest "../../ingest"
import result_output "../../output"
import sniff "../../sniff"

run_sniff_command :: proc(args: []string) {
	if len(args) < 3 {
		print_usage()
		os.exit(1)
	}
	if args[1] != "-f" {
		fmt.eprintln("error: sniff requires -f <input>")
		os.exit(1)
	}
	input_path := args[2]
	stdin_tmp_sniff := ""
	if input_path == "-" {
		tmp, stdin_ok := resolve_stdin_path()
		if !stdin_ok {
			fmt.eprintln("error: failed to read from stdin")
			os.exit(1)
		}
		stdin_tmp_sniff = tmp
		input_path = tmp
	}
	defer if stdin_tmp_sniff != "" {
		os.remove(stdin_tmp_sniff)
		delete(stdin_tmp_sniff)
	}

	config        := sniff.DEFAULT_SNIFF_CONFIG
	output_format := result_output.Sniff_Output_Format.Table
	has_format       := false
	has_top          := false
	has_max_distinct := false
	has_suggestions  := false
	log_opts: ingest.Log_Read_Options
	has_logformat := false
	cursor := 3
	for cursor < len(args) {
		option := args[cursor]
		switch option {
		case "--format":
			if has_format || cursor+1 >= len(args) {
				fmt.eprintln("error: malformed or duplicate --format")
				os.exit(1)
			}
			format_ok: bool
			output_format, format_ok = result_output.parse_sniff_output_format(args[cursor+1])
			if !format_ok {
				fmt.eprintfln("error: unsupported sniff format %q", args[cursor+1])
				os.exit(1)
			}
			has_format = true
			cursor += 2
		case "--logformat":
			if has_logformat || cursor+1 >= len(args) {
				fmt.eprintln("error: malformed or duplicate --logformat")
				os.exit(1)
			}
			switch args[cursor+1] {
			case "clf":      log_opts.format = .CLF
			case "combined": log_opts.format = .Combined
			case "logfmt":   log_opts.format = .Logfmt
			case "syslog":   log_opts.format = .Syslog
			case "regex":    log_opts.format = .Regex
			case:
				fmt.eprintfln("error: unsupported log format %q", args[cursor+1])
				os.exit(1)
			}
			has_logformat = true
			log_opts.has_format = true
			cursor += 2
		case "--logpattern":
			if cursor+1 >= len(args) {
				fmt.eprintln("error: --logpattern requires a value")
				os.exit(1)
			}
			log_opts.pattern = args[cursor+1]
			cursor += 2
		case "--strict":
			log_opts.strict = true
			cursor += 1
		case "--top":
			if has_top || cursor+1 >= len(args) {
				fmt.eprintln("error: malformed or duplicate --top")
				os.exit(1)
			}
			value, value_err := sniff.parse_sniff_option_value(
				args[cursor+1],
				0,
				sniff.MAX_TOP_VALUE_COUNT,
			)
			if value_err != .None {
				fmt.eprintfln("error: invalid --top value %q", args[cursor+1])
				os.exit(1)
			}
			config.top_value_count = value
			has_top = true
			cursor += 2
		case "--max-distinct":
			if has_max_distinct || cursor+1 >= len(args) {
				fmt.eprintln("error: malformed or duplicate --max-distinct")
				os.exit(1)
			}
			value, value_err := sniff.parse_sniff_option_value(
				args[cursor+1],
				1,
				sniff.MAX_DISTINCT_VALUES,
			)
			if value_err != .None {
				if value_err == .Sniff_Limit_Too_Large {
					fmt.eprintln("error: --max-distinct exceeds 1000000")
				} else {
					fmt.eprintfln("error: invalid --max-distinct value %q", args[cursor+1])
				}
				os.exit(1)
			}
			config.max_distinct_values = value
			has_max_distinct = true
			cursor += 2
		case "--suggestions":
			if has_suggestions || cursor+1 >= len(args) {
				fmt.eprintln("error: malformed or duplicate --suggestions")
				os.exit(1)
			}
			value, value_err := sniff.parse_sniff_option_value(
				args[cursor+1],
				0,
				sniff.MAX_SUGGESTIONS,
			)
			if value_err != .None {
				fmt.eprintfln("error: invalid --suggestions value %q", args[cursor+1])
				os.exit(1)
			}
			config.max_suggestions = value
			has_suggestions = true
			cursor += 2
		case:
			fmt.eprintfln("error: unknown sniff option %q", option)
			os.exit(1)
		}
	}

	report: sniff.Sniff_Report
	profile_err: snout_core.Error
	if strings.has_suffix(input_path, ".csv") {
		table_name := table_name_from_path(input_path, ".csv")
		report, profile_err = sniff.profile_csv_file(input_path, table_name, config)
	} else if strings.has_suffix(input_path, ".jsonl") || strings.has_suffix(input_path, ".ndjson") {
		suffix := ".jsonl" if strings.has_suffix(input_path, ".jsonl") else ".ndjson"
		table_name := table_name_from_path(input_path, suffix)
		report, profile_err = sniff.profile_jsonl_file(input_path, table_name, config)
	} else if strings.has_suffix(input_path, ".log") ||
	          strings.has_suffix(input_path, ".access") ||
	          strings.has_suffix(input_path, ".error") {
		log_suffix    := log_ext_suffix(input_path)
		log_table_name := table_name_from_path(input_path, log_suffix)
		report, profile_err = sniff.profile_log_file(input_path, log_table_name, log_opts, config)
	} else {
		table := load_table_or_exit(input_path)
		defer snout_core.free_table(&table)
		report, profile_err = sniff.profile_table(&table, config)
	}
	if profile_err != .None {
		if profile_err == .Non_Finite_Profile_Value {
			fmt.eprintln("error: non-finite value found in column")
		} else {
			fmt.eprintfln("error: %s", snout_core.error_message(profile_err))
		}
		os.exit(1)
	}
	defer sniff.free_sniff_report(&report)

	stdout, writer_ok := io.to_writer(os.to_stream(os.stdout))
	if !writer_ok {
		fmt.eprintln("error: could not write output")
		os.exit(1)
	}
	write_err := result_output.write_sniff_report(
		stdout,
		&report,
		input_path,
		output_format,
	)
	if write_err != .None {
		fmt.eprintfln("error: %s", snout_core.error_message(write_err))
		os.exit(1)
	}
}
