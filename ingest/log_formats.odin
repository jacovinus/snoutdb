package ingest

import "core:fmt"
import "core:strconv"
import "core:strings"
import snout_core "../core"

// Log_Field is a parsed name/value pair from one log line.
// null=true means the field is present but holds a null sentinel (e.g. "-" in CLF).
Log_Field :: struct {
	name:  string,
	value: string,
	null:  bool,
}

// Static schema templates — strings are literals, cloned before returning from the API.
@(private = "file")
CLF_SCHEMA_TEMPLATE := []Log_Column_Schema{
	{name = "remote_host", kind = .String,    nullable = false},
	{name = "ident",       kind = .String,    nullable = true},
	{name = "authuser",    kind = .String,    nullable = true},
	{name = "time",        kind = .Timestamp, nullable = false},
	{name = "method",      kind = .String,    nullable = false},
	{name = "path",        kind = .String,    nullable = false},
	{name = "protocol",    kind = .String,    nullable = false},
	{name = "status",      kind = .Int64,     nullable = false},
	{name = "bytes",       kind = .Int64,     nullable = true},
}

@(private = "file")
COMBINED_SCHEMA_TEMPLATE := []Log_Column_Schema{
	{name = "remote_host", kind = .String,    nullable = false},
	{name = "ident",       kind = .String,    nullable = true},
	{name = "authuser",    kind = .String,    nullable = true},
	{name = "time",        kind = .Timestamp, nullable = false},
	{name = "method",      kind = .String,    nullable = false},
	{name = "path",        kind = .String,    nullable = false},
	{name = "protocol",    kind = .String,    nullable = false},
	{name = "status",      kind = .Int64,     nullable = false},
	{name = "bytes",       kind = .Int64,     nullable = true},
	{name = "referer",     kind = .String,    nullable = true},
	{name = "user_agent",  kind = .String,    nullable = false},
}

@(private = "file")
SYSLOG_SCHEMA_TEMPLATE := []Log_Column_Schema{
	{name = "timestamp", kind = .Timestamp, nullable = false},
	{name = "hostname",  kind = .String,    nullable = false},
	{name = "app",       kind = .String,    nullable = false},
	{name = "pid",       kind = .Int64,     nullable = true},
	{name = "message",   kind = .String,    nullable = false},
}

@(private = "file")
APP_SCHEMA_TEMPLATE := []Log_Column_Schema{
	{name = "timestamp", kind = .Timestamp, nullable = false},
	{name = "level",     kind = .String,    nullable = false},
	{name = "message",   kind = .String,    nullable = false},
}

// Adobe UXP / IPC layout:
//   [2025-05-25_22-34-19][0x32acf3000][Default] [console] [fc-1] message body
// Three required leading brackets (timestamp, thread, level); everything after
// them — including any further [tag] segments — is captured as the message.
@(private = "file")
BRACKETED_SCHEMA_TEMPLATE := []Log_Column_Schema{
	{name = "timestamp", kind = .Timestamp, nullable = false},
	{name = "thread",    kind = .String,    nullable = false},
	{name = "level",     kind = .String,    nullable = false},
	{name = "message",   kind = .String,    nullable = false},
}

clf_schema_template :: proc() -> []Log_Column_Schema { return CLF_SCHEMA_TEMPLATE }
combined_schema_template :: proc() -> []Log_Column_Schema { return COMBINED_SCHEMA_TEMPLATE }
syslog_schema_template :: proc() -> []Log_Column_Schema { return SYSLOG_SCHEMA_TEMPLATE }
app_schema_template :: proc() -> []Log_Column_Schema { return APP_SCHEMA_TEMPLATE }
bracketed_schema_template :: proc() -> []Log_Column_Schema { return BRACKETED_SCHEMA_TEMPLATE }

// ---- Format detection -------------------------------------------------------

