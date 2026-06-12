package hunt

import "core:strings"
import snout_core "../core"
import "../sniff"

// run_engine orchestrates all v0 analyzers against an already-built Sniff_Report
// and an in-memory Table. Returns a ranked, deduplicated Hunt_Report.
//
// The caller owns both the input report and the input table. The returned
// Hunt_Report owns its findings (strings and slices) — free with free_hunt_report.
run_engine :: proc(
	report: ^sniff.Sniff_Report,
	table: ^snout_core.Table,
	config: Hunt_Config,
	allocator := context.allocator,
) -> (Hunt_Report, snout_core.Error) {
	if report == nil || table == nil {
		return {}, .Invalid_Sniff_Config
	}
	if !validate_config(config) {
		return {}, .Invalid_Sniff_Config
	}

	candidates := select_candidates(report, config, context.temp_allocator)

	// Each analyzer appends to this pool. Strings are allocated in `allocator`
	// so the final Hunt_Report owns them after ranking.
	pool := make([dynamic]Finding, 0, 32, context.temp_allocator)

	run_concentration(&pool, candidates, table, config, allocator)
	run_error_hotspot(&pool, candidates, table, config, allocator)
	run_metric_outlier(&pool, candidates, table, config, allocator)
	run_null_anomaly(&pool, candidates, table, config, allocator)
	run_temporal_shift(&pool, candidates, table, config, allocator)
	run_top_contributor(&pool, candidates, table, config, allocator)
	run_log_pattern(&pool, candidates, table, config, allocator)

	ranked := rank_findings(pool[:], config, allocator)

	// Free pooled findings that did not survive ranking. We compare by Finding
	// identity (raw title pointer) rather than dedup_key, because two findings
	// sharing the same dedup_key compete in the ranker and only one wins.
	// A keep-set keyed by dedup_key would mark the LOSER as "kept" and leak its
	// strings. Title pointers are unique per Finding instance because each one
	// is built with a separate `fmt.aprintf`.
	survivors := make(map[rawptr]bool, 0, context.temp_allocator)
	defer delete(survivors)
	for f in ranked {
		survivors[raw_data(f.title)] = true
	}
	for f in pool {
		if !survivors[raw_data(f.title)] {
			free_finding_strings(f, allocator)
		}
	}

	table_name, _ := strings.clone(report.table_name, allocator)

	severity:  []Severity_Summary
	frequent:  []Frequent_Pattern
	if config.show_frequent {
		severity = compute_severity_summary(report, table, allocator)
		frequent = compute_frequent_patterns(report, table, config.frequent_limit, allocator)
	}

	return Hunt_Report{
		table_name        = table_name,
		row_count         = report.row_count,
		findings          = ranked,
		severity_summary  = severity,
		frequent_patterns = frequent,
		allocator         = allocator,
	}, .None
}

// free_finding_strings releases every owned string inside a Finding. Used by
// the engine to discard findings that did not make the cut after ranking.
free_finding_strings :: proc(f: Finding, allocator := context.allocator) {
	delete(f.title, allocator)
	delete(f.summary, allocator)
	delete(f.reproduce_command, allocator)
	delete(f.dedup_key, allocator)
	#partial switch e in f.evidence {
	case Concentration_Evidence:
		delete(e.dimension, allocator)
		delete(e.value, allocator)
	case Error_Hotspot_Evidence:
		delete(e.dimension, allocator)
		delete(e.value, allocator)
		delete(e.error_column, allocator)
	case Metric_Outlier_Evidence:
		delete(e.metric, allocator)
	case Null_Anomaly_Evidence:
		delete(e.column, allocator)
	case Temporal_Shift_Evidence:
		delete(e.timestamp_column, allocator)
		delete(e.bucket_unit, allocator)
		delete(e.before_bucket, allocator)
		delete(e.after_bucket, allocator)
	case Top_Contributor_Evidence:
		delete(e.dimension, allocator)
		delete(e.value, allocator)
		delete(e.metric, allocator)
	}
}
