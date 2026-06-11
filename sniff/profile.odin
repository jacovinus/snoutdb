package sniff

import "base:runtime"
import "core:strings"
import snout_core "../core"

profile_table :: proc(
	table: ^snout_core.Table,
	config: Sniff_Config = DEFAULT_SNIFF_CONFIG,
	allocator := context.allocator,
) -> (Sniff_Report, snout_core.Error) {
	if table == nil {
		return {}, .Invalid_Sniff_Config
	}
	if err := validate_sniff_config(config); err != .None {
		return {}, err
	}

	report := Sniff_Report{
		version = REPORT_VERSION,
		row_count = table.row_count,
		column_count = len(table.columns),
		allocator = allocator,
	}
	table_name, name_err := strings.clone(table.name, allocator)
	if name_err != nil {
		return {}, .Out_Of_Memory
	}
	report.table_name = table_name

	profiles := make([]Column_Profile, len(table.columns), allocator)
	scan_states := make([]Column_Scan_State, len(table.columns), context.temp_allocator)
	warnings := make([dynamic]string, 0, context.temp_allocator)
	global_entries := 0

	for &column, index in table.columns {
		init_column_accumulator(&scan_states[index], context.temp_allocator)

		state := &scan_states[index]
		row_count := table.row_count
		for row_index in 0..<row_count {
			if column.null_mask[row_index] {
				observe_null(state)
				continue
			}
			observe_err := snout_core.Error.None
			#partial switch column.kind {
			case .String:
				observe_err = observe_string(
					state,
					column.strings[row_index],
					config,
					&global_entries,
					column.name,
					&warnings,
					allocator,
				)
			case .Timestamp:
				observe_err = observe_timestamp(
					state,
					column.strings[row_index],
					config,
					&global_entries,
					column.name,
					&warnings,
					allocator,
				)
			case .Int64:
				observe_int64(
					state,
					column.int64s[row_index],
					config,
					&global_entries,
					column.name,
					&warnings,
					allocator,
				)
			case .Float64:
				observe_err = observe_float64(
					state,
					column.float64s[row_index],
					config,
					&global_entries,
					column.name,
					&warnings,
					allocator,
				)
			case .Bool:
				observe_bool(state, column.bools[row_index])
			case .Unknown:
				observe_unknown(state)
			}
			if observe_err != .None {
				for warning in warnings {
					delete(warning, allocator)
				}
				cleanup_profiles_on_error(&profiles, index, allocator)
				delete(report.table_name, allocator)
				return {}, observe_err
			}
		}

		profile, finalize_err := finalize_column_profile(
			state,
			column.name,
			column.kind,
			row_count,
			index,
			allocator,
		)
		if finalize_err != .None {
			for warning in warnings {
				delete(warning, allocator)
			}
			cleanup_profiles_on_error(&profiles, index, allocator)
			delete(report.table_name, allocator)
			return {}, finalize_err
		}
		profiles[index] = profile
	}

	for &profile in profiles {
		classify_column_role(&profile)
		reason, reason_err := strings.clone(profile.role_reason, allocator)
		if reason_err != nil {
			cleanup_profiles_on_error(&profiles, len(profiles), allocator)
			for warning in warnings {
				delete(warning, allocator)
			}
			delete(report.table_name, allocator)
			return {}, .Out_Of_Memory
		}
		profile.role_reason = reason
	}

	// Second pass over in-memory columns: count outliers (values beyond 3σ from mean).
	// Only runs for Metric numeric columns with a valid std_dev. Streaming paths skip
	// this because they don't have access to the column data after the scan.
	for &profile, index in profiles {
		if profile.role != .Metric || !profile.numeric.valid || profile.numeric.std_dev == 0 {
			continue
		}
		col := &table.columns[index]
		mean      := profile.numeric.mean
		threshold := 3.0 * profile.numeric.std_dev
		for row_index in 0..<table.row_count {
			if col.null_mask[row_index] {
				continue
			}
			v: f64
			#partial switch col.kind {
			case .Int64:   v = f64(col.int64s[row_index])
			case .Float64: v = col.float64s[row_index]
			case: continue
			}
			diff := v - mean
			if diff < 0 { diff = -diff }
			if diff > threshold {
				profile.numeric.outlier_count += 1
			}
		}
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
			cleanup_profiles_on_error(&profiles, len(profiles), allocator)
			for warning in warnings {
				delete(warning, allocator)
			}
			delete(report.table_name, allocator)
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
		cleanup_profiles_on_error(&profiles, len(profiles), allocator)
		for warning in warnings {
			delete(warning, allocator)
		}
		delete(report.table_name, allocator)
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

cleanup_profiles_on_error :: proc(
	profiles: ^[]Column_Profile,
	count: int,
	allocator: runtime.Allocator,
) {
	for i in 0..<count {
		delete(profiles[i].name, allocator)
		delete(profiles[i].role_reason, allocator)
		delete(profiles[i].timestamp.min, allocator)
		delete(profiles[i].timestamp.max, allocator)
		for &top in profiles[i].top_values {
			if top.value.kind == .String {
				delete(top.value.string_value, allocator)
			}
		}
		delete(profiles[i].top_values, allocator)
	}
	delete(profiles^, allocator)
}
