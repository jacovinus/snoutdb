package main

import "core:fmt"
import "core:time"
import query "../query"

ONE_SORT_TERM := [?]query.Sort_Term{
	{
		target_kind = .Aggregate,
		result_index = 0,
		direction = .Descending,
	},
}

THREE_SORT_TERMS := [?]query.Sort_Term{
	{
		target_kind = .Aggregate,
		result_index = 0,
		direction = .Descending,
	},
	{
		target_kind = .Aggregate,
		result_index = 1,
		direction = .Descending,
	},
	{
		target_kind = .Group_Column,
		result_index = 0,
		direction = .Ascending,
	},
}

main :: proc() {
	run_sort_benchmark("100 groups / 1 term", 100, ONE_SORT_TERM[:])
	run_sort_benchmark("10000 groups / 1 term", 10_000, ONE_SORT_TERM[:])
	run_sort_benchmark("10000 groups / 3 terms", 10_000, THREE_SORT_TERMS[:])
	run_sort_benchmark("10000 groups / default key", 10_000, nil)
}

run_sort_benchmark :: proc(label: string, group_count: int, terms: []query.Sort_Term) {
	result, keys, values := make_benchmark_result(group_count)
	defer delete(result.groups)
	defer delete(keys)
	defer delete(values)

	start := time.tick_now()
	err := query.sort_group_results(&result, terms)
	elapsed := time.tick_since(start)
	if err != .None {
		fmt.printfln("%s: error=%v", label, err)
		return
	}
	fmt.printfln(
		"%s: groups=%d terms=%d elapsed=%v",
		label,
		group_count,
		len(terms),
		elapsed,
	)
}

make_benchmark_result :: proc(
	group_count: int,
) -> (query.Group_Result_Set, []query.Group_Key, []query.Aggregate_Value) {
	result := query.Group_Result_Set{
		group_columns = []string{"region", "carrier"},
		aggregates = []query.Aggregate_Spec{
			{kind = .Avg, column_name = "mos"},
			{kind = .Count, column_name = "*"},
		},
	}
	result.groups = make([]query.Group_Result, group_count)
	keys := make([]query.Group_Key, group_count*2)
	values := make([]query.Aggregate_Value, group_count*2)
	for index in 0..<group_count {
		result.groups[index].keys = keys[index*2:index*2+2]
		result.groups[index].values = values[index*2:index*2+2]
		result.groups[index].keys[0] = query.Group_Key{
			kind = .Int64,
			int_value = i64((index*7919)%group_count),
		}
		result.groups[index].keys[1] = query.Group_Key{
			kind = .Int64,
			int_value = i64((index*3571)%997),
		}
		result.groups[index].values[0] = query.Aggregate_Value{
			valid = true,
			kind = .Float64,
			float_value = f64((index*43)%1000)/100,
		}
		result.groups[index].values[1] = query.Aggregate_Value{
			valid = true,
			kind = .Int64,
			int_value = i64((index*17)%500),
		}
	}
	return result, keys, values
}
