package result_output

Output_Format :: enum {
	Table,
	CSV,
	JSON,
	JSONL,
}

parse_output_format :: proc(text: string) -> (Output_Format, bool) {
	switch text {
	case "table": return .Table, true
	case "csv":   return .CSV, true
	case "json":  return .JSON, true
	case "jsonl": return .JSONL, true
	}
	return .Table, false
}