detect_log_format :: proc(
	path: string,
	allocator := context.allocator,
) -> (format: Log_Format, err: snout_core.Error) {
	scanner, scan_err := open_jsonl_scanner(path, allocator = allocator)
	if scan_err != .None {
		return .CLF, scan_err
	}
	defer close_jsonl_scanner(&scanner)

	clf_count := 0
	combined_count := 0
	syslog_count := 0
	app_count := 0
	bracketed_count := 0
	logfmt_count := 0
	total := 0

	for total < 20 {
		line, done, line_err := next_jsonl_line(&scanner)
		if line_err != .None {
			return .CLF, line_err
		}
		if done {
			break
		}
		total += 1

		// Order matters: bracketed must be checked before app because both
		// start with similar-looking bracketed timestamps but bracketed is
		// stricter (three leading bracket groups, underscore separator).
		if is_combined_line(line) {
			combined_count += 1
		} else if is_clf_line(line) {
			clf_count += 1
		} else if is_bracketed_log_line(line) {
			bracketed_count += 1
		} else if is_syslog_line(line) {
			syslog_count += 1
		} else if is_app_log_line(line) {
			app_count += 1
		} else if is_logfmt_line(line) {
			logfmt_count += 1
		}
	}

	if total == 0 {
		return .CLF, .Empty_Input
	}

	threshold := (total * 8 + 9) / 10 // ceiling of 80%

	if combined_count >= threshold {
		return .Combined, .None
	}
	if clf_count + combined_count >= threshold {
		return .CLF, .None
	}
	if bracketed_count >= threshold {
		return .Bracketed, .None
	}
	if syslog_count >= threshold {
		return .Syslog, .None
	}
	if app_count >= threshold {
		return .App, .None
	}
	if logfmt_count >= threshold {
		return .Logfmt, .None
	}
	return .CLF, .Unknown_Log_Format
}

is_clf_line :: proc(line: string) -> bool {
	bracket_open := strings.index_byte(line, '[')
	if bracket_open < 0 {
		return false
	}
	bracket_close := strings.index_byte(line, ']')
	if bracket_close <= bracket_open {
		return false
	}
	if strings.index_byte(line[bracket_close:], '"') < 0 {
		return false
	}
	prefix := strings.trim_space(line[:bracket_open])
	tok_count := 0
	rest := prefix
	for {
		tok, remaining, ok := scan_log_token(rest)
		_ = tok
		if !ok {
			break
		}
		tok_count += 1
		rest = strings.trim_left(remaining, " \t")
	}
	return tok_count >= 3
}

is_combined_line :: proc(line: string) -> bool {
	if !is_clf_line(line) {
		return false
	}
	count := 0
	in_quote := false
	for i := 0; i < len(line); i += 1 {
		ch := line[i]
		if ch == '\\' && in_quote {
			i += 1
			continue
		}
		if ch == '"' {
			if !in_quote {
				in_quote = true
			} else {
				in_quote = false
				count += 1
			}
		}
	}
	return count >= 3
}

is_syslog_line :: proc(line: string) -> bool {
	s := syslog_strip_pri(line)
	if len(s) < 15 {
		return false
	}
	_, ok := month_abbrev_to_num(s[0:3])
	return ok && s[3] == ' '
}

// syslog_strip_pri removes an optional RFC 3164 PRI prefix like "<134>" from the line.
syslog_strip_pri :: proc(line: string) -> string {
	if len(line) > 2 && line[0] == '<' {
		end := 1
		for end < len(line) && line[end] != '>' {
			end += 1
		}
		if end < len(line) {
			return line[end + 1:]
		}
	}
	return line
}

is_logfmt_line :: proc(line: string) -> bool {
	eq_pos := strings.index_byte(line, '=')
	if eq_pos <= 0 {
		return false
	}
	key := line[0:eq_pos]
	for ch in key {
		valid :=
			(ch >= 'a' && ch <= 'z') ||
			(ch >= 'A' && ch <= 'Z') ||
			(ch >= '0' && ch <= '9') ||
			ch == '_' ||
			ch == '-' ||
			ch == '.'
		if !valid {
			return false
		}
	}
	return true
}

// is_app_log_line recognizes common application logs:
// YYYY-MM-DD HH:MM:SS [level] message
is_app_log_line :: proc(line: string) -> bool {
	_, ok := parse_app_log_line(line, context.temp_allocator)
	return ok
}

