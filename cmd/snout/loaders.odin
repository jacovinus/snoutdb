package main

import "core:fmt"
import "core:os"
import "core:strings"
import "core:time"
import snout_core "../../core"
import ingest "../../ingest"
import storage "../../storage"

load_table_or_exit :: proc(path: string) -> snout_core.Table {
	switch {
	case strings.has_suffix(path, ".snout"):
		return load_snout_or_exit(path)
	case strings.has_suffix(path, ".csv"):
		return load_csv_or_exit(path)
	case strings.has_suffix(path, ".jsonl"), strings.has_suffix(path, ".ndjson"):
		return load_jsonl_or_exit(path)
	}
	fmt.eprintfln("error: %s: %s", snout_core.error_message(.Unsupported_Input_Format), path)
	os.exit(1)
}

load_csv_or_exit :: proc(path: string) -> snout_core.Table {
	table_name := table_name_from_path(path, ".csv")
	table, err := ingest.read_csv_table(path, table_name)
	if err != .None {
		fmt.eprintfln("error: %s", snout_core.error_message(err))
		os.exit(1)
	}
	return table
}

load_jsonl_or_exit :: proc(path: string) -> snout_core.Table {
	table_name := table_name_from_path(path, ".jsonl")
	if table_name == path[strings.last_index_byte(path, '/')+1:] {
		table_name = strings.trim_suffix(table_name, ".ndjson")
	}
	table, detail := ingest.read_jsonl_table_detailed(path, table_name)
	if detail.code != .None {
		if detail.line > 0 {
			fmt.eprintfln(
				"error: %s at line %d",
				snout_core.error_message(detail.code),
				detail.line,
			)
		} else {
			fmt.eprintfln("error: %s", snout_core.error_message(detail.code))
		}
		os.exit(1)
	}
	return table
}

load_snout_or_exit :: proc(path: string) -> snout_core.Table {
	table, err := storage.read_snout_file(path)
	if err != .None {
		fmt.eprintfln("error: %s", snout_core.error_message(err))
		os.exit(1)
	}
	return table
}

// resolve_stdin_path buffers stdin to a temp file and returns its path with an
// inferred extension based on the first non-empty line.
// The caller is responsible for deleting the file when done.
resolve_stdin_path :: proc() -> (path: string, ok: bool) {
	buf := make([dynamic]u8, allocator = context.temp_allocator)
	chunk: [65536]u8
	for {
		n, errno := os.read(os.stdin, chunk[:])
		if n > 0 {
			append(&buf, ..chunk[:n])
		}
		if n == 0 || errno != os.ERROR_NONE {
			break
		}
	}

	ext     := ".csv"
	content := string(buf[:])
	for line in strings.split_lines_iterator(&content) {
		trimmed := strings.trim_space(line)
		if len(trimmed) == 0 {
			continue
		}
		if trimmed[0] == '{' {
			ext = ".jsonl"
		} else if ingest.is_combined_line(trimmed) ||
		          ingest.is_clf_line(trimmed) ||
		          ingest.is_syslog_line(trimmed) ||
		          ingest.is_app_log_line(trimmed) ||
		          ingest.is_logfmt_line(trimmed) {
			ext = ".log"
		}
		break
	}

	ns  := time.now()._nsec
	tmp := fmt.tprintf("/tmp/.snoutdb_stdin_%d%s", ns, ext)
	if write_err := os.write_entire_file(tmp, buf[:]); write_err != nil {
		return "", false
	}
	cloned, clone_err := strings.clone(tmp)
	if clone_err != nil {
		os.remove(tmp)
		return "", false
	}
	return cloned, true
}

table_name_from_path :: proc(path, suffix: string) -> string {
	start := strings.last_index_byte(path, '/') + 1
	name  := path[start:]
	return strings.trim_suffix(name, suffix)
}

log_ext_suffix :: proc(path: string) -> string {
	if strings.has_suffix(path, ".access") {
		return ".access"
	}
	if strings.has_suffix(path, ".error") {
		return ".error"
	}
	return ".log"
}

// parse_log_opts parses [--format clf|combined|logfmt|syslog|app|bracketed|regex] [--pattern "..."] [--strict]
// from a slice of remaining CLI args.
parse_log_opts :: proc(args: []string) -> ingest.Log_Read_Options {
	opts: ingest.Log_Read_Options
	i := 0
	for i < len(args) {
		switch args[i] {
		case "--format":
			if i+1 < len(args) {
				switch args[i+1] {
				case "clf":       opts.format = .CLF
				case "combined":  opts.format = .Combined
				case "logfmt":    opts.format = .Logfmt
				case "syslog":    opts.format = .Syslog
				case "app":       opts.format = .App
				case "bracketed": opts.format = .Bracketed
				case "regex":     opts.format = .Regex
				}
				opts.has_format = true
				i += 2
			} else {
				i += 1
			}
		case "--pattern":
			if i+1 < len(args) {
				opts.pattern = args[i+1]
				i += 2
			} else {
				i += 1
			}
		case "--strict":
			opts.strict = true
			i += 1
		case:
			i += 1
		}
	}
	return opts
}
