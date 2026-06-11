package sniff

import "base:runtime"
import snout_core "../core"
import query "../query"

REPORT_VERSION :: 1

MAX_TOP_VALUE_COUNT :: 100
MAX_DISTINCT_VALUES :: 1_000_000
MAX_SUGGESTIONS :: 20
MAX_TOTAL_TRACKED_DISTINCT_VALUES :: 250_000

LOW_CARDINALITY_ABSOLUTE :: 32
MAX_DIMENSION_CARDINALITY :: 1_000
MAX_DIMENSION_RATIO :: 0.20
IDENTIFIER_UNIQUE_RATIO :: 0.95

DEFAULT_SNIFF_CONFIG :: Sniff_Config {
	top_value_count = 5,
	max_distinct_values = 100_000,
	max_suggestions = 5,
}

Sniff_Config :: struct {
	top_value_count:     int,
	max_distinct_values: int,
	max_suggestions:     int,
}

Column_Role :: enum {
	Unknown,
	Timestamp,
	Identifier,
	Dimension,
	Metric,
}

Cardinality_Profile :: struct {
	exact:          bool,
	distinct_count: int,
	lower_bound:    int,
}

Numeric_Profile :: struct {
	valid:          bool,
	kind:           snout_core.Column_Type,
	count:          int,
	int_min:        i64,
	int_max:        i64,
	float_min:      f64,
	float_max:      f64,
	mean:           f64,
	std_dev:        f64,  // population std dev via Welford; 0 when count < 2
	outlier_count:  int,  // values beyond 3σ; only set by profile_table (in-memory path)
}

Timestamp_Profile :: struct {
	valid: bool,
	min:   string,
	max:   string,
}

Profile_Value :: struct {
	kind:         snout_core.Column_Type,
	string_value: string,
	int_value:    i64,
	bool_value:   bool,
}

Top_Value :: struct {
	value: Profile_Value,
	count: int,
}

Suggestion_Sort :: struct {
	target:    string,
	direction: query.Sort_Direction,
}

Query_Suggestion :: struct {
	group_columns: []string,
	aggregates:    []query.Aggregate_Spec,
	sort_terms:    []Suggestion_Sort,
	limit:         int,
	reason:        string,
}

Column_Profile :: struct {
	name:           string,
	kind:           snout_core.Column_Type,
	role:           Column_Role,
	role_reason:    string,
	row_count:      int,
	null_count:     int,
	non_null_count: int,
	null_ratio:     f64,
	cardinality:    Cardinality_Profile,
	numeric:        Numeric_Profile,
	timestamp:      Timestamp_Profile,
	top_values:     []Top_Value,
	source_index:   int,
}

Sniff_Report :: struct {
	version:      int,
	table_name:   string,
	row_count:    int,
	column_count: int,
	columns:      []Column_Profile,
	suggestions:  []Query_Suggestion,
	warnings:     []string,
	allocator:    runtime.Allocator,
}

validate_sniff_config :: proc(config: Sniff_Config) -> snout_core.Error {
	if config.top_value_count < 0 || config.top_value_count > MAX_TOP_VALUE_COUNT {
		return .Invalid_Sniff_Config
	}
	if config.max_distinct_values < 1 || config.max_distinct_values > MAX_DISTINCT_VALUES {
		return .Invalid_Sniff_Config
	}
	if config.max_suggestions < 0 || config.max_suggestions > MAX_SUGGESTIONS {
		return .Invalid_Sniff_Config
	}
	return .None
}

parse_sniff_option_value :: proc(
	text: string,
	min_value: int,
	max_value: int,
) -> (int, snout_core.Error) {
	if len(text) == 0 {
		return 0, .Invalid_Sniff_Option
	}
	for ch in text {
		if ch < '0' || ch > '9' {
			return 0, .Invalid_Sniff_Option
		}
	}
	value: i64
	for ch in text {
		next := value * 10 + i64(ch - '0')
		if next < value {
			return 0, .Invalid_Sniff_Option
		}
		value = next
	}
	if value < i64(min_value) {
		return 0, .Invalid_Sniff_Option
	}
	if value > i64(max_value) {
		return 0, .Sniff_Limit_Too_Large
	}
	return int(value), .None
}

role_name :: proc(role: Column_Role) -> string {
	switch role {
	case .Unknown:     return "unknown"
	case .Timestamp:   return "timestamp"
	case .Identifier:  return "identifier"
	case .Dimension:   return "dimension"
	case .Metric:      return "metric"
	}
	return "unknown"
}

role_display_name :: proc(role: Column_Role) -> string {
	switch role {
	case .Unknown:     return "Unknown"
	case .Timestamp:   return "Timestamp"
	case .Identifier:  return "Identifier"
	case .Dimension:   return "Dimension"
	case .Metric:      return "Metric"
	}
	return "Unknown"
}

free_sniff_report :: proc(report: ^Sniff_Report) {
	if report == nil {
		return
	}
	allocator := report.allocator
	for &column in report.columns {
		delete(column.name, allocator)
		delete(column.role_reason, allocator)
		delete(column.timestamp.min, allocator)
		delete(column.timestamp.max, allocator)
		for &top in column.top_values {
			if top.value.kind == .String {
				delete(top.value.string_value, allocator)
			}
		}
		delete(column.top_values, allocator)
	}
	delete(report.columns, allocator)
	for &suggestion in report.suggestions {
		for column_name in suggestion.group_columns {
			delete(column_name, allocator)
		}
		delete(suggestion.group_columns, allocator)
		for &aggregate in suggestion.aggregates {
			delete(aggregate.column_name, allocator)
		}
		delete(suggestion.aggregates, allocator)
		for &sort_term in suggestion.sort_terms {
			delete(sort_term.target, allocator)
		}
		delete(suggestion.sort_terms, allocator)
		delete(suggestion.reason, allocator)
	}
	delete(report.suggestions, allocator)
	for warning in report.warnings {
		delete(warning, allocator)
	}
	delete(report.warnings, allocator)
	delete(report.table_name, allocator)
	report^ = {}
}