// is_bracketed_log_line recognizes Adobe UXP / IPC style logs:
//   [YYYY-MM-DD_HH-MM-SS][thread][level] message
is_bracketed_log_line :: proc(line: string) -> bool {
	_, ok := parse_bracketed_log_line(line, context.temp_allocator)
	return ok
}

// ---- CLF / Combined parsers -------------------------------------------------

// parse_clf_tokens parses one CLF or Combined log line.
// Returns 9 fields for CLF or 11 for Combined (if the extra quote pair is present).
// All returned strings are slices into line or into alloc-allocated buffers.
parse_clf_tokens :: proc(
	line: string,
	alloc := context.temp_allocator,
) -> (fields: []Log_Field, ok: bool) {
	result := make([dynamic]Log_Field, 0, alloc)

	rest := strings.trim_left(line, " \t")

	// remote_host
	host, rem, found := scan_log_token(rest)
	if !found {
		return nil, false
	}
	append(&result, Log_Field{name = "remote_host", value = host})
	rest = strings.trim_left(rem, " \t")

	// ident (nullable)
	ident_s, rem2, found2 := scan_log_token(rest)
	if !found2 {
		return nil, false
	}
	append(&result, Log_Field{name = "ident", value = ident_s, null = ident_s == "-"})
	rest = strings.trim_left(rem2, " \t")

	// authuser (nullable)
	auth_s, rem3, found3 := scan_log_token(rest)
	if !found3 {
		return nil, false
	}
	append(&result, Log_Field{name = "authuser", value = auth_s, null = auth_s == "-"})
	rest = strings.trim_left(rem3, " \t")

	// time: [DD/Mon/YYYY:HH:MM:SS ±HHMM]
	if len(rest) == 0 || rest[0] != '[' {
		return nil, false
	}
	bracket_end := strings.index_byte(rest, ']')
	if bracket_end < 0 {
		return nil, false
	}
	time_raw := rest[1:bracket_end]
	time_iso, time_ok := clf_time_to_iso8601(time_raw, alloc)
	if !time_ok {
		return nil, false
	}
	append(&result, Log_Field{name = "time", value = time_iso})
	rest = strings.trim_left(rest[bracket_end + 1:], " \t")

	// request: "METHOD PATH PROTOCOL"
	if len(rest) == 0 || rest[0] != '"' {
		return nil, false
	}
	request_s, rest_req, req_ok := scan_log_quoted(rest)
	if !req_ok {
		return nil, false
	}
	parts := strings.split(request_s, " ", alloc)
	if len(parts) < 3 {
		return nil, false
	}
	append(&result, Log_Field{name = "method", value = parts[0]})
	append(&result, Log_Field{name = "path", value = parts[1]})
	append(&result, Log_Field{name = "protocol", value = parts[2]})
	rest = strings.trim_left(rest_req, " \t")

	// status
	status_s, rem4, found4 := scan_log_token(rest)
	if !found4 {
		return nil, false
	}
	append(&result, Log_Field{name = "status", value = status_s})
	rest = strings.trim_left(rem4, " \t")

	// bytes (nullable)
	bytes_s, rem5, _ := scan_log_token(rest)
	append(&result, Log_Field{name = "bytes", value = bytes_s, null = bytes_s == "-" || bytes_s == ""})
	rest = strings.trim_left(rem5, " \t")

	// Combined extra: referer + user_agent
	if len(rest) > 0 && rest[0] == '"' {
		referer_s, rest_ref, ref_ok := scan_log_quoted(rest)
		if !ref_ok {
			return result[:], true // treat as CLF only
		}
		append(&result, Log_Field{name = "referer", value = referer_s, null = referer_s == "-"})
		rest = strings.trim_left(rest_ref, " \t")

		if len(rest) > 0 && rest[0] == '"' {
			ua_s, _, ua_ok := scan_log_quoted(rest)
			if ua_ok {
				append(&result, Log_Field{name = "user_agent", value = ua_s})
			}
		}
	}

	return result[:], true
}

// ---- Syslog parser ----------------------------------------------------------

