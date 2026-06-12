package hunt

import "base:runtime"

// HUNT_SCHEMA_VERSION is emitted in JSON output. Bump on breaking changes
// to the JSON shape — never on additive changes.
HUNT_SCHEMA_VERSION :: 1

// Source_Kind identifies how the input was loaded. Drives which reproduce
// command variant is generated (csv-stats vs jsonl-stats vs stats, etc.).
Source_Kind :: enum {
	Unknown,
	CSV,
	JSONL,
	Log,
	Snout,
}

source_kind_from_path :: proc(path: string) -> Source_Kind {
	if has_suffix(path, ".csv") { return .CSV }
	if has_suffix(path, ".jsonl") || has_suffix(path, ".ndjson") { return .JSONL }
	if has_suffix(path, ".log") || has_suffix(path, ".access") || has_suffix(path, ".error") {
		return .Log
	}
	if has_suffix(path, ".snout") { return .Snout }
	return .Unknown
}

source_kind_name :: proc(k: Source_Kind) -> string {
	switch k {
	case .CSV:   return "csv"
	case .JSONL: return "jsonl"
	case .Log:   return "log"
	case .Snout: return "snout"
	case .Unknown: return "unknown"
	}
	return "unknown"
}

@(private="file")
has_suffix :: proc(s, suffix: string) -> bool {
	if len(s) < len(suffix) { return false }
	return s[len(s)-len(suffix):] == suffix
}

Finding_Type :: enum {
	Concentration,
	Error_Hotspot,
	Metric_Outlier,
	Null_Anomaly,
	Temporal_Shift,
	Top_Contributor,
	Log_Pattern,
}

Concentration_Evidence :: struct {
	dimension:     string,
	value:         string,
	matching_rows: int,
	total_rows:    int,
	share:         f64,
}

Error_Hotspot_Evidence :: struct {
	dimension:       string,
	value:           string,
	error_column:    string,
	matching_errors: int,
	total_errors:    int,
	segment_rate:    f64,
	baseline_rate:   f64,
	ratio:           f64,
}

Metric_Outlier_Evidence :: struct {
	metric:        string,
	median:        f64,
	p95:           f64,
	p99:           f64,
	max_value:     f64,
	ratio_p99_p50: f64,
}

Null_Anomaly_Evidence :: struct {
	column:     string,
	null_count: int,
	total_rows: int,
	null_ratio: f64,
}

Temporal_Shift_Evidence :: struct {
	timestamp_column: string,
	bucket_unit:      string, // "hour" | "day"
	before_bucket:    string,
	after_bucket:     string,
	before_count:     int,
	after_count:      int,
	ratio:            f64,
}

Top_Contributor_Evidence :: struct {
	dimension:    string,
	value:        string,
	metric:       string, // primary metric (highest share)
	contribution: f64,
	total:        f64,
	share:        f64,
	// Other metrics dominated by the same (dimension, value). Each entry pairs
	// the metric name with its share so the renderer can summarise:
	// "+7 metrics: bitrate_kbps (86%), concealed_packets (86%), …".
	extra_metrics: []Metric_Share,
}

Metric_Share :: struct {
	metric: string,
	share:  f64,
}

Log_Pattern_Evidence :: struct {
	level:                  Log_Level,
	original_level:         string,
	message_template:       string,
	representative_message: string,
	contains_fragment:      string, // stable substring suitable for --where ... contains
	matching_rows:          int,
	total_rows:             int,
	share:                  f64,
	// Temporal range — empty when the table has no timestamp column.
	first_seen:             string,
	last_seen:              string,
	// Time-distribution histogram. `histogram[i]` is the count in bucket i of
	// the file's full time range — i.e. matches[0] is the first slice of the
	// file, matches[N-1] the last. Length 0 when the table has no timestamp.
	histogram:              []int,
	// range_start / range_end are the FILE-wide timestamp extremes (not the
	// pattern's). Both are needed to label the histogram axis.
	range_start:            string,
	range_end:              string,
}

Evidence :: union {
	Concentration_Evidence,
	Error_Hotspot_Evidence,
	Metric_Outlier_Evidence,
	Null_Anomaly_Evidence,
	Temporal_Shift_Evidence,
	Top_Contributor_Evidence,
	Log_Pattern_Evidence,
}

Finding :: struct {
	type:               Finding_Type,
	score:              int, // 0..100
	confidence:         f64, // 0.0..1.0
	title:              string,
	summary:            string,
	evidence:           Evidence,
	reproduce_command:  string,
	reproduce_fidelity: Reproduce_Fidelity, // Exact | Approximate
	// dedup_key is computed by the analyzer; used by the ranker
	dedup_key: string,
	// novelty score (0..100) — analyzer-supplied
	novelty: f64,
}

// Reproduce_Fidelity lives in types.odin so every analyzer file can read it
// without a cyclical import. Concrete shell-quoting helpers are in reproduce.odin.
Reproduce_Fidelity :: enum {
	Exact,
	Approximate,
}

reproduce_fidelity_name :: proc(f: Reproduce_Fidelity) -> string {
	switch f {
	case .Exact:       return "exact"
	case .Approximate: return "approximate"
	}
	return "exact"
}

