package exec

import "core:slice"
import snout_core "../core"

Numeric_Stats :: struct {
	kind:       snout_core.Column_Type,
	count:      int,
	null_count: int,
	sum:        f64,
	avg:        f64,
	min:        f64,
	max:        f64,
	p50:        f64,
	p95:        f64,
	p99:        f64,
}

numeric_stats :: proc(
	table: ^snout_core.Table,
	column_name: string,
) -> (Numeric_Stats, snout_core.Error) {
	column, found := snout_core.get_column(table, column_name)
	if !found {
		return {}, .Column_Not_Found
	}
	if column.kind != .Int64 && column.kind != .Float64 {
		return {}, .Wrong_Column_Type
	}

	stats := Numeric_Stats{
		kind = column.kind,
	}

	#partial switch column.kind {
	case .Int64:
		for value, index in column.int64s {
			if column.null_mask[index] {
				stats.null_count += 1
				continue
			}
			add_numeric_value(&stats, f64(value))
		}
	case .Float64:
		for value, index in column.float64s {
			if column.null_mask[index] {
				stats.null_count += 1
				continue
			}
			add_numeric_value(&stats, value)
		}
	}

	if stats.count == 0 {
		return {}, .Wrong_Column_Type
	}
	stats.avg = stats.sum / f64(stats.count)

	values := make([]f64, stats.count, context.temp_allocator)
	vi := 0
	#partial switch column.kind {
	case .Int64:
		for value, index in column.int64s {
			if !column.null_mask[index] {
				values[vi] = f64(value)
				vi += 1
			}
		}
	case .Float64:
		for value, index in column.float64s {
			if !column.null_mask[index] {
				values[vi] = value
				vi += 1
			}
		}
	}
	slice.sort(values)
	stats.p50 = percentile_nearest_rank(values, 0.50)
	stats.p95 = percentile_nearest_rank(values, 0.95)
	stats.p99 = percentile_nearest_rank(values, 0.99)

	return stats, .None
}

percentile_nearest_rank :: proc(sorted: []f64, p: f64) -> f64 {
	n := len(sorted)
	if n == 0 {
		return 0
	}
	return sorted[int(p * f64(n - 1))]
}

add_numeric_value :: proc(stats: ^Numeric_Stats, value: f64) {
	if stats.count == 0 {
		stats.min = value
		stats.max = value
	} else {
		if value < stats.min {
			stats.min = value
		}
		if value > stats.max {
			stats.max = value
		}
	}
	stats.sum += value
	stats.count += 1
}

sum_i64 :: proc(
	table: ^snout_core.Table,
	column_name: string,
) -> (i64, snout_core.Error) {
	column, found := snout_core.get_column(table, column_name)
	if !found {
		return 0, .Column_Not_Found
	}
	if column.kind != .Int64 {
		return 0, .Wrong_Column_Type
	}

	total: i64
	for value, index in column.int64s {
		if !column.null_mask[index] {
			total += value
		}
	}
	return total, .None
}

avg_f64_or_i64 :: proc(
	table: ^snout_core.Table,
	column_name: string,
) -> (f64, snout_core.Error) {
	stats, err := numeric_stats(table, column_name)
	if err != .None {
		return 0, err
	}
	return stats.avg, .None
}
