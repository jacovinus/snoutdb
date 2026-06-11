package query

import "base:intrinsics"
import "base:runtime"
import "core:slice"
import "core:sort"
import "core:strings"
import snout_core "../core"

Aggregate_State :: struct {
	value_count:       int,
	int_sum:           i64,
	float_sum:         f64,
	int_min:           i64,
	int_max:           i64,
	float_min:         f64,
	float_max:         f64,
	bool_true_count:   int,
	percentile_values: [dynamic]f64,
	// count_distinct tracking — only one field is used per aggregate, depending on column type
	distinct_strings:  map[string]struct{},
	distinct_ints:     map[i64]struct{},
	distinct_floats:   map[u64]struct{},  // float64 bit patterns
	distinct_bools:    [2]bool,           // [0]=false seen, [1]=true seen
}

Temporary_Group :: struct {
	keys:           []Group_Key,
	states:         []Aggregate_State,
	row_count:      int,
	next_same_hash: int,
}

execute_group_query :: proc(
	table: ^snout_core.Table,
	group_query: Group_Query,
	allocator := context.allocator,
) -> (Group_Result_Set, snout_core.Error) {
	if len(group_query.group_columns) == 0 ||
	   len(group_query.group_columns) > MAX_GROUP_COLUMNS ||
	   len(group_query.aggregates) == 0 ||
	   len(group_query.aggregates) > MAX_AGGREGATES {
		return {}, .Malformed_Query_Arguments
	}
	for column_name, index in group_query.group_columns {
		for previous in group_query.group_columns[:index] {
			if column_name == previous {
				return {}, .Duplicate_Result_Column
			}
		}
	}
	for spec, index in group_query.aggregates {
		for previous in group_query.aggregates[:index] {
			if spec.kind == previous.kind && spec.column_name == previous.column_name {
				if spec.kind != .Percentile || spec.percentile == previous.percentile {
					return {}, .Duplicate_Result_Column
				}
			}
		}
	}

	group_columns := make(
		[]^snout_core.Column,
		len(group_query.group_columns),
		context.temp_allocator,
	)
	for column_name, index in group_query.group_columns {
		column, found := snout_core.get_column(table, column_name)
		if !found {
			return {}, .Column_Not_Found
		}
		switch column.kind {
		case .Float64, .Unknown:
			return {}, .Unsupported_Group_Column_Type
		case .String, .Timestamp, .Int64, .Bool:
		}
		group_columns[index] = column
	}

	value_columns := make(
		[]^snout_core.Column,
		len(group_query.aggregates),
		context.temp_allocator,
	)
	for spec, index in group_query.aggregates {
		count_star := spec.kind == .Count && spec.column_name == "*"
		if count_star {
			continue
		}
		if spec.column_name == "" || spec.column_name == "*" {
			return {}, .Invalid_Aggregate_Column
		}
		column, found := snout_core.get_column(table, spec.column_name)
		if !found {
			return {}, .Column_Not_Found
		}
		switch spec.kind {
		case .Error_Rate:
			if column.kind != .Bool {
				return {}, .Invalid_Aggregate_Column
			}
		case .Sum, .Avg, .Min, .Max, .Percentile:
			if column.kind != .Int64 && column.kind != .Float64 {
				return {}, .Invalid_Aggregate_Column
			}
		case .Count_Distinct:
			if column.kind == .Unknown {
				return {}, .Invalid_Aggregate_Column
			}
		case .Count:
		}
		value_columns[index] = column
	}

	selection, selected_rows, selection_err := build_selection(
		table,
		group_query.filters,
		context.temp_allocator,
	)
	if selection_err != .None {
		return {}, selection_err
	}

	max_groups := group_query.max_groups
	if max_groups <= 0 {
		max_groups = DEFAULT_MAX_GROUPS
	}
	groups := make([dynamic]Temporary_Group, 0, allocator=context.temp_allocator)
	hash_heads := make(map[u64]int, allocator=context.temp_allocator)

	for row_index in 0..<table.row_count {
		if !selection[row_index] {
			continue
		}

		key_hash := hash_group_row(group_columns, row_index)
		group_index := -1
		if head, found := hash_heads[key_hash]; found {
			candidate := head
			for candidate >= 0 {
				if group_keys_equal_row(groups[candidate].keys, group_columns, row_index) {
					group_index = candidate
					break
				}
				candidate = groups[candidate].next_same_hash
			}
		}
		if group_index < 0 {
			if len(groups) >= max_groups {
				return {}, .Too_Many_Groups
			}
			keys := make([]Group_Key, len(group_columns), context.temp_allocator)
			for column, index in group_columns {
				keys[index] = group_key_from_row(column, row_index)
			}
			states := make(
				[]Aggregate_State,
				len(group_query.aggregates),
				context.temp_allocator,
			)
			for spec, agg_idx in group_query.aggregates {
				if spec.kind == .Percentile {
					states[agg_idx].percentile_values = make(
						[dynamic]f64,
						0,
						64,
						context.temp_allocator,
					)
				}
				if spec.kind == .Count_Distinct {
					col := value_columns[agg_idx]
					if col != nil {
						switch col.kind {
						case .String, .Timestamp:
							states[agg_idx].distinct_strings = make(map[string]struct{}, context.temp_allocator)
						case .Int64:
							states[agg_idx].distinct_ints = make(map[i64]struct{}, context.temp_allocator)
						case .Float64:
							states[agg_idx].distinct_floats = make(map[u64]struct{}, context.temp_allocator)
						case .Bool, .Unknown:
						}
					}
				}
			}
			next := -1
			if head, found := hash_heads[key_hash]; found {
				next = head
			}
			append(&groups, Temporary_Group{
				keys = keys,
				states = states,
				next_same_hash = next,
			})
			group_index = len(groups)-1
			hash_heads[key_hash] = group_index
		}

		group := &groups[group_index]
		group.row_count += 1
		for spec, aggregate_index in group_query.aggregates {
			state := &group.states[aggregate_index]
			count_star := spec.kind == .Count && spec.column_name == "*"
			if count_star {
				state.value_count += 1
				continue
			}
			value_column := value_columns[aggregate_index]
			if value_column.null_mask[row_index] {
				continue
			}
			state.value_count += 1
			if spec.kind == .Count {
				continue
			}
			if spec.kind == .Count_Distinct {
				switch value_column.kind {
				case .String, .Timestamp:
					state.distinct_strings[value_column.strings[row_index]] = {}
				case .Int64:
					state.distinct_ints[value_column.int64s[row_index]] = {}
				case .Float64:
					state.distinct_floats[transmute(u64)value_column.float64s[row_index]] = {}
				case .Bool:
					if value_column.bools[row_index] {
						state.distinct_bools[1] = true
					} else {
						state.distinct_bools[0] = true
					}
				case .Unknown:
				}
				continue
			}
			#partial switch value_column.kind {
			case .Int64:
				value := value_column.int64s[row_index]
				if spec.kind == .Sum || spec.kind == .Avg {
					next_sum, overflow := intrinsics.overflow_add(state.int_sum, value)
					if overflow {
						return {}, .Aggregate_Overflow
					}
					state.int_sum = next_sum
				}
				if spec.kind == .Percentile {
					append(&state.percentile_values, f64(value))
				}
				if state.value_count == 1 {
					state.int_min = value
					state.int_max = value
				} else {
					state.int_min = min(state.int_min, value)
					state.int_max = max(state.int_max, value)
				}
			case .Float64:
				value := value_column.float64s[row_index]
				if spec.kind == .Sum || spec.kind == .Avg {
					state.float_sum += value
				}
				if spec.kind == .Percentile {
					append(&state.percentile_values, value)
				}
				if state.value_count == 1 {
					state.float_min = value
					state.float_max = value
				} else {
					state.float_min = min(state.float_min, value)
					state.float_max = max(state.float_max, value)
				}
			case .Bool:
				if spec.kind == .Error_Rate {
					if value_column.bools[row_index] {
						state.bool_true_count += 1
					}
				}
			case:
			}
		}
	}

	result: Group_Result_Set
	result.allocator = allocator
	result.filter_count = len(group_query.filters)
	result.selected_rows = selected_rows
	result.group_columns = clone_strings(group_query.group_columns, allocator)
	result.aggregates = clone_aggregate_specs(group_query.aggregates, allocator)
	result.groups, _ = make([]Group_Result, len(groups), allocator)
	if len(groups) > 0 && result.groups == nil {
		free_group_result_set(&result)
		return {}, .Out_Of_Memory
	}

	for temporary, index in groups {
		group := &result.groups[index]
		group.row_count = temporary.row_count
		group.keys, _ = make([]Group_Key, len(temporary.keys), allocator)
		group.values, _ = make(
			[]Aggregate_Value,
			len(group_query.aggregates),
			allocator,
		)
		for key, key_index in temporary.keys {
			group.keys[key_index] = key
			if key.kind == .String || key.kind == .Timestamp {
				group.keys[key_index].string_value, _ = strings.clone(
					key.string_value,
					allocator,
				)
			}
		}
		for spec, aggregate_index in group_query.aggregates {
			group.values[aggregate_index] = materialize_aggregate(
				temporary.states[aggregate_index],
				spec,
				value_columns[aggregate_index],
			)
		}
	}
	sort.quick_sort_proc(result.groups, compare_group_results)
	return result, .None
}

