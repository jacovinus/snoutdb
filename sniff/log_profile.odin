package sniff

import "core:strconv"
import "core:strings"
import "core:text/regex"
import ingest "../ingest"
import snout_core "../core"

// profile_log_file profiles a log file directly from the streaming scanner
// without constructing core.Table. The report is logically equivalent to
// read_log_table + profile_table but with bounded memory.
profile_log_file :: proc(
	path, table_name: string,
	opts: ingest.Log_Read_Options,
	config: Sniff_Config = DEFAULT_SNIFF_CONFIG,
	allocator := context.allocator,
) -> (Sniff_Report, snout_core.Error) {
	if err := validate_sniff_config(config); err != .None {
		return {}, err
	}

	schema, schema_err := ingest.inspect_log_file(path, table_name, opts, allocator)
	if schema_err != .None {
		return {}, schema_err
	}
	defer ingest.free_log_file_schema(&schema)

	column_count := len(schema.columns)
	report := Sniff_Report {
		version      = REPORT_VERSION,
		row_count    = schema.row_count,
		column_count = column_count,
		allocator    = allocator,
	}
	report_name, name_err := strings.clone(schema.table_name, allocator)
	if name_err != nil {
		return {}, .Out_Of_Memory
	}
	report.table_name = report_name

	profiles := make([]Column_Profile, column_count, allocator)
	scan_states := make([]Column_Scan_State, column_count, allocator)
	defer {
		for &state in scan_states {
			free_column_accumulator(&state)
		}
		delete(scan_states, allocator)
	}
	warnings := make([dynamic]string, 0, context.temp_allocator)
	global_entries := 0

	for &state in scan_states {
		init_column_accumulator(&state, allocator, owned_keys = true)
	}

	fail :: proc(
		report: ^Sniff_Report,
		profiles: ^[]Column_Profile,
		profile_count: int,
		warnings: ^[dynamic]string,
	) {
		for warning in warnings {
			delete(warning, report.allocator)
		}
		cleanup_profiles_on_error(profiles, profile_count, report.allocator)
		delete(report.table_name, report.allocator)
	}

	// For Regex format: pre-compile the pattern once.
	group_names: []string
	re: regex.Regular_Expression
	has_regex := false
	if schema.format == .Regex {
		names, modified, names_ok := ingest.parse_named_groups(opts.pattern, context.temp_allocator)
		if !names_ok || len(names) == 0 {
			fail(&report, &profiles, 0, &warnings)
			return {}, .Log_Parse_Error
		}
		group_names = names
		compiled, re_err := regex.create(modified, {}, allocator)
		if re_err != nil {
			fail(&report, &profiles, 0, &warnings)
			return {}, .Log_Parse_Error
		}
		re = compiled
		has_regex = true
		free_all(context.temp_allocator)
	}
	defer if has_regex {regex.destroy_regex(re, allocator)}

	scanner, open_err := ingest.open_jsonl_scanner(path, allocator = allocator)
	if open_err != .None {
		fail(&report, &profiles, 0, &warnings)
		return {}, open_err
	}
	defer ingest.close_jsonl_scanner(&scanner)

	row_index := 0
	for {
		line, done, line_err := ingest.next_jsonl_line(&scanner)
		if line_err != .None {
			fail(&report, &profiles, 0, &warnings)
			return {}, line_err
		}
		if done {
			break
		}
		if row_index >= schema.row_count {
			fail(&report, &profiles, 0, &warnings)
			return {}, .Input_Changed_During_Read
		}

		// Parse line according to format.
		fields: []ingest.Log_Field
		parse_ok: bool

		switch schema.format {
		case .CLF, .Combined:
			fields, parse_ok = ingest.parse_clf_tokens(line, context.temp_allocator)
		case .Syslog:
			fields, parse_ok = ingest.parse_syslog_line(line, context.temp_allocator)
		case .Logfmt:
			fields, parse_ok = ingest.parse_logfmt_line(line, context.temp_allocator)
		case .Regex:
			if has_regex {
				cap, matched := regex.match_and_allocate_capture(re, line, context.temp_allocator)
				if matched {
					fields_dyn := make([dynamic]ingest.Log_Field, 0, context.temp_allocator)
					for gname, gi in group_names {
						cap_idx := gi + 1
						is_null := cap_idx >= len(cap.groups) || cap.groups[cap_idx] == ""
						append(
							&fields_dyn,
							ingest.Log_Field{name = gname, value = cap.groups[cap_idx] if !is_null else "", null = is_null},
						)
					}
					fields = fields_dyn[:]
					parse_ok = true
				}
			}
		}

		if !parse_ok {
			// Non-strict: observe null for all columns.
			for &state in scan_states {
				observe_null(&state)
			}
			free_all(context.temp_allocator)
			row_index += 1
			continue
		}

		// Mark which columns were seen in this line.
		seen := make(map[string]bool, allocator = context.temp_allocator)
		for field in fields {
			col_idx, found := schema.column_indexes[field.name]
			if !found {
				continue
			}
			seen[field.name] = true
			state := &scan_states[col_idx]
			column_name := schema.columns[col_idx].name
			schema_kind := schema.columns[col_idx].kind

			if field.null {
				observe_null(state)
				continue
			}

			observe_err := snout_core.Error.None
			switch schema_kind {
			case .String:
				observe_err = observe_string(
					state,
					field.value,
					config,
					&global_entries,
					column_name,
					&warnings,
					allocator,
				)
			case .Timestamp:
				observe_err = observe_timestamp(
					state,
					field.value,
					config,
					&global_entries,
					column_name,
					&warnings,
					allocator,
				)
			case .Int64:
				parsed, ok := strconv.parse_i64(field.value)
				if !ok {
					observe_null(state)
				} else {
					observe_int64(state, parsed, config, &global_entries, column_name, &warnings, allocator)
				}
			case .Float64:
				parsed, ok := strconv.parse_f64(field.value)
				if !ok {
					observe_null(state)
				} else {
					observe_err = observe_float64(
						state,
						parsed,
						config,
						&global_entries,
						column_name,
						&warnings,
						allocator,
					)
				}
			case .Bool:
				switch field.value {
				case "true":
					observe_bool(state, true)
				case "false":
					observe_bool(state, false)
				case:
					observe_null(state)
				}
			case .Unknown:
				observe_unknown(state)
			}
			if observe_err != .None {
				fail(&report, &profiles, 0, &warnings)
				return {}, observe_err
			}
		}

		// Columns absent from this line are null.
		for &col, idx in schema.columns {
			if col.name not_in seen {
				observe_null(&scan_states[idx])
			}
		}

		free_all(context.temp_allocator)
		row_index += 1
	}

	if row_index != schema.row_count {
		fail(&report, &profiles, 0, &warnings)
		return {}, .Input_Changed_During_Read
	}

	for &state, index in scan_states {
		profile, finalize_err := finalize_column_profile(
			&state,
			schema.columns[index].name,
			schema.columns[index].kind,
			schema.row_count,
			index,
			allocator,
		)
		if finalize_err != .None {
			fail(&report, &profiles, index, &warnings)
			return {}, finalize_err
		}
		profiles[index] = profile
	}

	for &profile in profiles {
		classify_column_role(&profile)
		reason, reason_err := strings.clone(profile.role_reason, allocator)
		if reason_err != nil {
			fail(&report, &profiles, len(profiles), &warnings)
			return {}, .Out_Of_Memory
		}
		profile.role_reason = reason
	}

	for &profile, index in profiles {
		top_values, top_err := materialize_top_values(
			&scan_states[index],
			profile.role,
			profile.kind,
			config.top_value_count,
			allocator,
		)
		if top_err != .None {
			fail(&report, &profiles, len(profiles), &warnings)
			return {}, top_err
		}
		profile.top_values = top_values
	}

	suggestions, suggestion_warnings, suggest_err := build_suggestions(profiles[:], config, allocator)
	if suggest_err != .None {
		fail(&report, &profiles, len(profiles), &warnings)
		return {}, suggest_err
	}

	owned_warnings := make([dynamic]string, 0, allocator)
	for warning in warnings {
		append(&owned_warnings, warning)
	}
	for warning in suggestion_warnings {
		append(&owned_warnings, warning)
	}
	delete(suggestion_warnings)

	report.columns = profiles
	report.suggestions = suggestions
	report.warnings = owned_warnings[:]
	return report, .None
}
