package snout_core

Column :: struct {
	name:       string,
	kind:       Column_Type,
	nullable:   bool,
	null_mask:  []bool,
	strings:    []string,
	int64s:     []i64,
	float64s:   []f64,
	bools:      []bool,
}

column_type_name :: proc(kind: Column_Type) -> string {
	switch kind {
	case .Unknown:
		return "Unknown"
	case .String:
		return "String"
	case .Int64:
		return "Int64"
	case .Float64:
		return "Float64"
	case .Bool:
		return "Bool"
	case .Timestamp:
		return "Timestamp"
	}
	return "Unknown"
}
