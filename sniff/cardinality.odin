package sniff

import "base:runtime"
import "core:fmt"
import "core:math"
import "core:strings"
import snout_core "../core"

Column_Scan_State :: struct {
	null_count:         int,
	non_null_count:     int,
	cardinality_exact:  bool,
	distinct_count:     int,
	lower_bound:        int,
	string_seen:        map[string]struct{},
	int_seen:           map[i64]struct{},
	float_seen:         map[u64]struct{},
	bool_has_false:     bool,
	bool_has_true:      bool,
	string_freq:        map[string]int,
	int_freq:           map[i64]int,
	bool_false_count:   int,
	bool_true_count:    int,
	numeric:            Numeric_Profile,
	timestamp:          Timestamp_Profile,
	// Welford M2 accumulator for online variance: std_dev = sqrt(m2 / count)
	m2:                 f64,
	cardinality_warned: bool,
	global_warned:      bool,
	// owned_keys makes the distinct maps clone string keys on first
	// insertion. Required when observed values are ephemeral (scanner
	// fields); table-backed profiling borrows table strings instead.
	owned_keys:         bool,
	internal_allocator: runtime.Allocator,
	ts_min_buf:         [dynamic]u8,
	ts_max_buf:         [dynamic]u8,
}

init_scan_state :: proc(state: ^Column_Scan_State) {
	state.cardinality_exact = true
	state.numeric = {}
	state.timestamp = {}
}

mark_cardinality_truncated :: proc(
	state: ^Column_Scan_State,
	config: Sniff_Config,
	column_name: string,
	warnings: ^[dynamic]string,
	allocator: runtime.Allocator,
	global_budget: bool,
) {
	if !state.cardinality_exact {
		return
	}
	state.cardinality_exact = false
	state.lower_bound = state.distinct_count + 1
	state.distinct_count = 0
	if state.cardinality_warned {
		return
	}
	state.cardinality_warned = true
	warning: string
	if global_budget {
		warning = fmt.tprintf(
			"cardinality for %s exceeded global distinct tracking budget",
			column_name,
		)
	} else {
		warning = fmt.tprintf(
			"cardinality for %s exceeded %d distinct values",
			column_name,
			config.max_distinct_values,
		)
	}
	cloned, clone_err := strings.clone(warning, allocator)
	if clone_err != nil {
		return
	}
	append(warnings, cloned)
}

track_string_value :: proc(
	state: ^Column_Scan_State,
	value: string,
	config: Sniff_Config,
	global_entries: ^int,
	column_name: string,
	warnings: ^[dynamic]string,
	allocator: runtime.Allocator,
) -> snout_core.Error {
	if !state.cardinality_exact {
		return .None
	}
	if _, found := state.string_seen[value]; found {
		state.string_freq[value] += 1
		return .None
	}
	if state.distinct_count >= config.max_distinct_values {
		mark_cardinality_truncated(state, config, column_name, warnings, allocator, false)
		return .None
	}
	if global_entries^ >= MAX_TOTAL_TRACKED_DISTINCT_VALUES {
		mark_cardinality_truncated(state, config, column_name, warnings, allocator, true)
		return .None
	}
	key := value
	if state.owned_keys {
		cloned, clone_err := strings.clone(value, state.internal_allocator)
		if clone_err != nil {
			return .Out_Of_Memory
		}
		key = cloned
	}
	state.string_seen[key] = {}
	state.string_freq[key] = 1
	state.distinct_count += 1
	global_entries^ += 1
	return .None
}

track_int_value :: proc(
	state: ^Column_Scan_State,
	value: i64,
	config: Sniff_Config,
	global_entries: ^int,
	column_name: string,
	warnings: ^[dynamic]string,
	allocator: runtime.Allocator,
) {
	if !state.cardinality_exact {
		return
	}
	if _, found := state.int_seen[value]; found {
		state.int_freq[value] += 1
		return
	}
	if state.distinct_count >= config.max_distinct_values {
		mark_cardinality_truncated(state, config, column_name, warnings, allocator, false)
		return
	}
	if global_entries^ >= MAX_TOTAL_TRACKED_DISTINCT_VALUES {
		mark_cardinality_truncated(state, config, column_name, warnings, allocator, true)
		return
	}
	state.int_seen[value] = {}
	state.int_freq[value] = 1
	state.distinct_count += 1
	global_entries^ += 1
}

track_float_value :: proc(
	state: ^Column_Scan_State,
	value: f64,
	config: Sniff_Config,
	global_entries: ^int,
	column_name: string,
	warnings: ^[dynamic]string,
	allocator: runtime.Allocator,
) {
	bits := transmute(u64)f64(value)
	if !state.cardinality_exact {
		return
	}
	if _, found := state.float_seen[bits]; found {
		return
	}
	if state.distinct_count >= config.max_distinct_values {
		mark_cardinality_truncated(state, config, column_name, warnings, allocator, false)
		return
	}
	if global_entries^ >= MAX_TOTAL_TRACKED_DISTINCT_VALUES {
		mark_cardinality_truncated(state, config, column_name, warnings, allocator, true)
		return
	}
	state.float_seen[bits] = {}
	state.distinct_count += 1
	global_entries^ += 1
}

track_bool_value :: proc(state: ^Column_Scan_State, value: bool) {
	if value {
		if !state.bool_has_true {
			state.bool_has_true = true
			state.distinct_count += 1
		}
		state.bool_true_count += 1
	} else {
		if !state.bool_has_false {
			state.bool_has_false = true
			state.distinct_count += 1
		}
		state.bool_false_count += 1
	}
}

