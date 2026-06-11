package query

import "core:sort"
import snout_core "../core"

Sort_Context :: struct {
	groups: []Group_Result,
	terms:  []Sort_Term,
}

parse_sort_direction :: proc(text: string) -> (Sort_Direction, bool) {
	switch text {
	case "asc":  return .Ascending, true
	case "desc": return .Descending, true
	}
	return .Ascending, false
}

parse_result_limit :: proc(text: string) -> (int, snout_core.Error) {
	value, ok := parse_query_i64(text)
	if !ok || value < 0 {
		return 0, .Invalid_Limit
	}
	if value > MAX_RESULT_LIMIT {
		return 0, .Limit_Too_Large
	}
	return int(value), .None
}

resolve_sort_target :: proc(
	result: ^Group_Result_Set,
	target: string,
) -> (Sort_Term, snout_core.Error) {
	for column_name, index in result.group_columns {
		if target == column_name {
			return Sort_Term{
				target_kind = .Group_Column,
				result_index = index,
			}, .None
		}
	}
	kind_text, column_name, ok := split_aggregate_expression(target)
	if !ok {
		return {}, .Sort_Target_Not_Found
	}
	partial, kind_ok := parse_aggregate_spec_kind(kind_text)
	if !kind_ok {
		return {}, .Sort_Target_Not_Found
	}
	if partial.kind == .Count && column_name == "rows" {
		column_name = "*"
	}
	for spec, index in result.aggregates {
		if spec.kind == partial.kind && spec.column_name == column_name {
			if spec.kind != .Percentile || spec.percentile == partial.percentile {
				return Sort_Term{
					target_kind = .Aggregate,
					result_index = index,
				}, .None
			}
		}
	}
	return {}, .Sort_Target_Not_Found
}

sort_group_results :: proc(
	result: ^Group_Result_Set,
	terms: []Sort_Term,
) -> snout_core.Error {
	if len(terms) > MAX_SORT_TERMS {
		return .Too_Many_Sort_Terms
	}
	for term, index in terms {
		limit := len(result.group_columns)
		if term.target_kind == .Aggregate {
			limit = len(result.aggregates)
		}
		if term.result_index < 0 || term.result_index >= limit {
			return .Sort_Target_Not_Found
		}
		for previous in terms[:index] {
			if term.target_kind == previous.target_kind &&
			   term.result_index == previous.result_index {
				return .Duplicate_Sort_Target
			}
		}
	}
	if len(result.groups) < 2 {
		return .None
	}
	sort_context := Sort_Context{groups = result.groups, terms = terms}
	sort.sort(sort.Interface{
		collection = &sort_context,
		len = sort_context_len,
		less = sort_context_less,
		swap = sort_context_swap,
	})
	return .None
}

sort_context_len :: proc(interface: sort.Interface) -> int {
	sort_context := (^Sort_Context)(interface.collection)
	return len(sort_context.groups)
}

sort_context_less :: proc(interface: sort.Interface, left, right: int) -> bool {
	sort_context := (^Sort_Context)(interface.collection)
	return compare_with_sort_terms(
		sort_context.groups[left],
		sort_context.groups[right],
		sort_context.terms,
	) < 0
}

sort_context_swap :: proc(interface: sort.Interface, left, right: int) {
	sort_context := (^Sort_Context)(interface.collection)
	sort_context.groups[left], sort_context.groups[right] =
		sort_context.groups[right], sort_context.groups[left]
}

compare_with_sort_terms :: proc(
	left, right: Group_Result,
	terms: []Sort_Term,
) -> int {
	for term in terms {
		comparison := 0
		switch term.target_kind {
		case .Group_Column:
			comparison = compare_group_keys_directional(
				left.keys[term.result_index],
				right.keys[term.result_index],
				term.direction,
			)
		case .Aggregate:
			comparison = compare_aggregate_values(
				left.values[term.result_index],
				right.values[term.result_index],
				term.direction,
			)
		}
		if comparison != 0 {
			return comparison
		}
	}
	return compare_group_results(left, right)
}

compare_group_keys_directional :: proc(
	left, right: Group_Key,
	direction: Sort_Direction,
) -> int {
	comparison := compare_group_keys(left, right)
	return -comparison if direction == .Descending else comparison
}

compare_aggregate_values :: proc(
	left, right: Aggregate_Value,
	direction: Sort_Direction,
) -> int {
	if !left.valid {
		if !right.valid {
			return 0
		}
		return -1 if direction == .Ascending else 1
	}
	if !right.valid {
		return 1 if direction == .Ascending else -1
	}
	comparison := 0
	switch left.kind {
	case .Int64:
		comparison =
			-1 if left.int_value < right.int_value else
			1 if left.int_value > right.int_value else
			0
	case .Float64:
		comparison =
			-1 if left.float_value < right.float_value else
			1 if left.float_value > right.float_value else
			0
	case .String, .Timestamp, .Bool, .Unknown:
	}
	return -comparison if direction == .Descending else comparison
}

split_aggregate_expression :: proc(text: string) -> (string, string, bool) {
	for character, index in text {
		if character == '=' && index > 0 && index < len(text)-1 {
			return text[:index], text[index+1:], true
		}
	}
	return "", "", false
}
