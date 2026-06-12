package hunt

import "core:fmt"
import "core:slice"
import "core:strings"
import snout_core "../core"
import "../sniff"

TOP_CONTRIBUTOR_SHARE :: 0.40
TOP_CONTRIBUTOR_MAX_CARD :: 1000

// run_top_contributor pairs each (dimension, metric) candidate and detects when
// one dimension value contributes >= 40% of the metric sum.
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
		for met_cand in candidates.metrics {
			emit_top_contributor_for(pool, dim, met_cand.profile, table, config, allocator)
		}
	}
}

@(private="file")
emit_top_contributor_for :: proc(
	pool: ^[dynamic]Finding,
	dim: ^sniff.Column_Profile,
	met: ^sniff.Column_Profile,
	table: ^snout_core.Table,
	config: Hunt_Config,
	allocator := context.allocator,
) {
	if met.kind != .Int64 && met.kind != .Float64 { return }

	dim_col, ok := snout_core.get_column(table, dim.name)
	if !ok { return }
	met_col, ok2 := snout_core.get_column(table, met.name)
	if !ok2 { return }

	sums := make(map[string]f64, 0, context.temp_allocator)
	counts := make(map[string]int, 0, context.temp_allocator)
	defer delete(sums)
	defer delete(counts)

	total := f64(0)
	for i in 0..<table.row_count {
		if dim_col.nullable && dim_col.null_mask[i] { continue }
		if met_col.nullable && met_col.null_mask[i] { continue }

		key := value_string_local(dim_col, i)
		v := f64(0)
		#partial switch met_col.kind {
		case .Int64:   v = f64(met_col.int64s[i])
		case .Float64: v = met_col.float64s[i]
		}
		sums[key] = sums[key] + v
		counts[key] = counts[key] + 1
		total += v
	}
	if total <= 0 || len(sums) == 0 { return }

	// Sort keys to make winner selection deterministic on ties.
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
	if best_key == "" { return }
	if best_count < config.min_rows_per_finding { return }

	share := best_value / total
	if share < TOP_CONTRIBUTOR_SHARE { return }

	effect   := share * 100.0
	coverage := f64(best_count) / f64(table.row_count) * 100.0
	conf     := confidence_score(best_count)
	novelty  := f64(75)
	score    := compose_score(effect, coverage, conf, novelty)
	if score < config.min_score { return }

	value_clone, _ := strings.clone(best_key, allocator)
	dim_clone,   _ := strings.clone(dim.name, allocator)
	met_clone,   _ := strings.clone(met.name, allocator)

	title := fmt.aprintf(
		"%s=%s accounts for %.0f%% of total %s",
		dim.name, best_key, share * 100.0, met.name,
		allocator = allocator,
	)
	summary := fmt.aprintf(
		"%s=%s contributed %.2f of %.2f (%.0f%%) across %d rows.",
		dim.name, best_key, best_value, total, share * 100.0, best_count,
		allocator = allocator,
	)
	sum_arg := strings.concatenate({"sum=", met.name}, context.temp_allocator)
	sort_key := strings.concatenate({"sum=", met.name}, context.temp_allocator)
	repro := query_repro(
		config, dim.name,
		[]string{sum_arg, "count=rows"},
		[]Where_Clause{},
		[]Sort_Clause{{key = sort_key, dir = .Desc}},
		10, allocator,
	)
	dedup := fmt.aprintf("top_contributor:%s:%s:%s", dim.name, met.name, best_key, allocator = allocator)

	append(pool, Finding{
		type               = .Top_Contributor,
		score              = score,
		confidence         = confidence_from_rows(best_count),
		title              = title,
		summary            = summary,
		reproduce_command  = repro,
		reproduce_fidelity = .Exact,
		dedup_key          = dedup,
		novelty            = novelty,
		evidence = Top_Contributor_Evidence{
			dimension    = dim_clone,
			value        = value_clone,
			metric       = met_clone,
			contribution = best_value,
			total        = total,
			share        = share,
		},
	})
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