parse_syslog_line :: proc(
	line: string,
	alloc := context.temp_allocator,
) -> (fields: []Log_Field, ok: bool) {
	// Strip optional RFC 3164 PRI prefix: <NNN>
	s := syslog_strip_pri(line)

	if len(s) < 15 {
		return nil, false
	}

	month_num, month_ok := month_abbrev_to_num(s[0:3])
	if !month_ok || s[3] != ' ' {
		return nil, false
	}

	// Day: "DD" or " D" (single digit padded with space)
	day_str := strings.trim_left(s[4:6], " ")
	day_num, day_ok := strconv.parse_int(day_str)
	if !day_ok {
		return nil, false
	}
	if len(s) < 15 || s[6] != ' ' {
		return nil, false
	}

	// Time: HH:MM:SS
	time_s := s[7:15]
	if time_s[2] != ':' || time_s[5] != ':' {
		return nil, false
	}

	ts_buf: [24]u8
	ts_raw := fmt.bprintf(ts_buf[:], "0000-%02d-%02dT%s", month_num, day_num, time_s)
	ts := strings.clone(ts_raw, alloc)

	result := make([dynamic]Log_Field, 0, alloc)
	append(&result, Log_Field{name = "timestamp", value = ts})

	rest := strings.trim_left(s[15:], " \t")

	// hostname
	host, rem, found := scan_log_token(rest)
	if !found {
		return nil, false
	}
	append(&result, Log_Field{name = "hostname", value = host})
	rest = strings.trim_left(rem, " \t")

	// app[pid]: or app:
	colon_pos := strings.index_byte(rest, ':')
	if colon_pos < 0 {
		return nil, false
	}
	app_pid_s := rest[:colon_pos]
	rest = rest[colon_pos + 1:]
	if len(rest) > 0 && rest[0] == ' ' {
		rest = rest[1:]
	}

	bracket_open := strings.index_byte(app_pid_s, '[')
	if bracket_open >= 0 {
		bracket_close := strings.index_byte(app_pid_s, ']')
		app_name := app_pid_s[:bracket_open]
		pid_s := ""
		if bracket_close > bracket_open {
			pid_s = app_pid_s[bracket_open + 1:bracket_close]
		}
		append(&result, Log_Field{name = "app", value = app_name})
		append(&result, Log_Field{name = "pid", value = pid_s, null = pid_s == ""})
	} else {
		append(&result, Log_Field{name = "app", value = app_pid_s})
		append(&result, Log_Field{name = "pid", null = true})
	}

	append(&result, Log_Field{name = "message", value = rest})
	return result[:], true
}

// ---- Application log parser ------------------------------------------------

parse_app_log_line :: proc(
	line: string,
	alloc := context.temp_allocator,
) -> (fields: []Log_Field, ok: bool) {
	if len(line) < 23 {
		return nil, false
	}

	if line[4] != '-' || line[7] != '-' ||
	   line[13] != ':' || line[16] != ':' {
		return nil, false
	}
	if !is_ascii_digits(line[0:4]) || !is_ascii_digits(line[5:7]) ||
	   !is_ascii_digits(line[8:10]) || !is_ascii_digits(line[11:13]) ||
	   !is_ascii_digits(line[14:16]) || !is_ascii_digits(line[17:19]) {
		return nil, false
	}

	bracket_start := 20
	has_utc_suffix := false
	if line[10] == ' ' {
		if line[19] != ' ' || line[20] != '[' {
			return nil, false
		}
	} else if line[10] == 'T' {
		if len(line) < 24 || line[19] != 'Z' || line[20] != ' ' || line[21] != '[' {
			return nil, false
		}
		bracket_start = 21
		has_utc_suffix = true
	} else {
		return nil, false
	}

	month, month_ok := strconv.parse_int(line[5:7])
	day, day_ok := strconv.parse_int(line[8:10])
	hour, hour_ok := strconv.parse_int(line[11:13])
	minute, minute_ok := strconv.parse_int(line[14:16])
	second, second_ok := strconv.parse_int(line[17:19])
	if !month_ok || !day_ok || !hour_ok || !minute_ok || !second_ok ||
	   month < 1 || month > 12 || day < 1 || day > 31 ||
	   hour < 0 || hour > 23 || minute < 0 || minute > 59 ||
	   second < 0 || second > 59 {
		return nil, false
	}

	level_start := bracket_start + 1
	level_end_relative := strings.index_byte(line[level_start:], ']')
	if level_end_relative <= 0 {
		return nil, false
	}
	level_end := level_start + level_end_relative
	level := line[level_start:level_end]
	for ch in level {
		valid :=
			(ch >= 'a' && ch <= 'z') ||
			(ch >= 'A' && ch <= 'Z') ||
			(ch >= '0' && ch <= '9') ||
			ch == '_' ||
			ch == '-'
		if !valid {
			return nil, false
		}
	}

	ts_buf: [21]u8
	timestamp := line[0:20]
	if !has_utc_suffix {
		timestamp = fmt.bprintf(ts_buf[:], "%sT%s", line[0:10], line[11:19])
	}
	ts, clone_err := strings.clone(timestamp, alloc)
	if clone_err != nil {
		return nil, false
	}

	message := strings.trim_left(line[level_end + 1:], " \t")
	result := make([dynamic]Log_Field, 0, alloc)
	append(&result, Log_Field{name = "timestamp", value = ts})
	append(&result, Log_Field{name = "level", value = level})
	append(&result, Log_Field{name = "message", value = message})
	return result[:], true
}

