package merge

import "base:runtime"
import "core:strings"
import snout_core "../core"
import query "../query"

// rollup_tables merges N source tables and applies a group-by aggregation,
// returning a flat Table with one row per group. The caller owns the result
// and must call snout_core.free_table.
rollup_tables :: proc(
	sources: []^snout_core.Table,
	output_name: string,
	group_query: query.Group_Query,
	allocator := context.allocator,
) -> (snout_core.Table, snout_core.Error) {
	if len(sources) == 0 {
		return {}, .Empty_Input
	}

	merged, merge_err := merge_sources(sources, output_name, context.temp_allocator)
	if merge_err != .None {
		return {}, merge_err
	}
	defer snout_core.free_table(&merged)

	result, query_err := query.execute_group_query(&merged, group_query, context.temp_allocator)
	if query_err != .None {
		return {}, query_err
	}
	defer query.free_group_result_set(&result)

	return result_to_table(&result, &merged, output_name, allocator)
}

// result_to_table materializes a Group_Result_Set as a core.Table.
// source is consulted for column type information when the result has no groups.
result_to_table :: proc(
	result: ^query.Group_Result_Set,
	source: ^snout_core.Table,
	name: string,
	allocator: runtime.Allocator,
) -> (snout_core.Table, snout_core.Error) {
	group_count := len(result.group_columns)
	agg_count   := len(result.aggregates)
	row_count   := len(result.groups)

	out: snout_core.Table
	out.allocator = allocator
	out.row_count = row_count
	out.name      = strings.clone(name, allocator)

	failed := true
	defer if failed { snout_core.free_table(&out) }

	alloc_err: runtime.Allocator_Error
	out.columns, alloc_err = make([]snout_core.Column, group_count + agg_count, allocator)
	if alloc_err != nil {
		return {}, .Out_Of_Memory
	}

	// ---- group key columns -------------------------------------------------
	for i in 0 ..< group_count {
		col := &out.columns[i]
		col.name = strings.clone(result.group_columns[i], allocator)

		if row_count > 0 {
			col.kind = result.groups[0].keys[i].kind
		} else if src_col, found := snout_core.get_column(source, result.group_columns[i]);
		   found {
			col.kind = src_col.kind
		} else {
			col.kind = .String
		}

		col.nullable = false
		for &group in result.groups {
			if group.keys[i].is_null {
				col.nullable = true
				break
			}
		}

		col.null_mask, _ = make([]bool, row_count, allocator)
		if err := alloc_column_data(col, row_count, allocator); err != .None {
			return {}, err
		}

		for row_idx in 0 ..< row_count {
			key := result.groups[row_idx].keys[i]
			if key.is_null {
				col.null_mask[row_idx] = true
			} else {
				switch col.kind {
				case .String, .Timestamp:
					col.strings[row_idx] = strings.clone(key.string_value, allocator)
				case .Int64:
					col.int64s[row_idx] = key.int_value
				case .Bool:
					col.bools[row_idx] = key.bool_value
				case .Float64, .Unknown:
					// Float64 is rejected by execute_group_query before we reach here.
				}
			}
		}
	}

	// ---- aggregate columns -------------------------------------------------
	for i in 0 ..< agg_count {
		col := &out.columns[group_count + i]
		spec := result.aggregates[i]
		col.name = strings.clone(query.aggregate_column_name(spec), allocator)

		if row_count > 0 {
			col.kind = result.groups[0].values[i].kind
		} else {
			col.kind = infer_agg_kind(spec, source)
		}

		col.nullable = false
		for &group in result.groups {
			if !group.values[i].valid {
				col.nullable = true
				break
			}
		}

		col.null_mask, _ = make([]bool, row_count, allocator)
		if err := alloc_column_data(col, row_count, allocator); err != .None {
			return {}, err
		}

		for row_idx in 0 ..< row_count {
			agg_val := result.groups[row_idx].values[i]
			if !agg_val.valid {
				col.null_mask[row_idx] = true
			} else {
				switch col.kind {
				case .Int64:
					col.int64s[row_idx] = agg_val.int_value
				case .Float64:
					col.float64s[row_idx] = agg_val.float_value
				case .String, .Timestamp, .Bool, .Unknown:
					// Aggregate results are Int64 or Float64 only.
				}
			}
		}
	}

	failed = false
	return out, .None
}

// infer_agg_kind returns the Column_Type for an aggregate column when there are
// no result groups (Aggregate_Value.kind is unavailable in that case).
infer_agg_kind :: proc(
	spec: query.Aggregate_Spec,
	source: ^snout_core.Table,
) -> snout_core.Column_Type {
	switch spec.kind {
	case .Count, .Count_Distinct:
		return .Int64
	case .Avg, .Percentile, .Error_Rate:
		return .Float64
	case .Sum, .Min, .Max:
		if src_col, found := snout_core.get_column(source, spec.column_name); found {
			if src_col.kind == .Int64 {
				return .Int64
			}
		}
		return .Float64
	}
	return .Float64
}
