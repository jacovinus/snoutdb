package result_output

Sniff_Output_Format :: enum {
	Table,
	JSON,
}

parse_sniff_output_format :: proc(text: string) -> (Sniff_Output_Format, bool) {
	switch text {
	case "table": return .Table, true
	case "json":  return .JSON, true
	}
	return .Table, false
}
