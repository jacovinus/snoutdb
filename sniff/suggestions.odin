package sniff

import "base:runtime"
import "core:fmt"
import "core:strings"
import snout_core "../core"
import query "../query"

METRIC_PRIORITY_TOKENS :: [?]string{
	"mos",
	"latency",
	"jitter",
	"rtt",
	"duration",
	"loss",
	"rate",
	"bytes",
	"size",
	"count",
}

Ranked_Column :: struct {
	index:          int,
	name:           string,
	distinct_count: int,
	null_ratio:     f64,
	priority:       int,
}

metric_name_priority :: proc(name: string) -> int {
	normalized := normalize_column_name(name)
	for token, index in METRIC_PRIORITY_TOKENS {
		if normalized == token {
			return index
		}
		embedded := fmt.tprintf("_%s", token)
		if strings.contains(normalized, embedded) {
			return index
		}
		embedded_prefix := fmt.tprintf("%s_", token)
		if strings.contains(normalized, embedded_prefix) {
			return index
		}
		if strings.has_suffix(normalized, token) {
			return index
		}
	}
	return len(METRIC_PRIORITY_TOKENS)
}

sort_ranked_columns :: proc(
	ranked: []Ranked_Column,
	less: proc(a, b: Ranked_Column) -> bool,
) {
	for i in 1..<len(ranked) {
		key := ranked[i]
		j := i - 1
		for j >= 0 && less(key, ranked[j]) {
			ranked[j+1] = ranked[j]
			j -= 1
		}
		ranked[j+1] = key
	}
}

compare_ranked_dimensions :: proc(a, b: Ranked_Column) -> bool {
	if a.distinct_count != b.distinct_count {
		return a.distinct_count < b.distinct_count
	}
	if a.null_ratio != b.null_ratio {
		return a.null_ratio < b.null_ratio
	}
	return a.index < b.index
}

compare_ranked_metrics :: proc(a, b: Ranked_Column) -> bool {
	if a.priority != b.priority {
		return a.priority < b.priority
	}
	if a.null_ratio != b.null_ratio {
		return a.null_ratio < b.null_ratio
	}
	return a.index < b.index
}

rank_dimensions :: proc(columns: []Column_Profile) -> []Ranked_Column {
	ranked := make([dynamic]Ranked_Column, 0, context.temp_allocator)
	for &column, index in columns {
		if column.role != .Dimension {
			continue
		}
		if !column.cardinality.exact {
			continue
		}
		if column.cardinality.distinct_count <= 1 {
			continue
		}
		if column.cardinality.distinct_count > 100 {
			continue
		}
		if !is_safe_cli_name(column.name) {
			continue
		}
		append(&ranked, Ranked_Column{
			index = index,
			name = column.name,
			distinct_count = column.cardinality.distinct_count,
			null_ratio = column.null_ratio,
		})
	}
	sort_ranked_columns(ranked[:], compare_ranked_dimensions)
	return ranked[:]
}

rank_metrics :: proc(columns: []Column_Profile) -> []Ranked_Column {
	ranked := make([dynamic]Ranked_Column, 0, context.temp_allocator)
	for &column, index in columns {
		if column.role != .Metric {
			continue
		}
		if column.non_null_count == 0 {
			continue
		}
		if !is_safe_cli_name(column.name) {
			continue
		}
		append(&ranked, Ranked_Column{
			index = index,
			name = column.name,
			priority = metric_name_priority(column.name),
			null_ratio = column.null_ratio,
		})
	}
	sort_ranked_columns(ranked[:], compare_ranked_metrics)
	return ranked[:]
}

clone_string :: proc(text: string, allocator: runtime.Allocator) -> (string, snout_core.Error) {
	cloned, err := strings.clone(text, allocator)
	if err != nil {
		return "", .Out_Of_Memory
	}
	return cloned, .None
}

