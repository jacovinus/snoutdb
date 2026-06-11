package sniff

import "core:mem"
import "core:strings"
import ingest "../ingest"
import snout_core "../core"

// profile_jsonl_file profiles a JSONL file directly from the streaming scanner
// without constructing core.Table. The report is logically equivalent to
// read_jsonl_table + profile_table. Peak memory is bounded by the sniff
// configuration and scanner buffers, not by row count.
profile_jsonl_file :: proc(
	path, table_name: string,
	config: Sniff_Config = DEFAULT_SNIFF_CONFIG,
	allocator := context.allocator,
) -> (Sniff_Report, snout_core.Error) {
	if err := validate_sniff_config(config); err != .None {
		return {}, err
	}

	schema, schema_err := ingest.inspect_jsonl_file(path, table_name, allocator = allocator)
	if schema_err != .None {
		return {}, schema_err
	}
	defer ingest.free_jsonl_file_schema(&schema)

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

	scanner, open_err := ingest.open_jsonl_scanner(path, allocator = allocator)
	if open_err != .None {
		fail(&report, &profiles, 0, &warnings)
		return {}, open_err
	}
	defer ingest.close_jsonl_scanner(&scanner)

	// Per-record arena: reused for each parsed line, reset after observation.
	record_arena: mem.Dynamic_Arena
	mem.dynamic_arena_init(&record_arena, allocator, allocator, alignment = 64)
	defer mem.dynamic_arena_destroy(&record_arena)
	record_alloc := mem.dynamic_arena_allocator(&record_arena)

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

		record, parse_err := ingest.parse_json_object_line(line, record_alloc)
		if parse_err != .None {
			fail(&report, &profiles, 0, &warnings)
			return {}, parse_err
		}

		// Track which columns appeared in this record.
		seen := make(map[string]bool, allocator = record_alloc)
		for field in record {
			col_idx, found := schema.column_indexes[field.name]
			if !found {
				fail(&report, &profiles, 0, &warnings)
				return {}, .Input_Changed_During_Read
			}
			seen[field.name] = true
			state := &scan_states[col_idx]
			column_name := schema.columns[col_idx].name
			schema_kind := schema.columns[col_idx].kind

			if field.value.kind == .Null {
				observe_null(state)
				continue
			}

			observe_err := snout_core.Error.None
			switch schema_kind {
			case .String:
				observe_err = observe_string(
					state,
					field.value.string_value,
					config,
					&global_entries,
					column_name,
					&warnings,
					allocator,
				)
			case .Timestamp:
				observe_err = observe_timestamp(
					state,
					field.value.string_value,
					config,
					&global_entries,
					column_name,
					&warnings,
					allocator,
				)
			case .Int64:
				observe_int64(
					state,
					field.value.int_value,
					config,
					&global_entries,
					column_name,
					&warnings,
					allocator,
				)
			case .Float64:
				// Schema may have promoted Int64 → Float64.
				value :=
					f64(field.value.int_value) if field.value.kind == .Int64 else field.value.float_value
				observe_err = observe_float64(
					state,
					value,
					config,
					&global_entries,
					column_name,
					&warnings,
					allocator,
				)
			case .Bool:
				observe_bool(state, field.value.bool_value)
			case .Unknown:
				observe_unknown(state)
			}
			if observe_err != .None {
				fail(&report, &profiles, 0, &warnings)
				return {}, observe_err
			}
		}

		// Columns absent from this record are null.
		for &col, idx in schema.columns {
			if col.name not_in seen {
				observe_null(&scan_states[idx])
			}
		}

		mem.dynamic_arena_free_all(&record_arena)
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