update_int64_numeric :: proc(state: ^Column_Scan_State, value: i64) {
	if !state.numeric.valid {
		state.numeric.valid = true
		state.numeric.kind = .Int64
		state.numeric.count = 1
		state.numeric.int_min = value
		state.numeric.int_max = value
		state.numeric.mean = f64(value)
		return
	}
	state.numeric.count += 1
	if value < state.numeric.int_min {
		state.numeric.int_min = value
	}
	if value > state.numeric.int_max {
		state.numeric.int_max = value
	}
	delta := f64(value) - state.numeric.mean
	state.numeric.mean += delta / f64(state.numeric.count)
	delta2 := f64(value) - state.numeric.mean
	state.m2 += delta * delta2
}

update_float64_numeric :: proc(state: ^Column_Scan_State, value: f64) -> snout_core.Error {
	if math.is_nan(value) || math.is_inf(value) {
		return .Non_Finite_Profile_Value
	}
	if !state.numeric.valid {
		state.numeric.valid = true
		state.numeric.kind = .Float64
		state.numeric.count = 1
		state.numeric.float_min = value
		state.numeric.float_max = value
		state.numeric.mean = value
		return .None
	}
	state.numeric.count += 1
	if value < state.numeric.float_min {
		state.numeric.float_min = value
	}
	if value > state.numeric.float_max {
		state.numeric.float_max = value
	}
	delta := value - state.numeric.mean
	state.numeric.mean += delta / f64(state.numeric.count)
	delta2 := value - state.numeric.mean
	state.m2 += delta * delta2
	return .None
}

// update_timestamp_bounds copies the candidate value into reusable scratch
// buffers so the tracked min/max never reference caller-owned memory. The
// timestamp profile views are refreshed after every copy.
update_timestamp_bounds :: proc(state: ^Column_Scan_State, value: string) {
	set_buffer :: proc(buffer: ^[dynamic]u8, value: string) {
		clear(buffer)
		append(buffer, ..transmute([]u8)value)
	}
	if !state.timestamp.valid {
		state.timestamp.valid = true
		set_buffer(&state.ts_min_buf, value)
		set_buffer(&state.ts_max_buf, value)
		state.timestamp.min = string(state.ts_min_buf[:])
		state.timestamp.max = string(state.ts_max_buf[:])
		return
	}
	if value < state.timestamp.min {
		set_buffer(&state.ts_min_buf, value)
		state.timestamp.min = string(state.ts_min_buf[:])
	}
	if value > state.timestamp.max {
		set_buffer(&state.ts_max_buf, value)
		state.timestamp.max = string(state.ts_max_buf[:])
	}
}

Top_Value_Entry :: struct {
	value: Profile_Value,
	count: int,
}

compare_top_values :: proc(a, b: Top_Value_Entry) -> bool {
	if a.count != b.count {
		return a.count > b.count
	}
	#partial switch a.value.kind {
	case .Bool:
		return !a.value.bool_value && b.value.bool_value
	case .Int64:
		return a.value.int_value < b.value.int_value
	case .String:
		return a.value.string_value < b.value.string_value
	case:
		return false
	}
}

sort_top_value_entries :: proc(entries: []Top_Value_Entry) {
	for i in 1..<len(entries) {
		key := entries[i]
		j := i - 1
		for j >= 0 && compare_top_values(key, entries[j]) {
			entries[j+1] = entries[j]
			j -= 1
		}
		entries[j+1] = key
	}
}

materialize_top_values :: proc(
	state: ^Column_Scan_State,
	role: Column_Role,
	kind: snout_core.Column_Type,
	top_count: int,
	allocator: runtime.Allocator,
) -> ([]Top_Value, snout_core.Error) {
	if top_count == 0 || role != .Dimension {
		return nil, .None
	}
	entries := make([dynamic]Top_Value_Entry, 0, allocator=context.temp_allocator)
	#partial switch kind {
	case .String:
		for value, count in state.string_freq {
			append(&entries, Top_Value_Entry{
				value = Profile_Value{kind = .String, string_value = value},
				count = count,
			})
		}
	case .Int64:
		for value, count in state.int_freq {
			append(&entries, Top_Value_Entry{
				value = Profile_Value{kind = .Int64, int_value = value},
				count = count,
			})
		}
	case .Bool:
		if state.bool_false_count > 0 {
			append(&entries, Top_Value_Entry{
				value = Profile_Value{kind = .Bool, bool_value = false},
				count = state.bool_false_count,
			})
		}
		if state.bool_true_count > 0 {
			append(&entries, Top_Value_Entry{
				value = Profile_Value{kind = .Bool, bool_value = true},
				count = state.bool_true_count,
			})
		}
	case:
		return nil, .None
	}
	sort_top_value_entries(entries[:])
	limit := min(top_count, len(entries))
	result := make([]Top_Value, limit, allocator)
	for entry, index in entries[:limit] {
		top := Top_Value{value = entry.value, count = entry.count}
		if top.value.kind == .String {
			cloned, clone_err := strings.clone(top.value.string_value, allocator)
			if clone_err != nil {
				for i in 0..<index {
					delete(result[i].value.string_value, allocator)
				}
				delete(result)
				return nil, .Out_Of_Memory
			}
			top.value.string_value = cloned
		}
		result[index] = top
	}
	return result, .None
}
