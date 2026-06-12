package hunt

import "core:fmt"
import "core:strings"
import snout_core "../core"

NULL_ANOMALY_RATIO_THRESHOLD :: 0.20

// run_null_anomaly emits findings for columns whose null ratio crosses 20%.
// Sniff already computes null_ratio per column, so this analyzer is O(columns).
run_null_anomaly :: proc(
	pool: ^[dynamic]Finding,
	candidates: Candidate_Set,
	table: ^snout_core.Table,
	config: Hunt_Config,
	allocator := context.allocator,
) {
	for cand in candidates.all {
		p := cand.profile
		// Skip suspicious column names that come from misparsed logfmt: URLs,
		// query strings, JSON fragments, or anything containing characters that
		// are never part of a sensible schema. These are noise, not signals.
		if !is_plausible_column_name(p.name) { continue }
		if p.null_count < config.min_rows_per_finding { continue }
		if p.null_ratio < NULL_ANOMALY_RATIO_THRESHOLD { continue }

		effect   := p.null_ratio * 100.0
		coverage := f64(p.null_count) / f64(p.row_count) * 100.0
		conf     := confidence_score(p.null_count)
		novelty  := f64(60)
		score    := compose_score(effect, coverage, conf, novelty)
		if score < config.min_score { continue }

		col_clone, _ := strings.clone(p.name, allocator)
		title := fmt.aprintf(
			"%.0f%% of %s values are missing",
			p.null_ratio * 100.0, p.name,
			allocator = allocator,
		)
		summary := fmt.aprintf(
			"%s has %d null values out of %d rows.",
			p.name, p.null_count, p.row_count,
			allocator = allocator,
		)
		repro := query_repro(
			config, p.name,
			[]string{"count=rows"},
			[]Where_Clause{{column = p.name, op = .Is_Null}},
			[]Sort_Clause{}, 0, allocator,
		)
		dedup := fmt.aprintf("null_anomaly:%s", p.name, allocator = allocator)

		append(pool, Finding{
			type               = .Null_Anomaly,
			score              = score,
			confidence         = confidence_from_rows(p.null_count),
			title              = title,
			summary            = summary,
			reproduce_command  = repro,
			reproduce_fidelity = .Exact,
			dedup_key          = dedup,
			novelty            = novelty,
			evidence = Null_Anomaly_Evidence{
				column     = col_clone,
				null_count = p.null_count,
				total_rows = p.row_count,
				null_ratio = p.null_ratio,
			},
		})
	}
}

// is_plausible_column_name filters out the side-effects of permissive logfmt
// parsing: URL fragments, JSON path segments, and other strings that no schema
// would use as a column name. Used to suppress noisy findings.
@(private="file")
is_plausible_column_name :: proc(name: string) -> bool {
	if len(name) == 0 { return false }
	if len(name) > 64 { return false }
	for i in 0..<len(name) {
		c := name[i]
		// Allow standard identifier chars plus dots (for json paths some logs use).
		switch c {
		case 'a'..='z', 'A'..='Z', '0'..='9', '_', '-', '.':
			continue
		case:
			return false
		}
	}
	return true
}
