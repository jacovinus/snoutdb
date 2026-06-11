package sniff

import "core:fmt"
import "core:strings"

IDENTIFIER_HINTS :: [?]string{"id", "uuid", "guid", "key", "identifier"}

normalize_column_name :: proc(name: string, allocator := context.temp_allocator) -> string {
	builder: strings.Builder
	strings.builder_init(&builder, allocator)
	defer strings.builder_destroy(&builder)
	for ch in name {
		switch {
		case ch >= 'A' && ch <= 'Z':
			strings.write_rune(&builder, ch-'A'+'a')
		case ch >= 'a' && ch <= 'z':
			strings.write_rune(&builder, ch)
		case ch >= '0' && ch <= '9':
			strings.write_rune(&builder, ch)
		case ch == '-', ch == '.', ch == ' ':
			strings.write_byte(&builder, '_')
		case:
			_, _ = strings.write_rune(&builder, ch)
		}
	}
	return strings.clone(strings.to_string(builder), allocator)
}

has_identifier_hint :: proc(name: string) -> bool {
	normalized := normalize_column_name(name)
	for hint in IDENTIFIER_HINTS {
		if normalized == hint {
			return true
		}
		prefix := fmt.tprintf("%s_", hint)
		if strings.has_prefix(normalized, prefix) {
			return true
		}
		suffix := fmt.tprintf("_%s", hint)
		if strings.has_suffix(normalized, suffix) {
			return true
		}
	}
	return false
}

is_safe_cli_name :: proc(name: string) -> bool {
	if len(name) == 0 {
		return false
	}
	for ch in name {
		switch {
		case ch >= 'A' && ch <= 'Z':
		case ch >= 'a' && ch <= 'z':
		case ch >= '0' && ch <= '9':
		case ch == '_', ch == '-', ch == '.':
		case:
			return false
		}
	}
	return true
}

classify_column_role :: proc(profile: ^Column_Profile) {
	if profile.kind == .Unknown {
		profile.role = .Unknown
		profile.role_reason = "unknown source type"
		return
	}
	if profile.non_null_count == 0 {
		profile.role = .Unknown
		profile.role_reason = "all values are null"
		return
	}
	if profile.kind == .Timestamp {
		profile.role = .Timestamp
		profile.role_reason = "timestamp type with observed range"
		return
	}
	if (profile.kind == .String || profile.kind == .Int64) &&
	   profile.cardinality.exact {
		unique_ratio := f64(profile.cardinality.distinct_count) /
			f64(profile.non_null_count)
		if unique_ratio >= IDENTIFIER_UNIQUE_RATIO && has_identifier_hint(profile.name) {
			profile.role = .Identifier
			profile.role_reason = fmt.tprintf(
				"identifier-like name and %.2f%% unique values",
				unique_ratio * 100.0,
			)
			return
		}
	}
	if profile.kind == .Bool {
		profile.role = .Dimension
		profile.role_reason = "boolean column"
		return
	}
	if profile.kind == .String && profile.cardinality.exact {
		distinct_count := profile.cardinality.distinct_count
		unique_ratio := f64(distinct_count) / f64(profile.non_null_count)
		if distinct_count <= LOW_CARDINALITY_ABSOLUTE {
			profile.role = .Dimension
			profile.role_reason = fmt.tprintf("%d distinct string values", distinct_count)
			return
		}
		if distinct_count <= MAX_DIMENSION_CARDINALITY &&
		   unique_ratio <= MAX_DIMENSION_RATIO {
			profile.role = .Dimension
			profile.role_reason = fmt.tprintf(
				"%d distinct values across %d rows",
				distinct_count,
				profile.non_null_count,
			)
			return
		}
	}
	if profile.kind == .Int64 && profile.cardinality.exact {
		distinct_count := profile.cardinality.distinct_count
		unique_ratio := f64(distinct_count) / f64(profile.non_null_count)
		if distinct_count <= LOW_CARDINALITY_ABSOLUTE && unique_ratio <= MAX_DIMENSION_RATIO {
			profile.role = .Dimension
			profile.role_reason = fmt.tprintf(
				"%d distinct values across %d rows",
				distinct_count,
				profile.non_null_count,
			)
			return
		}
	}
	if profile.kind == .Int64 || profile.kind == .Float64 {
		profile.role = .Metric
		profile.role_reason = "numeric column with measurable range"
		return
	}
	if profile.kind == .String {
		profile.role = .Unknown
		profile.role_reason = "high-cardinality text without identifier evidence"
		return
	}
	profile.role = .Unknown
	profile.role_reason = "unknown source type"
}