// ---- Bracketed parser (Adobe UXP / IPC) ------------------------------------

// parse_bracketed_log_line accepts lines of the form
//   [YYYY-MM-DD_HH-MM-SS][thread][level] [extra] [...] message body
// Returns four fields: timestamp (ISO-8601), thread (raw), level (raw),
// message (everything after the third closing bracket, trimmed).
parse_bracketed_log_line :: proc(
	line: string,
	alloc := context.temp_allocator,
) -> (fields: []Log_Field, ok: bool) {
	// Minimum length: "[2025-05-25_22-34-19][a][b]" = 26 chars.
	if len(line) < 26 || line[0] != '[' { return nil, false }

	// First bracket = timestamp.
	end1 := strings.index_byte(line, ']')
	if end1 <= 0 { return nil, false }
	ts_raw := line[1:end1]
	ts_iso, ts_ok := bracketed_ts_to_iso(ts_raw, alloc)
	if !ts_ok { return nil, false }

	rest := line[end1 + 1:]
	if len(rest) == 0 || rest[0] != '[' { return nil, false }

	// Second bracket = thread / process id.
	end2 := strings.index_byte(rest, ']')
	if end2 <= 0 { return nil, false }
	thread := rest[1:end2]
	if len(thread) == 0 { return nil, false }
	rest = rest[end2 + 1:]
	if len(rest) == 0 || rest[0] != '[' { return nil, false }

	// Third bracket = severity / category label.
	end3 := strings.index_byte(rest, ']')
	if end3 <= 0 { return nil, false }
	level := rest[1:end3]
	if len(level) == 0 { return nil, false }
	for r in level {
		ascii_alpha :=
			(r >= 'a' && r <= 'z') || (r >= 'A' && r <= 'Z') ||
			(r >= '0' && r <= '9') || r == '_' || r == '-' || r == ' '
		if !ascii_alpha { return nil, false }
	}

	// Whatever follows is the message body. Strip leading whitespace.
	message := strings.trim_left(rest[end3 + 1:], " \t")

	result := make([dynamic]Log_Field, 0, alloc)
	append(&result, Log_Field{name = "timestamp", value = ts_iso})
	append(&result, Log_Field{name = "thread",    value = thread})
	append(&result, Log_Field{name = "level",     value = level})
	append(&result, Log_Field{name = "message",   value = message})
	return result[:], true
}