clone_aggregate_specs :: proc(
	specs: []query.Aggregate_Spec,
	allocator: runtime.Allocator,
) -> ([]query.Aggregate_Spec, snout_core.Error) {
	result := make([]query.Aggregate_Spec, len(specs), allocator)
	for spec, index in specs {
		column_name, err := clone_string(spec.column_name, allocator)
		if err != .None {
			for i in 0..<index {
				delete(result[i].column_name, allocator)
			}
			delete(result)
			return nil, err
		}
		result[index] = query.Aggregate_Spec{
			kind = spec.kind,
			column_name = column_name,
		}
	}
	return result, .None
}

clone_sort_terms :: proc(
	terms: []Suggestion_Sort,
	allocator: runtime.Allocator,
) -> ([]Suggestion_Sort, snout_core.Error) {
	result := make([]Suggestion_Sort, len(terms), allocator)
	for term, index in terms {
		target, err := clone_string(term.target, allocator)
		if err != .None {
			for i in 0..<index {
				delete(result[i].target, allocator)
			}
			delete(result)
			return nil, err
		}
		result[index] = Suggestion_Sort{
			target = target,
			direction = term.direction,
		}
	}
	return result, .None
}

append_suggestion :: proc(
	suggestions: ^[dynamic]Query_Suggestion,
	suggestion: Query_Suggestion,
	allocator: runtime.Allocator,
) -> snout_core.Error {
	group_columns, group_err := make([]string, len(suggestion.group_columns), allocator)
	if group_err != nil {
		return .Out_Of_Memory
	}
	for name, index in suggestion.group_columns {
		cloned, err := clone_string(name, allocator)
		if err != .None {
			for i in 0..<index {
				delete(group_columns[i], allocator)
			}
			delete(group_columns)
			return err
		}
		group_columns[index] = cloned
	}
	aggregates, agg_err := clone_aggregate_specs(suggestion.aggregates, allocator)
	if agg_err != .None {
		for name in group_columns {
			delete(name, allocator)
		}
		delete(group_columns)
		return agg_err
	}
	sort_terms, sort_err := clone_sort_terms(suggestion.sort_terms, allocator)
	if sort_err != .None {
		for name in group_columns {
			delete(name, allocator)
		}
		delete(group_columns)
		for &aggregate in aggregates {
			delete(aggregate.column_name, allocator)
		}
		delete(aggregates)
		return sort_err
	}
	reason, reason_err := clone_string(suggestion.reason, allocator)
	if reason_err != .None {
		for name in group_columns {
			delete(name, allocator)
		}
		delete(group_columns)
		for &aggregate in aggregates {
			delete(aggregate.column_name, allocator)
		}
		delete(aggregates)
		for &term in sort_terms {
			delete(term.target, allocator)
		}
		delete(sort_terms)
		return reason_err
	}
	append(suggestions, Query_Suggestion{
		group_columns = group_columns,
		aggregates = aggregates,
		sort_terms = sort_terms,
		limit = suggestion.limit,
		reason = reason,
	})
	return .None
}

collect_unsafe_name_warnings :: proc(
	columns: []Column_Profile,
	warnings: ^[dynamic]string,
	allocator: runtime.Allocator,
) -> snout_core.Error {
	for &column in columns {
		if column.role != .Dimension && column.role != .Metric {
			continue
		}
		if is_safe_cli_name(column.name) {
			continue
		}
		warning := fmt.tprintf(
			`column "%s" omitted from suggestions because its name requires shell quoting`,
			column.name,
		)
		cloned, err := clone_string(warning, allocator)
		if err != .None {
			return err
		}
		append(warnings, cloned)
	}
	return .None
}

