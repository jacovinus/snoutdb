package hunt

import "core:slice"
import "core:strings"
import "../sniff"

// Candidate column for analyzer dispatch. Holds a pointer into the Sniff_Report
// so analyzers can read the full Column_Profile.
Candidate :: struct {
	profile: ^sniff.Column_Profile,
	name:    string,
}

Candidate_Set :: struct {
	dimensions: []Candidate,
	metrics:    []Candidate,
	timestamps: []Candidate,
	errors:     []Candidate, // bool/level/status columns suitable for error_hotspot
	all:        []Candidate, // every column (sorted by name)
}

// select_candidates returns candidate columns grouped by role. Results are
// sorted by column name to guarantee deterministic analyzer order.
select_candidates :: proc(
	report: ^sniff.Sniff_Report,
	config: Hunt_Config,
	allocator := context.allocator,
) -> Candidate_Set {
	all := make([dynamic]Candidate, 0, len(report.columns), allocator)
	for &col in report.columns {
		append(&all, Candidate{profile = &col, name = col.name})
	}
	slice.sort_by(all[:], candidate_less)

	dims := make([dynamic]Candidate, 0, config.max_dimensions, allocator)
	mets := make([dynamic]Candidate, 0, config.max_metrics, allocator)
	tss  := make([dynamic]Candidate, 0, config.max_timestamp_columns, allocator)
	errs := make([dynamic]Candidate, 0, 4, allocator)

	for cand in all {
		p := cand.profile
		switch p.role {
		case .Dimension:
			if len(dims) < config.max_dimensions {
				append(&dims, cand)
			}
			if is_error_like_column(p) && len(errs) < 8 {
				append(&errs, cand)
			}
		case .Metric:
			if len(mets) < config.max_metrics {
				append(&mets, cand)
			}
			if is_error_like_column(p) && len(errs) < 8 {
				append(&errs, cand)
			}
		case .Timestamp:
			if len(tss) < config.max_timestamp_columns {
				append(&tss, cand)
			}
		case .Identifier:
			// Identifiers are skipped from dimension/metric pools unless they
			// are low cardinality (handled by individual analyzers).
		case .Unknown:
			// no-op
		}
	}

	return Candidate_Set{
		dimensions = dims[:],
		metrics    = mets[:],
		timestamps = tss[:],
		errors     = errs[:],
		all        = all[:],
	}
}

// is_error_like_column flags columns that the error_hotspot analyzer can use.
// It detects: boolean columns named like errors, integer status codes (200..599
// range typical), and string columns whose top values look like log levels.
is_error_like_column :: proc(p: ^sniff.Column_Profile) -> bool {
	name := strings.to_lower(p.name, context.temp_allocator)

	// Booleans named like errors.
	if p.kind == .Bool {
		if name_contains_error_token(name) { return true }
	}

	// Integer status columns: name like status/code AND values 100..599.
	if p.kind == .Int64 && (strings.contains(name, "status") || strings.contains(name, "code")) {
		if p.numeric.valid && p.numeric.int_min >= 100 && p.numeric.int_max <= 599 {
			return true
		}
	}

	// String level/severity columns.
	if p.kind == .String {
		if strings.contains(name, "level") || strings.contains(name, "severity") {
			return true
		}
	}

	return false
}

@(private="file")
candidate_less :: proc(a, b: Candidate) -> bool {
	return a.name < b.name
}

@(private="file")
name_contains_error_token :: proc(lower_name: string) -> bool {
	tokens := []string{"error", "failed", "is_error", "fail"}
	for t in tokens {
		if strings.contains(lower_name, t) { return true }
	}
	return false
}
