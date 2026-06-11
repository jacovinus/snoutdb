package sniff

import "core:strconv"
import "core:strings"
import ingest "../ingest"
import snout_core "../core"

// profile_csv_file profiles a CSV file directly from the streaming scanner
// without constructing core.Table. The report is logically equivalent to
// read_csv_table + profile_table. Peak memory is bounded by the sniff
// configuration and scanner buffers, not by row count.
profile_csv_file :: proc(
	path, table_name: string,
	config: Sniff_Config = DEFAULT_SNIFF_CONFIG,
	allocator := context.allocator,
) -> (Sniff_Report, snout_core.Error) {
	if err := validate_sniff_config(config); err != .None {
		return {}, err
	}

	schema, schema_err := ingest.inspect_csv_file(path, table_name, allocator = allocator)
	if schema_err != .None {
		return {}, schema_err
	}
	defer ingest.free_csv_file_schema(&schema)

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

	scanner, open_err := ingest.open_csv_scanner(path, allocator = allocator)
	if open_err != .None {
		fail(&report, &profiles, 0, &warnings)
		return {}, open_err
	}
	defer ingest.close_csv_scanner(&scanner)

	header, header_done, header_err := ingest.next_csv_record(&scanner)
	if header_err != .None {
		fail(&report, &profiles, 0, &warnings)
		return {}, header_err
	}
	if header_done || len(header.fields) != column_count {
		fail(&report, &profiles, 0, &warnings)
		return {}, .Input_Changed_During_Read
	}
	for field, index in header.fields {
		if field != schema.columns[index].name {
			fail(&report, &profiles, 0, &warnings)
			return {}, .Input_Changed_During_Read
		}
	}

	row_index := 0
	for {
		record, done, record_err := ingest.next_csv_record(&scanner)
		if record_err != .None {
			fail(&report, &profiles, 0, &warnings)
			return {}, record_err
		}
		if done {
			break
		}
		if row_index >= schema.row_count || len(record.fields) != column_count {
			fail(&report, &profiles, 0, &warnings)
			return {}, .Input_Changed_During_Read
		}
		for field, index in record.fields {
			state := &scan_states[index]
			if field == "" {
				observe_null(state)
				continue
			}
			observe_err := snout_core.Error.None
			column_name := schema.columns[index].name
			switch schema.columns[index].kind {
			case .String:
				observe_err = observe_string(
					state,
					field,
					config,
					&global_entries,
					column_name,
					&warnings,
					allocator,
				)
			case .Timestamp:
				observe_err = observe_timestamp(
					state,
					field,
					config,
					&global_entries,
					column_name,
					&warnings,
					allocator,
				)
			case .Int64:
				parsed, ok := strconv.parse_i64(field)
				if !ok {
					observe_err = .Input_Changed_During_Read
				} else {
					observe_int64(
						state,
						parsed,
						config,
						&global_entries,
						column_name,
						&warnings,
						allocator,
					)
				}
			case .Float64:
				parsed, ok := strconv.parse_f64(field)
				if !ok {
					observe_err = .Input_Changed_During_Read
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
				switch field {
				case "true":
					observe_bool(state, true)
				case "false":
					observe_bool(state, false)
				case:
					observe_err = .Input_Changed_During_Read
				}
			case .Unknown:
				observe_err = .Invalid_Sniff_Config
			}
			if observe_err != .None {
				fail(&report, &profiles, 0, &warnings)
				return {}, observe_err
			}
		}
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

	suggestions, suggestion_warnings, suggest_err := build_suggestions(
		profiles[:],
		config,
		allocator,
	)
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
