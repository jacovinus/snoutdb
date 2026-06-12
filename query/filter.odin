package query

import "core:math"
import "core:strconv"
import "core:strings"
import snout_core "../core"

parse_filter_operator :: proc(text: string) -> (Filter_Operator, bool) {
	switch text {
	case "eq":       return .Equal, true
	case "ne":       return .Not_Equal, true
	case "lt":       return .Less, true
	case "le":       return .Less_Equal, true
	case "gt":       return .Greater, true
	case "ge":       return .Greater_Equal, true
	case "contains": return .Contains, true
	case "not-contains": return .Not_Contains, true
	case "icontains": return .IContains, true
	case "is-null":  return .Is_Null, true
	case "not-null": return .Is_Not_Null, true
	}
	return .Equal, false
}

parse_aggregate_kind :: proc(text: string) -> (Aggregate_Kind, bool) {
	switch text {
	case "count":      return .Count, true
	case "sum":        return .Sum, true
	case "avg":        return .Avg, true
	case "min":        return .Min, true
	case "max":        return .Max, true
	case "error_rate": return .Error_Rate, true
	}
	return .Count, false
}

// parse_aggregate_spec_kind parses the left-hand side of an aggregate expression
// (e.g. "p95", "error_rate", "avg") and returns a partial Aggregate_Spec with
// kind and percentile filled; column_name is left empty for the caller to set.
parse_aggregate_spec_kind :: proc(text: string) -> (spec: Aggregate_Spec, ok: bool) {
	switch text {
	case "count":      return {kind = .Count}, true
	case "sum":        return {kind = .Sum}, true
	case "avg":        return {kind = .Avg}, true
	case "min":        return {kind = .Min}, true
	case "max":        return {kind = .Max}, true
	case "error_rate":      return {kind = .Error_Rate}, true
	case "count_distinct":  return {kind = .Count_Distinct}, true
	}
	if len(text) >= 2 && text[0] == 'p' {
		n, n_ok := strconv.parse_int(text[1:])
		if n_ok && n >= 0 && n <= 99 {
			return {kind = .Percentile, percentile = f64(n) / 100.0}, true
		}
	}
	return {}, false
}

make_filter_predicate :: proc(
	table: ^snout_core.Table,
	column_name: string,
	operator: Filter_Operator,
	literal: string,
) -> (Filter_Predicate, snout_core.Error) {
	column, found := snout_core.get_column(table, column_name)
	if !found {
		return {}, .Column_Not_Found
	}
	if column.kind == .Bool &&
	   operator != .Equal && operator != .Not_Equal &&
	   operator != .Is_Null && operator != .Is_Not_Null {
		return {}, .Unsupported_Filter_Operator
	}
	if (operator == .Contains || operator == .Not_Contains || operator == .IContains) &&
	   column.kind != .String {
		return {}, .Unsupported_Filter_Operator
	}

	predicate := Filter_Predicate{
		column_name = column_name,
		operator = operator,
		value = Filter_Value{kind = column.kind},
	}
	if operator == .Is_Null || operator == .Is_Not_Null {
		return predicate, .None
	}

	switch column.kind {
	case .String:
		predicate.value.string_value = literal
	case .Timestamp:
		if !is_query_timestamp(literal) {
			return {}, .Invalid_Filter_Value
		}
		predicate.value.string_value = literal
	case .Int64:
		value, ok := parse_query_i64(literal)
		if !ok {
			return {}, .Invalid_Filter_Value
		}
		predicate.value.int_value = value
	case .Float64:
		value, ok := strconv.parse_f64(literal)
		if !ok || math.is_inf(value) || math.is_nan(value) {
			return {}, .Invalid_Filter_Value
		}
		predicate.value.float_value = value
	case .Bool:
		switch literal {
		case "true":  predicate.value.bool_value = true
		case "false": predicate.value.bool_value = false
		case: return {}, .Invalid_Filter_Value
		}
	case .Unknown:
		return {}, .Invalid_Filter_Value
	}
	return predicate, .None
}