build_suggestions :: proc(
	columns: []Column_Profile,
	config: Sniff_Config,
	allocator: runtime.Allocator,
) -> ([]Query_Suggestion, []string, snout_core.Error) {
	warnings := make([dynamic]string, 0, allocator)
	if warn_err := collect_unsafe_name_warnings(columns, &warnings, allocator); warn_err != .None {
		for warning in warnings {
			delete(warning, allocator)
		}
		return nil, nil, warn_err
	}

	suggestions := make([dynamic]Query_Suggestion, 0, allocator)
	if config.max_suggestions == 0 {
		return suggestions[:], warnings[:], .None
	}

	dimensions := rank_dimensions(columns)
	metrics := rank_metrics(columns)

	if len(dimensions) == 0 {
		warning, err := clone_string(
			"no low-cardinality dimensions available for query suggestions",
			allocator,
		)
		if err != .None {
			for existing in warnings {
				delete(existing, allocator)
			}
			delete(warnings)
			return nil, nil, err
		}
		append(&warnings, warning)
		return suggestions[:], warnings[:], .None
	}

	primary_dimension := dimensions[0].name

	// Pass 1: single-dimension metric queries (at most 3)
	pass_one_limit := min(3, len(metrics))
	for metric_index in 0..<pass_one_limit {
		if len(suggestions) >= config.max_suggestions {
			break
		}
		metric_name := metrics[metric_index].name
		sort_target := fmt.tprintf("avg=%s", metric_name)
		suggestion := Query_Suggestion{
			group_columns = []string{primary_dimension},
			aggregates = {
				{kind = .Avg, column_name = metric_name},
				{kind = .Count, column_name = "*"},
			},
			sort_terms = {
				{target = sort_target, direction = .Descending},
			},
			limit = 10,
			reason = fmt.tprintf("compare %s across %s", metric_name, primary_dimension),
		}
		if err := append_suggestion(&suggestions, suggestion, allocator); err != .None {
			free_partial_suggestions(&suggestions, allocator)
			for warning in warnings {
				delete(warning, allocator)
			}
			delete(warnings)
			return nil, nil, err
		}
	}

	// Pass 2: two-dimension drilldown
	if len(suggestions) < config.max_suggestions &&
	   len(dimensions) >= 2 &&
	   len(metrics) >= 1 &&
	   config.max_suggestions > len(suggestions) {
		metric_name := metrics[0].name
		sort_target := fmt.tprintf("avg=%s", metric_name)
		suggestion := Query_Suggestion{
			group_columns = []string{dimensions[0].name, dimensions[1].name},
			aggregates = {
				{kind = .Avg, column_name = metric_name},
				{kind = .Count, column_name = "*"},
			},
			sort_terms = {
				{target = sort_target, direction = .Descending},
			},
			limit = 10,
			reason = fmt.tprintf(
				"drill into %s by %s and %s",
				metric_name,
				dimensions[0].name,
				dimensions[1].name,
			),
		}
		if err := append_suggestion(&suggestions, suggestion, allocator); err != .None {
			free_partial_suggestions(&suggestions, allocator)
			for warning in warnings {
				delete(warning, allocator)
			}
			delete(warnings)
			return nil, nil, err
		}
	}

	// Pass 3: volume query
	if len(suggestions) < config.max_suggestions && len(dimensions) >= 1 {
		suggestion := Query_Suggestion{
			group_columns = []string{dimensions[0].name},
			aggregates = {{kind = .Count, column_name = "*"}},
			sort_terms = {{target = "count=rows", direction = .Descending}},
			limit = 10,
			reason = fmt.tprintf("find the most frequent %s values", dimensions[0].name),
		}
		if err := append_suggestion(&suggestions, suggestion, allocator); err != .None {
			free_partial_suggestions(&suggestions, allocator)
			for warning in warnings {
				delete(warning, allocator)
			}
			delete(warnings)
			return nil, nil, err
		}
	}

	return suggestions[:], warnings[:], .None
}

free_single_suggestion :: proc(suggestion: ^Query_Suggestion, allocator: runtime.Allocator) {
	for name in suggestion.group_columns {
		delete(name, allocator)
	}
	delete(suggestion.group_columns, allocator)
	for &aggregate in suggestion.aggregates {
		delete(aggregate.column_name, allocator)
	}
	delete(suggestion.aggregates, allocator)
	for &term in suggestion.sort_terms {
		delete(term.target, allocator)
	}
	delete(suggestion.sort_terms, allocator)
	delete(suggestion.reason, allocator)
	suggestion^ = {}
}

free_partial_suggestions :: proc(
	suggestions: ^[dynamic]Query_Suggestion,
	allocator: runtime.Allocator,
) {
	for &suggestion in suggestions {
		free_single_suggestion(&suggestion, allocator)
	}
	delete(suggestions^)
}
