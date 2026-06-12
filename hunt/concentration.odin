package hunt

import "core:fmt"
import "core:strings"
import snout_core "../core"
import "../sniff"

CONCENTRATION_SHARE_THRESHOLD :: 0.50
CONCENTRATION_MIN_ROWS        :: 30
CONCENTRATION_MAX_IDENT_CARD  :: 50

// run_concentration emits findings when a single dimension value dominates a
// column. Reuses sniff's pre-computed top_values to avoid a second scan.
run_concentration :: proc(
	pool: ^[dynamic]Finding,
	candidates: Candidate_Set,
	table: ^snout_core.Table,
	config: Hunt_Config,
	allocator := context.allocator,
) {
	min_rows := config.min_rows_per_finding
	if min_rows < CONCENTRATION_MIN_ROWS { min_rows = CONCENTRATION_MIN_ROWS }

	for cand in candidates.dimensions {
		emit_concentration_for(pool, cand.profile, table, config, min_rows, allocator)
	}
	// Allow identifiers with low cardinality (e.g. small enum-like columns).
	for cand in candidates.all {
		p := cand.profile
		if p.role != .Identifier { continue }
		if !p.cardinality.exact { continue }
		if p.cardinality.distinct_count > CONCENTRATION_MAX_IDENT_CARD { continue }
		emit_concentration_for(pool, p, table, config, min_rows, allocator)
	}
}

@(private="file")
emit_concentration_for :: proc(
	pool: ^[dynamic]Finding,
	p: ^sniff.Column_Profile,
	table: ^snout_core.Table,
	config: Hunt_Config,
	min_rows: int,
	allocator := context.allocator,
) {
	if len(p.top_values) == 0 { return }
	if p.non_null_count <= 0 { return }
	top := p.top_values[0]
	if top.count < min_rows { return }

	share := f64(top.count) / f64(p.non_null_count)
	if share < CONCENTRATION_SHARE_THRESHOLD { return }

	value_str := profile_value_to_string(top.value, allocator)

	// Suppress routine log-level dominance (INFO, DEBUG, TRACE). These belong
	// in the frequent-context summary, not attention findings.
	if is_level_column(p.name) {
		if is_routine_level(normalize_level(value_str)) {
			delete(value_str, allocator)
			return
		}
	}

	effect      := share * 100.0
	coverage    := coverage_score(top.count, p.row_count)
	conf_score  := confidence_score(top.count)
	novelty     := f64(70) // dimension dominance is moderately novel
	score       := compose_score(effect, coverage, conf_score, novelty)

	if score < config.min_score {
		delete(value_str, allocator)
		return
	}

	dim_clone, _ := strings.clone(p.name, allocator)
	title := fmt.aprintf(
		"%.0f%% of %s rows are %s=%s",
		share * 100.0, table.name, p.name, value_str,
		allocator = allocator,
	)
	summary := fmt.aprintf(
		"One value dominates the %s column (%d of %d non-null rows).",
		p.name, top.count, p.non_null_count,
		allocator = allocator,
	)
	repro := query_repro(
		config, p.name,
		[]string{"count=rows"},
		[]Where_Clause{{column = p.name, op = .Eq, value = value_str}},
		[]Sort_Clause{}, 0, allocator,
	)
	dedup := fmt.aprintf("concentration:%s:%s", p.name, value_str, allocator = allocator)

	append(pool, Finding{
		type               = .Concentration,
		score              = score,
		confidence         = confidence_from_rows(top.count),
		title              = title,
		summary            = summary,
		reproduce_command  = repro,
		reproduce_fidelity = .Exact,
		dedup_key          = dedup,
		novelty            = novelty,
		evidence = Concentration_Evidence{
			dimension     = dim_clone,
			value         = value_str,
			matching_rows = top.count,
			total_rows    = p.non_null_count,
			share         = share,
		},
	})
}

// is_level_column returns true when the column name looks like a log level
// column. ASCII case-insensitive, allocation-free.
@(private="file")
is_level_column :: proc(name: string) -> bool {
	if hunt_ieq(name, "level") { return true }
	if hunt_ieq(name, "severity") { return true }
	if hunt_ieq(name, "loglevel") { return true }
	if hunt_ieq(name, "log_level") { return true }
	return false
}

// profile_value_to_string renders a sniff.Profile_Value as a flat string.
profile_value_to_string :: proc(v: sniff.Profile_Value, allocator := context.allocator) -> string {
	#partial switch v.kind {
	case .String, .Timestamp:
		out, _ := strings.clone(v.string_value, allocator)
		return out
	case .Int64:
		return fmt.aprintf("%d", v.int_value, allocator = allocator)
	case .Bool:
		if v.bool_value {
			out, _ := strings.clone("true", allocator)
			return out
		}
		out, _ := strings.clone("false", allocator)
		return out
	}
	return strings.clone("", allocator) or_else ""
}