// bracketed_ts_to_iso converts "YYYY-MM-DD_HH-MM-SS" → "YYYY-MM-DDTHH:MM:SSZ".
@(private = "file")
bracketed_ts_to_iso :: proc(s: string, alloc := context.temp_allocator) -> (string, bool) {
	if len(s) != 19 { return "", false }
	if s[4]  != '-' || s[7]  != '-' || s[10] != '_' ||
	   s[13] != '-' || s[16] != '-' { return "", false }
	if !is_ascii_digits(s[0:4])  || !is_ascii_digits(s[5:7])  ||
	   !is_ascii_digits(s[8:10]) || !is_ascii_digits(s[11:13]) ||
	   !is_ascii_digits(s[14:16]) || !is_ascii_digits(s[17:19]) {
		return "", false
	}
	out := fmt.aprintf("%s-%s-%sT%s:%s:%sZ",
		s[0:4], s[5:7], s[8:10], s[11:13], s[14:16], s[17:19],
		allocator = alloc)
	return out, true
}

// ---- Logfmt parser ----------------------------------------------------------

parse_logfmt_line :: proc(
	line: string,
	alloc := context.temp_allocator,
) -> (fields: []Log_Field, ok: bool) {
	result := make([dynamic]Log_Field, 0, alloc)

	rest := line
	for {
		rest = strings.trim_left(rest, " \t")
		if rest == "" {
			break
		}

		eq_pos := strings.index_byte(rest, '=')
		if eq_pos <= 0 {
			break
		}
		key := rest[:eq_pos]
		rest = rest[eq_pos + 1:]

		value := ""
		is_null := false
		if rest == "" {
			is_null = true
		} else if rest[0] == '"' {
			quoted, remaining, q_ok := scan_log_quoted(rest)
			if !q_ok {
				return nil, false
			}
			value = quoted
			rest = remaining
		} else {
			end := 0
			for end < len(rest) && rest[end] != ' ' && rest[end] != '\t' {
				end += 1
			}
			value = rest[:end]
			rest = rest[end:]
		}

		append(&result, Log_Field{name = key, value = value, null = is_null})
	}

	if len(result) == 0 {
		return nil, false
	}
	return result[:], true
}

// ---- Type inference for dynamic formats (Logfmt, Regex) --------------------

// logfmt_infer_type infers the column type for a key=value pair.
logfmt_infer_type :: proc(key, value: string) -> snout_core.Column_Type {
	if key == "ts" || key == "time" || key == "timestamp" {
		if len(value) >= 10 && value[4] == '-' && value[7] == '-' {
			return .Timestamp
		}
	}
	if value == "true" || value == "false" {
		return .Bool
	}
	_, int_ok := strconv.parse_i64(value)
	if int_ok {
		return .Int64
	}
	_, float_ok := strconv.parse_f64(value)
	if float_ok {
		return .Float64
	}
	return .String
}

// promote_log_type promotes a column type when a new incompatible observation arrives.
promote_log_type :: proc(
	existing: snout_core.Column_Type,
	incoming: snout_core.Column_Type,
) -> snout_core.Column_Type {
	if existing == incoming {
		return existing
	}
	if existing == .Unknown {
		return incoming
	}
	if incoming == .Unknown {
		return existing
	}
	if (existing == .Int64 && incoming == .Float64) ||
	   (existing == .Float64 && incoming == .Int64) {
		return .Float64
	}
	return .String
}

// ---- Named group extraction for Regex format --------------------------------

// parse_named_groups extracts names from (?P<name>...) groups in order
// and returns the modified pattern with plain capture groups.
parse_named_groups :: proc(
	pattern: string,
	alloc := context.temp_allocator,
) -> (names: []string, modified: string, ok: bool) {
	names_dyn := make([dynamic]string, 0, alloc)
	builder := strings.builder_make(alloc)

	i := 0
	for i < len(pattern) {
		if i + 4 < len(pattern) && pattern[i:i + 4] == "(?P<" {
			gt_pos := strings.index_byte(pattern[i + 4:], '>')
			if gt_pos < 0 {
				return nil, "", false
			}
			name := pattern[i + 4:i + 4 + gt_pos]
			append(&names_dyn, name)
			strings.write_string(&builder, "(")
			i = i + 4 + gt_pos + 1
		} else {
			strings.write_byte(&builder, pattern[i])
			i += 1
		}
	}

	return names_dyn[:], strings.to_string(builder), true
}

// ---- Shared string utilities ------------------------------------------------

