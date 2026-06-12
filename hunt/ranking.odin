package hunt

import "core:slice"

// rank_findings sorts, deduplicates, and truncates the candidate list.
// Sorting is stable and deterministic:
//   1. Higher score first.
//   2. Tie-breaker: lower type_priority first (Error_Hotspot before Concentration etc).
//   3. Tie-breaker: title ascending.
// Findings with score < config.min_score are dropped.
// Deduplication collapses findings sharing the same dedup_key, keeping the
// highest-scoring one.
//
// `limit` semantics:
//   limit > 0  → return at most `limit` findings
//   limit == 0 → no cap (return every surviving finding)
//   limit < 0  → no cap (treated as 0 for backward compatibility)
rank_findings :: proc(
	findings: []Finding,
	config: Hunt_Config,
	allocator := context.allocator,
) -> []Finding {
	if len(findings) == 0 {
		return make([]Finding, 0, allocator)
	}

	// Deduplicate by dedup_key, keeping the highest-scoring finding per key.
	best := make(map[string]int, 0, context.temp_allocator)
	defer delete(best)

	for f, i in findings {
		if f.score < config.min_score { continue }
		key := f.dedup_key
		if key == "" { key = f.title }
		existing, ok := best[key]
		if !ok || findings[existing].score < f.score {
			best[key] = i
		}
	}

	if len(best) == 0 {
		return make([]Finding, 0, allocator)
	}

	// Materialize surviving findings into a temp slice we can sort.
	survivors := make([dynamic]Finding, 0, len(best), context.temp_allocator)
	for _, idx in best {
		append(&survivors, findings[idx])
	}

	slice.sort_by(survivors[:], finding_less)

	limit := config.limit
	if limit <= 0 || limit > len(survivors) { limit = len(survivors) }

	if config.include_info_patterns && limit < len(survivors) {
		out := select_verbose_findings(survivors[:], limit, allocator)
		slice.sort_by(out, verbose_finding_less)
		return out
	}

	out := make([]Finding, limit, allocator)
	for i in 0..<limit {
		out[i] = survivors[i]
	}
	if config.include_info_patterns {
		slice.sort_by(out, verbose_finding_less)
	}
	return out
}

@(private="file")
select_verbose_findings :: proc(
	survivors: []Finding,
	limit: int,
	allocator := context.allocator,
) -> []Finding {
	selected := make([]bool, len(survivors), context.temp_allocator)
	info_reserved := 0
	for finding, i in survivors {
		if info_reserved >= 2 || info_reserved >= limit { break }
		if finding_is_info_pattern(finding) {
			selected[i] = true
			info_reserved += 1
		}
	}

	remaining := limit - info_reserved
	for finding, i in survivors {
		if remaining == 0 { break }
		if selected[i] || finding_is_info_pattern(finding) { continue }
		selected[i] = true
		remaining -= 1
	}
	for _, i in survivors {
		if remaining == 0 { break }
		if selected[i] { continue }
		selected[i] = true
		remaining -= 1
	}

	out := make([]Finding, limit, allocator)
	out_index := 0
	for finding, i in survivors {
		if !selected[i] { continue }
		out[out_index] = finding
		out_index += 1
	}
	return out
}

@(private="file")
finding_is_info_pattern :: proc(finding: Finding) -> bool {
	if evidence, ok := finding.evidence.(Log_Pattern_Evidence); ok {
		return evidence.level == .Info
	}
	return false
}

@(private="file")
verbose_finding_less :: proc(a, b: Finding) -> bool {
	a_rank := verbose_severity_rank(a)
	b_rank := verbose_severity_rank(b)
	if a_rank != b_rank { return a_rank < b_rank }
	return finding_less(a, b)
}

@(private="file")
verbose_severity_rank :: proc(finding: Finding) -> int {
	level, ok := finding_log_level(finding)
	if !ok { return 7 }
	switch level {
	case .Critical: return 0
	case .Error:    return 1
	case .Warn:     return 2
	case .Unknown:  return 3
	case .Info:     return 4
	case .Debug:    return 5
	case .Trace:    return 6
	}
	return 7
}

@(private="file")
finding_log_level :: proc(finding: Finding) -> (Log_Level, bool) {
	if evidence, ok := finding.evidence.(Log_Pattern_Evidence); ok {
		return evidence.level, true
	}
	if _, ok := finding.evidence.(Error_Hotspot_Evidence); ok {
		return .Error, true
	}
	return .Unknown, false
}

@(private="file")
finding_less :: proc(a, b: Finding) -> bool {
	if a.score != b.score { return a.score > b.score }
	pa := finding_type_priority(a.type)
	pb := finding_type_priority(b.type)
	if pa != pb { return pa < pb }
	return a.title < b.title
}
