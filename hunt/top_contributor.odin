package hunt

import "base:runtime"
import "core:fmt"
import "core:slice"
import "core:strings"
import snout_core "../core"
import "../sniff"

TOP_CONTRIBUTOR_SHARE :: 0.40
TOP_CONTRIBUTOR_MAX_CARD :: 1000

// run_top_contributor emits one finding per (dimension, dominant value) pair,
// not per (dimension, metric) pair. When the same dimension value dominates
// several metrics (e.g. roaming=false covers 86% of seven metrics) we collapse
// them into a single finding with the strongest metric as the primary and the
// rest listed as `extra_metrics`. Otherwise this analyzer floods the report
// with near-identical rows that all repeat the same story.
run_top_contributor :: proc(
	pool: ^[dynamic]Finding,
	candidates: Candidate_Set,
	table: ^snout_core.Table,
	config: Hunt_Config,
	allocator := context.allocator,
) {
	for dim_cand in candidates.dimensions {
		dim := dim_cand.profile
		if dim.cardinality.exact && dim.cardinality.distinct_count > TOP_CONTRIBUTOR_MAX_CARD {
			continue
		}
		emit_consolidated_for_dim(pool, dim, candidates.metrics, table, config, allocator)
	}
}

// Per-metric dominance summary for a single dimension value.
@(private="file")
Dominance :: struct {
	metric_name:  string,
	metric_ref:   ^sniff.Column_Profile,
	share:        f64,
	contribution: f64,
	total:        f64,
	row_count:    int,
}

@(private="file")
emit_consolidated_for_dim :: proc(
	pool: ^[dynamic]Finding,
	dim: ^sniff.Column_Profile,
	metrics: []Candidate,
	table: ^snout_core.Table,
	config: Hunt_Config,
	allocator := context.allocator,
) {
	dim_col, ok := snout_core.get_column(table, dim.name)
	if !ok { return }

	// For each metric: find the value that dominates it (if any) and record
	// the dominance under a map keyed by the dominant value.
	// Map: dominant_value → []Dominance (one per metric this value dominates).
	by_value := make(map[string][dynamic]Dominance, 0, context.temp_allocator)
	defer {
		for _, list in by_value { delete(list) }
		delete(by_value)
	}

	for met_cand in metrics {
		met := met_cand.profile
		if met.kind != .Int64 && met.kind != .Float64 { continue }

		met_col, found := snout_core.get_column(table, met.name)
		if !found { continue }

		dominant_value, dominance, has := dominant_metric_value(dim_col, met_col, met, allocator)
		if !has { continue }
		if dominance.share < TOP_CONTRIBUTOR_SHARE { continue }
		if dominance.row_count < config.min_rows_per_finding { continue }

		list, exists := by_value[dominant_value]
		if !exists {
			list = make([dynamic]Dominance, 0, 4, context.temp_allocator)
		}
		append(&list, dominance)
		by_value[dominant_value] = list
	}

	if len(by_value) == 0 { return }

	// Iterate values in deterministic order.
	values := make([dynamic]string, 0, len(by_value), context.temp_allocator)
	for v in by_value { append(&values, v) }
	slice.sort(values[:])

	for value in values {
		dominances := by_value[value]
		if len(dominances) == 0 { continue }

		// Pick the strongest dominance as the primary metric.
		slice.sort_by(dominances[:], dominance_desc)
		primary := dominances[0]

		// Score is driven by the strongest metric; we score once per (dim, value)
		// regardless of how many metrics are covered.
		effect   := primary.share * 100.0
		coverage := f64(primary.row_count) / f64(table.row_count) * 100.0
		conf     := confidence_score(primary.row_count)
		novelty  := f64(75)
		// Small bonus when the same (dim, value) dominates multiple metrics —
		// it's a stronger signal than dominating one in isolation.
		if len(dominances) >= 3 {
			novelty += 10
		}
		score := compose_score(effect, coverage, conf, novelty)
		if score < config.min_score { continue }

		value_clone, _ := strings.clone(value, allocator)
		dim_clone,   _ := strings.clone(dim.name, allocator)
		met_clone,   _ := strings.clone(primary.metric_name, allocator)

		// Build extra_metrics (skip the primary, but keep stable order).
		extras := make([dynamic]Metric_Share, 0, max(0, len(dominances) - 1), allocator)
		for i in 1..<len(dominances) {
			d := dominances[i]
			mc, _ := strings.clone(d.metric_name, allocator)
			append(&extras, Metric_Share{metric = mc, share = d.share})
		}

		title := build_top_contributor_title(
			dim.name, value, primary.share, primary.metric_name, len(dominances),
			allocator,
		)
		summary := build_top_contributor_summary(
			value, primary, dominances[:], allocator,
		)

		sum_arg  := strings.concatenate({"sum=", primary.metric_name}, context.temp_allocator)
		sort_key := strings.concatenate({"sum=", primary.metric_name}, context.temp_allocator)
		repro := query_repro(
			config, dim.name,
			[]string{sum_arg, "count=rows"},
			[]Where_Clause{},
			[]Sort_Clause{{key = sort_key, dir = .Desc}},
			10, allocator,
		)
		dedup := fmt.aprintf("top_contributor:%s:%s", dim.name, value, allocator = allocator)

		append(pool, Finding{
			type               = .Top_Contributor,
			score              = score,
			confidence         = confidence_from_rows(primary.row_count),
			title              = title,
			summary            = summary,
			reproduce_command  = repro,
			reproduce_fidelity = .Exact,
			dedup_key          = dedup,
			novelty            = novelty,
			evidence = Top_Contributor_Evidence{
				dimension     = dim_clone,
				value         = value_clone,
				metric        = met_clone,
				contribution  = primary.contribution,
				total         = primary.total,
				share         = primary.share,
				extra_metrics = extras[:],
			},
		})
	}
}

