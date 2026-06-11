package ingest

import "core:strconv"
import "core:strings"
import snout_core "../core"

infer_value_type :: proc(value: string) -> snout_core.Column_Type {
	if value == "true" || value == "false" {
		return .Bool
	}
	if is_timestamp(value) {
		return .Timestamp
	}
	if _, ok := strconv.parse_i64(value); ok {
		return .Int64
	}
	if has_float_marker(value) {
		if _, ok := strconv.parse_f64(value); ok {
			return .Float64
		}
	}
	return .String
}

promote_types :: proc(
	current, incoming: snout_core.Column_Type,
) -> snout_core.Column_Type {
	if current == .Unknown {
		return incoming
	}
	if incoming == .Unknown || current == incoming {
		return current
	}
	if (current == .Int64 && incoming == .Float64) ||
	   (current == .Float64 && incoming == .Int64) {
		return .Float64
	}
	return .String
}

infer_column_type :: proc(values: []string) -> (snout_core.Column_Type, bool) {
	kind := snout_core.Column_Type.Unknown
	nullable := false
	for value in values {
		if value == "" {
			nullable = true
			continue
		}
		kind = promote_types(kind, infer_value_type(value))
	}
	if kind == .Unknown {
		kind = .String
	}
	return kind, nullable
}

has_float_marker :: proc(value: string) -> bool {
	return strings.contains(value, ".") ||
	       strings.contains(value, "e") ||
	       strings.contains(value, "E")
}

is_timestamp :: proc(value: string) -> bool {
	if len(value) < 20 || value[len(value)-1] != 'Z' {
		return false
	}
	return value[4] == '-' &&
	       value[7] == '-' &&
	       value[10] == 'T' &&
	       value[13] == ':' &&
	       value[16] == ':'
}