materialize_aggregate :: proc(
	state: Aggregate_State,
	spec: Aggregate_Spec,
	value_column: ^snout_core.Column,
) -> Aggregate_Value {
	if spec.kind == .Count {
		return Aggregate_Value{
			valid = true,
			kind = .Int64,
			count = state.value_count,
			int_value = i64(state.value_count),
		}
	}
	if spec.kind == .Percentile {
		values := state.percentile_values
		if len(values) == 0 {
			return Aggregate_Value{valid = false, kind = .Float64}
		}
		slice.sort(values[:])
		count := len(values)
		idx := int(spec.percentile * f64(count - 1))
		return Aggregate_Value{
			valid       = true,
			kind        = .Float64,
			count       = count,
			float_value = values[idx],
		}
	}
	if spec.kind == .Error_Rate {
		if state.value_count == 0 {
			return Aggregate_Value{valid = false, kind = .Float64}
		}
		return Aggregate_Value{
			valid       = true,
			kind        = .Float64,
			count       = state.value_count,
			float_value = f64(state.bool_true_count) / f64(state.value_count),
		}
	}
	if spec.kind == .Count_Distinct {
		n: int
		if value_column != nil {
			switch value_column.kind {
			case .String, .Timestamp:
				n = len(state.distinct_strings)
			case .Int64:
				n = len(state.distinct_ints)
			case .Float64:
				n = len(state.distinct_floats)
			case .Bool:
				n = (1 if state.distinct_bools[0] else 0) + (1 if state.distinct_bools[1] else 0)
			case .Unknown:
			}
		}
		return Aggregate_Value{
			valid      = true,
			kind       = .Int64,
			count      = state.value_count,
			int_value  = i64(n),
		}
	}
	if state.value_count == 0 {
		return Aggregate_Value{valid = false, kind = value_column.kind}
	}
	value := Aggregate_Value{
		valid = true,
		kind = value_column.kind,
		count = state.value_count,
	}
	#partial switch value_column.kind {
	case .Int64:
		switch spec.kind {
		case .Sum: value.int_value = state.int_sum
		case .Avg: value.kind = .Float64; value.float_value = f64(state.int_sum)/f64(state.value_count)
		case .Min: value.int_value = state.int_min
		case .Max: value.int_value = state.int_max
		case .Count, .Percentile, .Error_Rate, .Count_Distinct:
		}
	case .Float64:
		switch spec.kind {
		case .Sum: value.float_value = state.float_sum
		case .Avg: value.float_value = state.float_sum/f64(state.value_count)
		case .Min: value.float_value = state.float_min
		case .Max: value.float_value = state.float_max
		case .Count, .Percentile, .Error_Rate, .Count_Distinct:
		}
	case:
	}
	return value
}

