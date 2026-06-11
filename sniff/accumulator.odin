package sniff

import "base:runtime"
import "core:math"
import "core:strings"
import snout_core "../core"

// The column accumulator is the single implementation of per-column profile
// accumulation. profile_table feeds it table-owned values (borrowed keys);
// profile_csv_file feeds it ephemeral scanner fields (owned keys).

init_column_accumulator :: proc(
	state: ^Column_Scan_State,
	internal_allocator: runtime.Allocator,
	owned_keys := false,
) {
	init_scan_state(state)
	state.string_seen = make(map[string]struct{}, internal_allocator)
	state.int_seen = make(map[i64]struct{}, internal_allocator)
	state.float_seen = make(map[u64]struct{}, internal_allocator)
	state.string_freq = make(map[string]int, internal_allocator)
	state.int_freq = make(map[i64]int, internal_allocator)
	state.ts_min_buf = make([dynamic]u8, 0, allocator = internal_allocator)
	state.ts_max_buf = make([dynamic]u8, 0, allocator = internal_allocator)
	state.owned_keys = owned_keys
	state.internal_allocator = internal_allocator
}

observe_null :: proc(state: ^Column_Scan_State) {
	state.null_count += 1
}

observe_string :: proc(
	state: ^Column_Scan_State,
	value: string,
	config: Sniff_Config,
	global_entries: ^int,
	column_name: string,
	warnings: ^[dynamic]string,
	warning_allocator: runtime.Allocator,
) -> snout_core.Error {
	state.non_null_count += 1
	return track_string_value(
		state,
		value,
		config,
		global_entries,
		column_name,
		warnings,
		warning_allocator,
	)
}

observe_timestamp :: proc(
	state: ^Column_Scan_State,
	value: string,
	config: Sniff_Config,
	global_entries: ^int,
	column_name: string,
	warnings: ^[dynamic]string,
	warning_allocator: runtime.Allocator,
) -> snout_core.Error {
	state.non_null_count += 1
	track_err := track_string_value(
		state,
		value,
		config,
		global_entries,
		column_name,
		warnings,
		warning_allocator,
	)
	if track_err != .None {
		return track_err
	}
	update_timestamp_bounds(state, value)
	return .None
}

observe_int64 :: proc(
	state: ^Column_Scan_State,
	value: i64,
	config: Sniff_Config,
	global_entries: ^int,
	column_name: string,
	warnings: ^[dynamic]string,
	warning_allocator: runtime.Allocator,
) {
	state.non_null_count += 1
	track_int_value(
		state,
		value,
		config,
		global_entries,
		column_name,
		warnings,
		warning_allocator,
	)
	update_int64_numeric(state, value)
}

observe_float64 :: proc(
	state: ^Column_Scan_State,
	value: f64,
	config: Sniff_Config,
	global_entries: ^int,
	column_name: string,
	warnings: ^[dynamic]string,
	warning_allocator: runtime.Allocator,
) -> snout_core.Error {
	state.non_null_count += 1
	if num_err := update_float64_numeric(state, value); num_err != .None {
		return num_err
	}
	track_float_value(
		state,
		value,
		config,
		global_entries,
		column_name,
		warnings,
		warning_allocator,
	)
	return .None
}

observe_bool :: proc(state: ^Column_Scan_State, value: bool) {
	state.non_null_count += 1
	track_bool_value(state, value)
}

observe_unknown :: proc(state: ^Column_Scan_State) {
	state.non_null_count += 1
}

// finalize_column_profile materializes the accumulated state into an owned
// Column_Profile. Top values and role classification remain separate steps
// because they depend on the classified role.
finalize_column_profile :: proc(
	state: ^Column_Scan_State,
	column_name: string,
	kind: snout_core.Column_Type,
	row_count: int,
	source_index: int,
	allocator: runtime.Allocator,
) -> (profile: Column_Profile, err: snout_core.Error) {
	null_ratio: f64 = 0.0
	if row_count > 0 {
		null_ratio = f64(state.null_count) / f64(row_count)
	}

	owned_name, name_err := strings.clone(column_name, allocator)
	if name_err != nil {
		return {}, .Out_Of_Memory
	}

	cardinality := Cardinality_Profile {
		exact          = state.cardinality_exact,
		distinct_count = state.distinct_count,
		lower_bound    = state.lower_bound,
	}
	if !cardinality.exact {
		cardinality.distinct_count = 0
	}

	numeric := state.numeric
	if numeric.valid && numeric.count >= 2 {
		numeric.std_dev = math.sqrt(state.m2 / f64(numeric.count))
	}

	profile = Column_Profile {
		name           = owned_name,
		kind           = kind,
		row_count      = row_count,
		null_count     = state.null_count,
		non_null_count = state.non_null_count,
		null_ratio     = null_ratio,
		cardinality    = cardinality,
		numeric        = numeric,
		timestamp      = {},
		source_index   = source_index,
	}

	if state.timestamp.valid {
		min_ts, min_err := strings.clone(state.timestamp.min, allocator)
		if min_err != nil {
			delete(owned_name, allocator)
			return {}, .Out_Of_Memory
		}
		max_ts, max_err := strings.clone(state.timestamp.max, allocator)
		if max_err != nil {
			delete(min_ts, allocator)
			delete(owned_name, allocator)
			return {}, .Out_Of_Memory
		}
		profile.timestamp = Timestamp_Profile {
			valid = true,
			min   = min_ts,
			max   = max_ts,
		}
	}
	return profile, .None
}

free_column_accumulator :: proc(state: ^Column_Scan_State) {
	if state.owned_keys {
		for key in state.string_seen {
			delete(key, state.internal_allocator)
		}
	}
	delete(state.string_seen)
	delete(state.int_seen)
	delete(state.float_seen)
	delete(state.string_freq)
	delete(state.int_freq)
	delete(state.ts_min_buf)
	delete(state.ts_max_buf)
	state^ = {}
}