Hunt_Config :: struct {
	limit:                 int,
	min_score:             int,
	max_dimensions:        int,
	max_metrics:           int,
	max_timestamp_columns: int,
	min_rows_per_finding:  int,
	frequent_limit:        int, // max Frequent_Pattern records to emit
	show_frequent:         bool, // include frequent context in output
	include_info_patterns: bool, // include INFO log patterns as verbose findings
	// Input metadata — set by the CLI before invoking the engine.
	source_path:           string,
	source_kind:           Source_Kind,
	// Log-specific fields (only meaningful when source_kind == .Log).
	log_format_name:       string, // "clf" | "combined" | "logfmt" | "syslog" | "app" | "regex" | ""
	log_pattern:           string, // only when log_format_name == "regex"
}

DEFAULT_HUNT_CONFIG :: Hunt_Config {
	limit                 = 10,
	min_score             = 60,
	max_dimensions        = 12,
	max_metrics           = 8,
	max_timestamp_columns = 2,
	min_rows_per_finding  = 30,
	frequent_limit        = 5,
	show_frequent         = true,
	include_info_patterns = false,
	source_path           = "",
	source_kind           = .Unknown,
	log_format_name       = "",
	log_pattern           = "",
}

// validate_config returns an Odin error when the configuration is unusable.
// Called by the engine before any analyzer runs.
validate_config :: proc(c: Hunt_Config) -> bool {
	if c.limit < 0 { return false }
	if c.min_score < 0 || c.min_score > 100 { return false }
	if c.max_dimensions < 0 { return false }
	if c.max_metrics < 0 { return false }
	if c.max_timestamp_columns < 0 { return false }
	if c.min_rows_per_finding < 0 { return false }
	return true
}

Frequent_Pattern :: struct {
	level:            Log_Level,
	original_level:   string,
	message:          string,
	message_template: string,
	count:            int,
	share:            f64,
	first_seen:       string,
	last_seen:        string,
}

Severity_Summary :: struct {
	level: Log_Level,
	count: int,
	share: f64,
}

// Schema_Overview is the non-log equivalent of `severity_summary`. It gives the
// user a one-glance summary of the file's shape before diving into findings.
// Populated for CSV, JSONL, and `.snout` inputs (logs already show severity).
Schema_Overview :: struct {
	row_count:         int,
	column_count:      int,
	timestamp_columns: int,
	dimension_columns: int,
	metric_columns:    int,
	identifier_columns:int,
	time_range_start:  string, // ISO-8601 if any Timestamp column has a range
	time_range_end:    string,
	top_null_columns:  []Null_Highlight,    // columns with the highest null ratio
	top_dimensions:    []Dimension_Highlight, // dominant values in dimension columns
}

Null_Highlight :: struct {
	name:       string,
	null_count: int,
	null_ratio: f64,
}

Dimension_Highlight :: struct {
	name:           string,
	top_value:      string,
	top_share:      f64,
	distinct_count: int,
}

Hunt_Report :: struct {
	table_name:        string,
	row_count:         int,
	findings:          []Finding,
	severity_summary:  []Severity_Summary,
	frequent_patterns: []Frequent_Pattern,
	schema_overview:   ^Schema_Overview, // nil for log inputs
	allocator:         runtime.Allocator,
}

finding_type_name :: proc(t: Finding_Type) -> string {
	switch t {
	case .Concentration:    return "concentration"
	case .Error_Hotspot:    return "error_hotspot"
	case .Metric_Outlier:   return "metric_outlier"
	case .Null_Anomaly:     return "null_anomaly"
	case .Temporal_Shift:   return "temporal_shift"
	case .Top_Contributor:  return "top_contributor"
	case .Log_Pattern:      return "log_pattern"
	}
	return "unknown"
}

// Type ordering for deterministic tie-breakers.
finding_type_priority :: proc(t: Finding_Type) -> int {
	switch t {
	case .Log_Pattern:      return 1 // tied with Error_Hotspot for top priority
	case .Error_Hotspot:    return 1
	case .Concentration:    return 2
	case .Metric_Outlier:   return 3
	case .Temporal_Shift:   return 4
	case .Top_Contributor:  return 5
	case .Null_Anomaly:     return 6
	}
	return 99
}

free_hunt_report :: proc(report: ^Hunt_Report) {
	if report == nil { return }
	allocator := report.allocator
	delete(report.table_name, allocator)
	for &p in report.frequent_patterns {
		delete(p.original_level, allocator)
		delete(p.message, allocator)
		delete(p.message_template, allocator)
		delete(p.first_seen, allocator)
		delete(p.last_seen, allocator)
	}
	delete(report.frequent_patterns, allocator)
	delete(report.severity_summary, allocator)
	if report.schema_overview != nil {
		so := report.schema_overview
		delete(so.time_range_start, allocator)
		delete(so.time_range_end, allocator)
		for n in so.top_null_columns { delete(n.name, allocator) }
		delete(so.top_null_columns, allocator)
		for d in so.top_dimensions {
			delete(d.name, allocator)
			delete(d.top_value, allocator)
		}
		delete(so.top_dimensions, allocator)
		free(so, allocator)
	}
	for &f in report.findings {
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
			for ms in e.extra_metrics {
				delete(ms.metric, allocator)
			}
			delete(e.extra_metrics, allocator)
		case Log_Pattern_Evidence:
			delete(e.original_level, allocator)
			delete(e.message_template, allocator)
			delete(e.representative_message, allocator)
			delete(e.contains_fragment, allocator)
			delete(e.first_seen, allocator)
			delete(e.last_seen, allocator)
			delete(e.range_start, allocator)
			delete(e.range_end, allocator)
			delete(e.histogram, allocator)
		}
	}
	delete(report.findings, allocator)
	report^ = {}
}