group_key_from_row :: proc(column: ^snout_core.Column, row_index: int) -> Group_Key {
	key := Group_Key{kind = column.kind, is_null = column.null_mask[row_index]}
	if key.is_null {
		return key
	}
	switch column.kind {
	case .String, .Timestamp:
		key.string_value = column.strings[row_index]
	case .Int64:
		key.int_value = column.int64s[row_index]
	case .Bool:
		key.bool_value = column.bools[row_index]
	case .Float64, .Unknown:
	}
	return key
}

group_keys_equal_row :: proc(
	keys: []Group_Key,
	columns: []^snout_core.Column,
	row_index: int,
) -> bool {
	for key, index in keys {
		other := group_key_from_row(columns[index], row_index)
		if compare_group_keys(key, other) != 0 {
			return false
		}
	}
	return true
}

hash_group_row :: proc(columns: []^snout_core.Column, row_index: int) -> u64 {
	hash := u64(0xcbf29ce484222325)
	for column in columns {
		hash = hash_mix_byte(hash, byte(column.kind))
		if column.null_mask[row_index] {
			hash = hash_mix_byte(hash, 0xff)
			continue
		}
		hash = hash_mix_byte(hash, 0)
		switch column.kind {
		case .String, .Timestamp:
			for value in transmute([]byte)column.strings[row_index] {
				hash = hash_mix_byte(hash, value)
			}
		case .Int64:
			value := cast(u64)column.int64s[row_index]
			for shift := u64(0); shift < 64; shift += 8 {
				hash = hash_mix_byte(hash, byte(value>>shift))
			}
		case .Bool:
			hash = hash_mix_byte(hash, 1 if column.bools[row_index] else 0)
		case .Float64, .Unknown:
		}
		hash = hash_mix_byte(hash, 0xfe)
	}
	return hash
}