@(private="file")
dominant_metric_value :: proc(
	dim_col, met_col: ^snout_core.Column,
	met: ^sniff.Column_Profile,
	allocator: runtime.Allocator,
) -> (string, Dominance, bool) {
	sums   := make(map[string]f64, 0, context.temp_allocator)
	counts := make(map[string]int, 0, context.temp_allocator)
	defer delete(sums)
	defer delete(counts)

	total := f64(0)
	n := len(met_col.int64s) if met_col.kind == .Int64 else len(met_col.float64s)
	for i in 0..<n {
		if dim_col.nullable && dim_col.null_mask[i] { continue }
		if met_col.nullable && met_col.null_mask[i] { continue }

		key := value_string_local(dim_col, i)
		v := f64(0)
		#partial switch met_col.kind {
		case .Int64:   v = f64(met_col.int64s[i])
		case .Float64: v = met_col.float64s[i]
		}
		sums[key]   = sums[key]   + v
		counts[key] = counts[key] + 1
		total += v
	}
	if total <= 0 || len(sums) == 0 {
		return "", {}, false
	}

	// Deterministic winner selection.
	keys := make([dynamic]string, 0, len(sums), context.temp_allocator)
	for k in sums { append(&keys, k) }
	slice.sort(keys[:])

	best_key   := ""
	best_value := f64(0)
	best_count := 0
	for k in keys {
		v := sums[k]
		if v > best_value {
			best_value = v
			best_key   = k
			best_count = counts[k]
		}
	}
	if best_key == "" {
		return "", {}, false
	}

	d := Dominance{
		metric_name  = met.name,
		metric_ref   = met,
		share        = best_value / total,
		contribution = best_value,
		total        = total,
		row_count    = best_count,
	}
	_ = allocator
	return best_key, d, true
}

@(private="file")
dominance_desc :: proc(a, b: Dominance) -> bool {
	if a.share != b.share { return a.share > b.share }
	return a.metric_name < b.metric_name
}

@(private="file")
build_top_contributor_title :: proc(
	dim, value: string,
	share: f64,
	primary_metric: string,
	num_metrics: int,
	allocator := context.allocator,
) -> string {
	if num_metrics <= 1 {
		return fmt.aprintf(
			"%s=%s accounts for %.0f%% of total %s",
			dim, value, share * 100.0, primary_metric,
			allocator = allocator,
		)
	}
	return fmt.aprintf(
		"%s=%s dominates %d metrics (%.0f%% of %s and %d more)",
		dim, value, num_metrics, share * 100.0, primary_metric, num_metrics - 1,
		allocator = allocator,
	)
}

@(private="file")
build_top_contributor_summary :: proc(
	value: string,
	primary: Dominance,
	all: []Dominance,
	allocator := context.allocator,
) -> string {
	if len(all) <= 1 {
		return fmt.aprintf(
			"%s contributed %.2f of %.2f (%.0f%%) across %d rows.",
			value, primary.contribution, primary.total,
			primary.share * 100.0, primary.row_count,
			allocator = allocator,
		)
	}
	// Build "metric1 (X%), metric2 (Y%), …" capped to avoid runaway lines.
	b := strings.builder_make(context.temp_allocator)
	max_inline := min(len(all), 6)
	for i in 0..<max_inline {
		if i > 0 { strings.write_string(&b, ", ") }
		strings.write_string(&b, all[i].metric_name)
		strings.write_string(&b, fmt.tprintf(" (%.0f%%)", all[i].share * 100.0))
	}
	if len(all) > max_inline {
		strings.write_string(&b, fmt.tprintf(", +%d more", len(all) - max_inline))
	}
	return fmt.aprintf(
		"%s dominates: %s. Across %d rows.",
		value, strings.to_string(b), primary.row_count,
		allocator = allocator,
	)
}

@(private="file")
value_string_local :: proc(col: ^snout_core.Column, i: int) -> string {
	#partial switch col.kind {
	case .String, .Timestamp:
		return col.strings[i]
	case .Int64:
		return fmt.tprintf("%d", col.int64s[i])
	case .Bool:
		if col.bools[i] { return "true" }
		return "false"
	}
	return ""
}
