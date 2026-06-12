package query

import "base:runtime"
import "core:fmt"
import snout_core "../core"

MAX_FILTERS :: 32
MAX_GROUP_COLUMNS :: 8
MAX_AGGREGATES :: 16
MAX_SORT_TERMS :: 16
MAX_RESULT_LIMIT :: 1_000_000
DEFAULT_MAX_GROUPS :: 1_000_000

Aggregate_Kind :: enum {
	Count,
	Sum,
	Avg,
	Min,
	Max,
	Percentile,      // nearest-rank; spec.percentile holds the quantile in [0.0, 1.0)
	Error_Rate,      // count(true) / count(non-null) for Bool columns
	Count_Distinct,  // number of unique non-null values
}

Sort_Direction :: enum {
	Ascending,
	Descending,
}

Sort_Target_Kind :: enum {
	Group_Column,
	Aggregate,
}

Sort_Term :: struct {
	target_kind:  Sort_Target_Kind,
	result_index: int,
	direction:    Sort_Direction,
}

Filter_Operator :: enum {
	Equal,
	Not_Equal,
	Less,
	Less_Equal,
	Greater,
	Greater_Equal,
	Contains,
	Not_Contains,
	IContains,
	Is_Null,
	Is_Not_Null,
}

Filter_Value :: struct {
	kind:         snout_core.Column_Type,
	string_value: string,
	int_value:    i64,
	float_value:  f64,
	bool_value:   bool,
}

Filter_Predicate :: struct {
	column_name: string,
	operator:    Filter_Operator,
	value:       Filter_Value,
}

Aggregate_Spec :: struct {
	kind:        Aggregate_Kind,
	column_name: string,
	percentile:  f64, // quantile in [0.0, 1.0); only used when kind == .Percentile
}

Group_Query :: struct {
	group_columns: []string,
	aggregates:    []Aggregate_Spec,
	filters:       []Filter_Predicate,
	max_groups:    int,
}

Group_Key :: struct {
	kind:         snout_core.Column_Type,
	is_null:      bool,
	string_value: string,
	int_value:    i64,
	bool_value:   bool,
}

Aggregate_Value :: struct {
	valid:       bool,
	kind:        snout_core.Column_Type,
	count:       int,
	int_value:   i64,
	float_value: f64,
}

Group_Result :: struct {
	keys:      []Group_Key,
	row_count: int,
	values:    []Aggregate_Value,
}

Group_Result_Set :: struct {
	group_columns: []string,
	aggregates:    []Aggregate_Spec,
	filter_count:  int,
	selected_rows: int,
	groups:        []Group_Result,
	allocator:     runtime.Allocator,
}

free_group_result_set :: proc(result: ^Group_Result_Set) {
	if result == nil {
		return
	}
	allocator := result.allocator
	for &group in result.groups {
		for &key in group.keys {
			delete(key.string_value, allocator)
		}
		delete(group.keys, allocator)
		delete(group.values, allocator)
	}
	for column_name in result.group_columns {
		delete(column_name, allocator)
	}
	for &aggregate in result.aggregates {
		delete(aggregate.column_name, allocator)
	}
	delete(result.groups, allocator)
	delete(result.group_columns, allocator)
	delete(result.aggregates, allocator)
	result^ = {}
}

aggregate_name :: proc(spec: Aggregate_Spec, allocator := context.temp_allocator) -> string {
	switch spec.kind {
	case .Count:      return "count"
	case .Sum:        return "sum"
	case .Avg:        return "avg"
	case .Min:        return "min"
	case .Max:        return "max"
	case .Error_Rate:      return "error_rate"
	case .Count_Distinct:  return "count_distinct"
	case .Percentile:
		pct := int(spec.percentile * 100 + 0.5)
		return fmt.aprintf("p%d", pct, allocator=allocator)
	}
	return "unknown"
}

// aggregate_column_name returns a valid identifier for use as a saved column name.
// Examples: count=rows → "count", avg=jitter_ms → "avg_jitter_ms", p95=mos → "p95_mos".
aggregate_column_name :: proc(spec: Aggregate_Spec, allocator := context.temp_allocator) -> string {
	fn := aggregate_name(spec, allocator)
	if spec.kind == .Count {
		return "count"
	}
	return fmt.aprintf("%s_%s", fn, spec.column_name, allocator=allocator)
}
