package hunt

import "core:fmt"
import "core:slice"
import "core:strings"
import snout_core "../core"
import "../query"
import "../sniff"

ERROR_HOTSPOT_RATIO_THRESHOLD :: 2.0
ERROR_HOTSPOT_MIN_ERRORS      :: 20

// run_error_hotspot detects dimensions that concentrate errors disproportionately.
// For each detected error column (boolean error/failed, integer status >= 400,
// string level=error/fatal), it groups by each remaining dimension and emits a
// finding when one segment's error rate is >= 2x the overall baseline.
run_error_hotspot :: proc(
	pool: ^[dynamic]Finding,
	candidates: Candidate_Set,
	table: ^snout_core.Table,
	config: Hunt_Config,
	allocator := context.allocator,
) {
	if len(candidates.errors) == 0 { return }
	if len(candidates.dimensions) == 0 { return }

	for err_cand in candidates.errors {
		err_profile := err_cand.profile

		// Compute baseline error rate over the whole table.
		baseline, ok := compute_baseline_error_rate(table, err_profile)
		if !ok || baseline.total_rows < ERROR_HOTSPOT_MIN_ERRORS { continue }
		if baseline.error_rows < ERROR_HOTSPOT_MIN_ERRORS { continue }
		if baseline.rate <= 0 { continue }

		for dim_cand in candidates.dimensions {
			if dim_cand.profile == err_profile { continue }
			emit_error_hotspot_for(
				pool, table, err_profile, dim_cand.profile,
				baseline, config, allocator,
			)
		}
	}
}

@(private="file")
Baseline_Error :: struct {
	error_rows: int,
	total_rows: int,
	rate:       f64,
}

@(private="file")
compute_baseline_error_rate :: proc(
	table: ^snout_core.Table,
	err: ^sniff.Column_Profile,
) -> (Baseline_Error, bool) {
	col, found := snout_core.get_column(table, err.name)
	if !found { return {}, false }

	errors := 0
	total  := 0

	#partial switch col.kind {
	case .Bool:
		for v, i in col.bools {
			if col.nullable && col.null_mask[i] { continue }
			total += 1
			if v { errors += 1 }
		}
	case .Int64:
		// Status code semantics: 4xx and 5xx count as errors.
		for v, i in col.int64s {
			if col.nullable && col.null_mask[i] { continue }
			total += 1
			if v >= 400 && v <= 599 { errors += 1 }
		}
	case .String:
		// level/severity: error|fatal|critical map to errors. Use case-insensitive
		// equality to avoid allocating a lowercased copy per row.
		for v, i in col.strings {
			if col.nullable && col.null_mask[i] { continue }
			total += 1
			if level_is_error(v) { errors += 1 }
		}
	case:
		return {}, false
	}

	if total == 0 { return {}, false }
	return Baseline_Error{
		error_rows = errors,
		total_rows = total,
		rate       = f64(errors) / f64(total),
	}, true
}