build_selection :: proc(
	table: ^snout_core.Table,
	predicates: []Filter_Predicate,
	allocator := context.allocator,
) -> ([]bool, int, snout_core.Error) {
	if len(predicates) > MAX_FILTERS {
		return nil, 0, .Too_Many_Filters
	}
	selection, alloc_err := make([]bool, table.row_count, allocator)
	if alloc_err != nil {
		return nil, 0, .Out_Of_Memory
	}
	for &selected in selection {
		selected = true
	}

	columns := make([]^snout_core.Column, len(predicates), context.temp_allocator)
	for predicate, index in predicates {
		column, found := snout_core.get_column(table, predicate.column_name)
		if !found {
			delete(selection, allocator)
			return nil, 0, .Column_Not_Found
		}
		columns[index] = column
	}

	selected_count := 0
	for row_index in 0..<table.row_count {
		for predicate, index in predicates {
			if !row_matches(columns[index], row_index, predicate) {
				selection[row_index] = false
				break
			}
		}
		if selection[row_index] {
			selected_count += 1
		}
	}
	return selection, selected_count, .None
}

row_matches :: proc(
	column: ^snout_core.Column,
	row_index: int,
	predicate: Filter_Predicate,
) -> bool {
	is_null := column.null_mask[row_index]
	#partial switch predicate.operator {
	case .Is_Null:
		return is_null
	case .Is_Not_Null:
		return !is_null
	case:
		if is_null {
			return false
		}
	}

	comparison: int
	switch column.kind {
	case .String, .Timestamp:
		if predicate.operator == .Contains {
			return strings.contains(column.strings[row_index], predicate.value.string_value)
		}
		if predicate.operator == .Not_Contains {
			return !strings.contains(column.strings[row_index], predicate.value.string_value)
		}
		if predicate.operator == .IContains {
			return contains_ascii_fold(column.strings[row_index], predicate.value.string_value)
		}
		comparison = strings.compare(column.strings[row_index], predicate.value.string_value)
	case .Int64:
		value := column.int64s[row_index]
		expected := predicate.value.int_value
		comparison = -1 if value < expected else 1 if value > expected else 0
	case .Float64:
		value := column.float64s[row_index]
		expected := predicate.value.float_value
		comparison = -1 if value < expected else 1 if value > expected else 0
	case .Bool:
		value := column.bools[row_index]
		expected := predicate.value.bool_value
		comparison = -1 if !value && expected else 1 if value && !expected else 0
	case .Unknown:
		return false
	}

	switch predicate.operator {
	case .Equal:         return comparison == 0
	case .Not_Equal:     return comparison != 0
	case .Less:          return comparison < 0
	case .Less_Equal:    return comparison <= 0
	case .Greater:       return comparison > 0
	case .Greater_Equal: return comparison >= 0
	case .Contains, .Not_Contains, .IContains: return false
	case .Is_Null, .Is_Not_Null: return false
	}
	return false
}

contains_ascii_fold :: proc(value, needle: string) -> bool {
	if needle == "" {
		return true
	}
	if len(needle) > len(value) {
		return false
	}
	for start in 0..=len(value)-len(needle) {
		matches := true
		for offset in 0..<len(needle) {
			left := value[start+offset]
			right := needle[offset]
			if left >= 'A' && left <= 'Z' {
				left += 'a'-'A'
			}
			if right >= 'A' && right <= 'Z' {
				right += 'a'-'A'
			}
			if left != right {
				matches = false
				break
			}
		}
		if matches {
			return true
		}
	}
	return false
}

parse_query_i64 :: proc(text: string) -> (i64, bool) {
	if text == "" {
		return 0, false
	}
	negative := text[0] == '-'
	start := 1 if negative else 0
	if start == len(text) {
		return 0, false
	}
	limit := u64(max(i64)) + (1 if negative else 0)
	magnitude: u64
	for character in text[start:] {
		if character < '0' || character > '9' {
			return 0, false
		}
		digit := u64(character-'0')
		if magnitude > (limit-digit)/10 {
			return 0, false
		}
		magnitude = magnitude*10 + digit
	}
	if negative {
		if magnitude == u64(max(i64))+1 {
			return min(i64), true
		}
		return -i64(magnitude), true
	}
	return i64(magnitude), true
}

is_query_timestamp :: proc(value: string) -> bool {
	return len(value) >= 20 &&
	       value[len(value)-1] == 'Z' &&
	       value[4] == '-' &&
	       value[7] == '-' &&
	       value[10] == 'T' &&
	       value[13] == ':' &&
	       value[16] == ':'
}