hash_mix_byte :: proc(hash: u64, value: byte) -> u64 {
	return (hash~u64(value))*u64(0x100000001b3)
}

compare_group_results :: proc(a, b: Group_Result) -> int {
	for key, index in a.keys {
		comparison := compare_group_keys(key, b.keys[index])
		if comparison != 0 {
			return comparison
		}
	}
	return 0
}

compare_group_keys :: proc(a, b: Group_Key) -> int {
	if a.is_null {
		return 0 if b.is_null else -1
	}
	if b.is_null {
		return 1
	}
	switch a.kind {
	case .String, .Timestamp:
		return strings.compare(a.string_value, b.string_value)
	case .Int64:
		return -1 if a.int_value < b.int_value else 1 if a.int_value > b.int_value else 0
	case .Bool:
		return -1 if !a.bool_value && b.bool_value else 1 if a.bool_value && !b.bool_value else 0
	case .Float64, .Unknown:
		return 0
	}
	return 0
}

clone_strings :: proc(values: []string, allocator: runtime.Allocator) -> []string {
	result, _ := make([]string, len(values), allocator)
	for value, index in values {
		result[index], _ = strings.clone(value, allocator)
	}
	return result
}

clone_aggregate_specs :: proc(
	specs: []Aggregate_Spec,
	allocator: runtime.Allocator,
) -> []Aggregate_Spec {
	result, _ := make([]Aggregate_Spec, len(specs), allocator)
	for spec, index in specs {
		result[index].kind = spec.kind
		result[index].column_name, _ = strings.clone(spec.column_name, allocator)
		result[index].percentile = spec.percentile
	}
	return result
}