@(private="file")
emit_error_hotspot_for :: proc(
	pool: ^[dynamic]Finding,
	table: ^snout_core.Table,
	err: ^sniff.Column_Profile,
	dim: ^sniff.Column_Profile,
	baseline: Baseline_Error,
	config: Hunt_Config,
	allocator := context.allocator,
) {
	if dim.kind != .String && dim.kind != .Int64 && dim.kind != .Bool && dim.kind != .Timestamp {
		return
	}
	if dim.cardinality.exact && dim.cardinality.distinct_count > 1000 { return }

	err_col, ok := snout_core.get_column(table, err.name)
	if !ok { return }
	dim_col, ok2 := snout_core.get_column(table, dim.name)
	if !ok2 { return }

	// Group rows by dim value, counting (error_rows, total_rows) per segment.
	// We walk rows directly rather than running a Group_Query, because Group_Query
	// only supports its own aggregate kinds; bespoke counting is simpler here.
	segments := make(map[string]Baseline_Error, 0, context.temp_allocator)
	defer delete(segments)

	n := table.row_count
	for i in 0..<n {
		if dim_col.nullable && dim_col.null_mask[i] { continue }
		if err_col.nullable && err_col.null_mask[i] { continue }

		key := value_string(dim_col, i)
		entry := segments[key]
		entry.total_rows += 1
		if row_is_error(err_col, i) { entry.error_rows += 1 }
		segments[key] = entry
	}

	// Pick the segment with the strongest signal. Sort keys first so two
	// segments with equal ratio always resolve to the same winner.
	segment_keys := make([dynamic]string, 0, len(segments), context.temp_allocator)
	for k in segments { append(&segment_keys, k) }
	slice.sort(segment_keys[:])

	best_key   := ""
	best       := Baseline_Error{}
	best_ratio := 0.0
	for k in segment_keys {
		v := segments[k]
		if v.total_rows < ERROR_HOTSPOT_MIN_ERRORS { continue }
		if v.error_rows < ERROR_HOTSPOT_MIN_ERRORS { continue }
		rate  := f64(v.error_rows) / f64(v.total_rows)
		ratio := rate / baseline.rate
		if ratio > best_ratio {
			best_ratio = ratio
			best_key   = k
			best       = Baseline_Error{
				error_rows = v.error_rows,
				total_rows = v.total_rows,
				rate       = rate,
			}
		}
	}

	if best_key == "" { return }
	if best_ratio < ERROR_HOTSPOT_RATIO_THRESHOLD { return }

	value_clone, _ := strings.clone(best_key, allocator)
	dim_clone,   _ := strings.clone(dim.name, allocator)
	err_clone,   _ := strings.clone(err.name, allocator)

	effect := best_ratio * 20.0
	if effect > 100.0 { effect = 100.0 }
	cov  := coverage_score(best.error_rows, baseline.error_rows)
	conf := confidence_score(best.error_rows)
	novelty := f64(90)
	score := compose_score(effect, cov, conf, novelty)

	if score < config.min_score {
		delete(value_clone, allocator)
		delete(dim_clone, allocator)
		delete(err_clone, allocator)
		return
	}

	share_pct := f64(best.error_rows) / f64(baseline.error_rows) * 100.0
	title := fmt.aprintf(
		"%.0f%% of %s errors come from %s=%s",
		share_pct, err.name, dim.name, best_key,
		allocator = allocator,
	)
	summary := fmt.aprintf(
		"%s=%s has a %.1fx higher error rate (%.1f%% vs baseline %.1f%%).",
		dim.name, best_key, best_ratio,
		best.rate * 100.0, baseline.rate * 100.0,
		allocator = allocator,
	)
	repro := build_error_hotspot_repro(config, dim.name, best_key, err, allocator)
	dedup := fmt.aprintf("error_hotspot:%s:%s:%s", err.name, dim.name, best_key, allocator = allocator)

	append(pool, Finding{
		type               = .Error_Hotspot,
		score              = score,
		confidence         = confidence_from_rows(best.error_rows),
		title              = title,
		summary            = summary,
		reproduce_command  = repro,
		reproduce_fidelity = .Exact,
		dedup_key          = dedup,
		novelty            = novelty,
		evidence = Error_Hotspot_Evidence{
			dimension       = dim_clone,
			value           = value_clone,
			error_column    = err_clone,
			matching_errors = best.error_rows,
			total_errors    = baseline.error_rows,
			segment_rate    = best.rate,
			baseline_rate   = baseline.rate,
			ratio           = best_ratio,
		},
	})
}

@(private="file")
row_is_error :: proc(col: ^snout_core.Column, i: int) -> bool {
	#partial switch col.kind {
	case .Bool:
		return col.bools[i]
	case .Int64:
		v := col.int64s[i]
		return v >= 400 && v <= 599
	case .String:
		return level_is_error(col.strings[i])
	}
	return false
}

// level_is_error returns true for log-level strings considered "error-ish".
// Delegates to the severity model for case-insensitive, allocation-free
// classification.
@(private="file")
level_is_error :: proc(s: string) -> bool {
	#partial switch normalize_level(s) {
	case .Error, .Critical:
		return true
	}
	return false
}

@(private="file")
value_string :: proc(col: ^snout_core.Column, i: int) -> string {
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

@(private="file")
build_error_hotspot_repro :: proc(
	config: Hunt_Config,
	dim: string,
	value: string,
	err: ^sniff.Column_Profile,
	allocator := context.allocator,
) -> string {
	filters: [dynamic]Where_Clause
	filters = make([dynamic]Where_Clause, 0, 2, context.temp_allocator)
	#partial switch err.kind {
	case .Int64:
		append(&filters, Where_Clause{column = err.name, op = .Ge, value = "400"})
	case .Bool:
		append(&filters, Where_Clause{column = err.name, op = .Eq, value = "true"})
	case .String:
		append(&filters, Where_Clause{column = err.name, op = .Eq, value = "error"})
	}
	append(&filters, Where_Clause{column = dim, op = .Eq, value = value})
	// Silence unused-import warning when no branch hit.
	_ = query.Sort_Direction.Ascending
	return query_repro(
		config, dim,
		[]string{"count=rows"},
		filters[:], []Sort_Clause{}, 0, allocator,
	)
}