// scan_log_token returns the next whitespace-delimited token.
scan_log_token :: proc(s: string) -> (token: string, rest: string, ok: bool) {
	if s == "" {
		return "", "", false
	}
	end := 0
	for end < len(s) && s[end] != ' ' && s[end] != '\t' {
		end += 1
	}
	if end == 0 {
		return "", "", false
	}
	return s[:end], s[end:], true
}

is_ascii_digits :: proc(s: string) -> bool {
	if s == "" {
		return false
	}
	for ch in s {
		if ch < '0' || ch > '9' {
			return false
		}
	}
	return true
}

// scan_log_quoted parses a double-quoted string at s[0]=='"'.
// Returns unquoted content and remaining string after the closing '"'.
scan_log_quoted :: proc(s: string) -> (content: string, rest: string, ok: bool) {
	if len(s) == 0 || s[0] != '"' {
		return "", "", false
	}
	i := 1
	for i < len(s) {
		if s[i] == '\\' && i + 1 < len(s) {
			i += 2
			continue
		}
		if s[i] == '"' {
			rest_s := ""
			if i + 1 < len(s) {
				rest_s = s[i + 1:]
			}
			return s[1:i], rest_s, true
		}
		i += 1
	}
	return "", "", false
}

// clf_time_to_iso8601 converts a CLF timestamp to ISO-8601 UTC.
// Input: "10/Oct/2000:13:55:36 -0700" or "10/Oct/2000:13:55:36"
// Output: "2000-10-10T06:55:36Z"
clf_time_to_iso8601 :: proc(
	s: string,
	alloc := context.temp_allocator,
) -> (result: string, ok: bool) {
	if len(s) < 20 {
		return "", false
	}
	if s[2] != '/' || s[6] != '/' || s[11] != ':' || s[14] != ':' || s[17] != ':' {
		return "", false
	}

	day, day_ok := strconv.parse_int(s[0:2])
	month, month_ok := month_abbrev_to_num(s[3:6])
	year, year_ok := strconv.parse_int(s[7:11])
	hour, hour_ok := strconv.parse_int(s[12:14])
	min_, min_ok := strconv.parse_int(s[15:17])
	sec, sec_ok := strconv.parse_int(s[18:20])
	if !day_ok || !month_ok || !year_ok || !hour_ok || !min_ok || !sec_ok {
		return "", false
	}

	// Apply timezone offset when present: "10/Oct/2000:13:55:36 -0700"
	if len(s) >= 26 && s[20] == ' ' && (s[21] == '+' || s[21] == '-') {
		tz_h, tz_h_ok := strconv.parse_int(s[22:24])
		tz_m, tz_m_ok := strconv.parse_int(s[24:26])
		if tz_h_ok && tz_m_ok {
			total_min := hour * 60 + min_
			offset := tz_h * 60 + tz_m
			if s[21] == '+' {
				total_min -= offset
			} else {
				total_min += offset
			}
			if total_min < 0 {
				total_min += 24 * 60
				day -= 1
				if day <= 0 {
					day = 1
				}
			} else if total_min >= 24 * 60 {
				total_min -= 24 * 60
				day += 1
				if day > 31 {
					day = 31
				}
			}
			hour = total_min / 60
			min_ = total_min % 60
		}
	}

	buf: [25]u8
	formatted := fmt.bprintf(buf[:], "%04d-%02d-%02dT%02d:%02d:%02dZ", year, month, day, hour, min_, sec)
	cloned, clone_err := strings.clone(formatted, alloc)
	if clone_err != nil {
		return "", false
	}
	return cloned, true
}

// month_abbrev_to_num converts a 3-letter month abbreviation to 1-12.
month_abbrev_to_num :: proc(m: string) -> (int, bool) {
	switch m {
	case "Jan":
		return 1, true
	case "Feb":
		return 2, true
	case "Mar":
		return 3, true
	case "Apr":
		return 4, true
	case "May":
		return 5, true
	case "Jun":
		return 6, true
	case "Jul":
		return 7, true
	case "Aug":
		return 8, true
	case "Sep":
		return 9, true
	case "Oct":
		return 10, true
	case "Nov":
		return 11, true
	case "Dec":
		return 12, true
	}
	return 0, false
}
