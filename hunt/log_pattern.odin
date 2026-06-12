package hunt

import "core:fmt"
import "core:slice"
import "core:strings"
import snout_core "../core"

// Severity-aware minimum occurrence thresholds. Errors and critical messages
// are rare by definition — requiring 5 occurrences to surface them defeats the
// purpose of the analyzer. We use a tiered threshold so that:
//   - Any critical/error pattern with ≥1 occurrence emits a finding.
//   - Warn patterns with ≥2 occurrences emit a finding (1 is just noise).
//   - Unknown levels use the warn threshold.
LOG_PATTERN_MIN_OCCURRENCES_CRITICAL :: 1
LOG_PATTERN_MIN_OCCURRENCES_ERROR    :: 1
LOG_PATTERN_MIN_OCCURRENCES_WARN     :: 2
LOG_PATTERN_MIN_OCCURRENCES_UNKNOWN  :: 2
LOG_PATTERN_MIN_OCCURRENCES_INFO     :: 2

@(private="file")
min_occurrences_for_level :: proc(l: Log_Level) -> int {
	switch l {
	case .Critical: return LOG_PATTERN_MIN_OCCURRENCES_CRITICAL
	case .Error:    return LOG_PATTERN_MIN_OCCURRENCES_ERROR
	case .Warn:     return LOG_PATTERN_MIN_OCCURRENCES_WARN
	case .Unknown:  return LOG_PATTERN_MIN_OCCURRENCES_UNKNOWN
	case .Info:     return LOG_PATTERN_MIN_OCCURRENCES_INFO
	case .Debug, .Trace:
		return 9999 // routine — should be filtered out earlier
	}
	return 9999
}

// run_log_pattern emits attention findings for templates that appear under
// non-routine levels (Warn / Error / Critical). Each finding carries a
// representative message, the normalized template, and (when possible) a
// stable substring suitable for a `--where ... contains` filter.
//
// No-op when there is no detectable level + message column pair.
run_log_pattern :: proc(
	pool: ^[dynamic]Finding,
	candidates: Candidate_Set,
	table: ^snout_core.Table,
	config: Hunt_Config,
	allocator := context.allocator,
) {
	_ = candidates // analyzer derives columns from the table directly

	level_col := lp_find_level_column(table)
	msg_col   := lp_find_message_column(table)
	ts_col    := lp_find_timestamp_column(table) // optional
	if level_col == nil || msg_col == nil { return }

	// File-wide timestamp extremes — needed for histogram bucketing.
	file_first, file_last := "", ""
	file_first_sec: i64 = 0
	file_last_sec:  i64 = 0
	if ts_col != nil {
		file_first, file_last = compute_time_range(ts_col.strings, ts_col.null_mask, ts_col.nullable)
		file_first_sec = iso_to_seconds(file_first)
		file_last_sec  = iso_to_seconds(file_last)
	}
	use_histogram := ts_col != nil && file_first_sec > 0 && file_last_sec > file_first_sec

	Bucket :: struct {
		count:      int,
		level:      Log_Level,
		original:   string, // borrowed from table
		message:    string, // borrowed from table
		template:   string, // owned by allocator
		first_seen: string, // borrowed from table; "" if no timestamp col
		last_seen:  string, // borrowed from table; "" if no timestamp col
		histogram:  []int,  // owned via context.temp_allocator
	}

	// Key is "<level_priority>|<template>" so the same template at different
	// severities surfaces as distinct findings.
	buckets := make(map[string]Bucket, 0, context.temp_allocator)
	defer delete(buckets)

	for i in 0..<table.row_count {
		if level_col.nullable && level_col.null_mask[i] { continue }
		if msg_col.nullable && msg_col.null_mask[i] { continue }
		lvl := normalize_level(level_col.strings[i])
		if is_routine_level(lvl) &&
		   !(config.include_info_patterns && lvl == .Info) {
			continue
		}

		tmpl := templatize(msg_col.strings[i], allocator)
		key := fmt.tprintf("%d|%s", log_level_priority(lvl), tmpl)
		entry, exists := buckets[key]
		if !exists {
			entry.template = tmpl
			entry.message  = msg_col.strings[i]
			entry.original = level_col.strings[i]
			entry.level    = lvl
			if use_histogram {
				entry.histogram = make([]int, HISTOGRAM_BUCKETS_VERBOSE, context.temp_allocator)
			}
		} else {
			delete(tmpl, allocator)
		}
		entry.count += 1
		if ts_col != nil && (!ts_col.nullable || !ts_col.null_mask[i]) {
			ts := ts_col.strings[i]
			if entry.first_seen == "" || ts < entry.first_seen { entry.first_seen = ts }
			if entry.last_seen  == "" || ts > entry.last_seen  { entry.last_seen  = ts }
			if use_histogram {
				idx := timestamp_to_bucket(ts, file_first_sec, file_last_sec, HISTOGRAM_BUCKETS_VERBOSE)
				if idx >= 0 { entry.histogram[idx] += 1 }
			}
		}
		buckets[key] = entry
	}

	if len(buckets) == 0 { return }

	// Track which buckets we emitted; any unused template strings still need
	// to be freed before the proc returns.
	emitted := make(map[string]bool, 0, context.temp_allocator)
	defer {
		for k, b in buckets {
			if !emitted[k] { delete(b.template, allocator) }
		}
		delete(emitted)
	}

	keys := make([dynamic]string, 0, len(buckets), context.temp_allocator)
	for k in buckets { append(&keys, k) }
	slice.sort(keys[:])

	for k in keys {
		b := buckets[k]
		if b.count < min_occurrences_for_level(b.level) { continue }

		// Severity-aware scoring. Errors and criticals are rare by definition,
		// so we don't penalise them for low counts — instead we let level
		// itself drive most of the effect. Tuned so that 1 error with the
		// default config (min_score=60) always passes.
		base_effect:  f64
		base_novelty: f64
		min_conf:     f64
		switch b.level {
		case .Critical: base_effect = 100; base_novelty = 100; min_conf = 70
		case .Error:    base_effect = 90;  base_novelty = 95;  min_conf = 60
		case .Warn:     base_effect = 95;  base_novelty = 85;  min_conf = 55
		case .Unknown:  base_effect = 70;  base_novelty = 70;  min_conf = 40
		case .Info:
			if !config.include_info_patterns { continue }
			base_effect = 80
			base_novelty = 55
			min_conf = 55
		case .Debug, .Trace: continue
		}

		share    := f64(b.count) / f64(table.row_count)
		effect   := base_effect + share * 30.0
		// Burst boost: when ≥3 occurrences fall inside a 5-minute window we
		// treat the pattern as a spike. Concentrated errors deserve more
		// attention than the same count spread across a day.
		if b.count >= 3 && is_burst(b.first_seen, b.last_seen) {
			effect += 10
		}
		if effect > 100 { effect = 100 }
		coverage := share * 100.0
		conf     := confidence_score(b.count)
		if conf < min_conf { conf = min_conf }
		score    := compose_score(effect, coverage, conf, base_novelty)
		if score < config.min_score { continue }

		// Stable fragment for the reproduce command — first 4+ char alphanumeric
		// word taken from the message (preferred) or template.
		fragment := lp_first_word_hint(b.message)
		if fragment == "" {
			fragment = lp_first_word_hint(b.template)
		}

		representative, _ := strings.clone(b.message,  allocator)
		template_owned    := b.template // already in `allocator`
		original_clone, _ := strings.clone(b.original, allocator)
		fragment_clone, _ := strings.clone(fragment,    allocator)
		first_clone, _    := strings.clone(b.first_seen, allocator)
		last_clone,  _    := strings.clone(b.last_seen,  allocator)
		range_start_clone, _ := strings.clone(file_first, allocator)
		range_end_clone,   _ := strings.clone(file_last,  allocator)
		hist_owned: []int
		if use_histogram {
			hist_owned = make([]int, HISTOGRAM_BUCKETS_VERBOSE, allocator)
			copy(hist_owned, b.histogram)
		}

		// Title intentionally omits the "LEVEL pattern (N×):" prefix — the
		// renderer adds the LEVEL tag and the (N×) count itself.
		title, _ := strings.clone(template_owned, allocator)
		summary := fmt.aprintf(
			"%d occurrences. Sample: %s",
			b.count, representative,
			allocator = allocator,
		)

		// Reproduce command — exact when we have a fragment to filter on,
		// approximate otherwise (level-only filter cannot distinguish patterns).
		filters := make([dynamic]Where_Clause, 0, 2, context.temp_allocator)
		append(&filters, Where_Clause{column = "level", op = .Eq, value = b.original})
		fidelity := Reproduce_Fidelity.Approximate
		if fragment_clone != "" {
			// query engine does not yet expose `contains`; documented as
			// approximate, but the level filter still narrows the search.
		}
		repro := query_repro(
			config, "level",
			[]string{"count=rows"},
			filters[:], []Sort_Clause{}, 10, allocator,
		)
		dedup := fmt.aprintf("log_pattern:%s:%s",
			log_level_name(b.level), template_owned, allocator = allocator)

		emitted[k] = true
		append(pool, Finding{
			type              = .Log_Pattern,
			score             = score,
			confidence        = confidence_from_rows(b.count),
			title             = title,
			summary           = summary,
			reproduce_command = repro,
			reproduce_fidelity = fidelity,
			dedup_key         = dedup,
			novelty           = base_novelty,
			evidence = Log_Pattern_Evidence{
				level                  = b.level,
				original_level         = original_clone,
				message_template       = template_owned,
				representative_message = representative,
				contains_fragment      = fragment_clone,
				matching_rows          = b.count,
				total_rows             = table.row_count,
				share                  = share,
				first_seen             = first_clone,
				last_seen              = last_clone,
				range_start            = range_start_clone,
				range_end              = range_end_clone,
				histogram              = hist_owned,
			},
		})
	}
}

// is_burst returns true when first and last ISO-8601 timestamps span less than
// 5 minutes — a rough heuristic for "this all happened at once". Lexicographic
// comparison is monotonic for ISO-8601 with the same offset.
@(private="file")
is_burst :: proc(first, last: string) -> bool {
	if first == "" || last == "" { return false }
	if len(first) < 16 || len(last) < 16 { return false }
	// Same date AND minute → tight cluster.
	if first[:16] == last[:16] { return true }
	// Same hour, last minute ≤ first minute + 5.
	if first[:13] != last[:13] { return false }
	a_min := iso_minute(first)
	b_min := iso_minute(last)
	if a_min < 0 || b_min < 0 { return false }
	return b_min - a_min <= 5
}

@(private="file")
iso_minute :: proc(ts: string) -> int {
	if len(ts) < 16 { return -1 }
	tens := int(ts[14] - '0')
	ones := int(ts[15] - '0')
	if tens < 0 || tens > 9 || ones < 0 || ones > 9 { return -1 }
	return tens * 10 + ones
}

@(private="file")
lp_first_word_hint :: proc(s: string) -> string {
	start := -1
	for i in 0..<len(s) {
		c := s[i]
		is_alnum := (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || (c >= '0' && c <= '9')
		if start < 0 {
			if is_alnum { start = i }
		} else if !is_alnum {
			if i - start >= 4 { return s[start:i] }
			start = -1
		}
	}
	if start >= 0 && len(s) - start >= 4 { return s[start:] }
	return ""
}

@(private="file")
lp_find_level_column :: proc(table: ^snout_core.Table) -> ^snout_core.Column {
	for &col in table.columns {
		if col.kind != .String { continue }
		if hunt_ieq(col.name, "level") || hunt_ieq(col.name, "severity") {
			return &col
		}
	}
	return nil
}

@(private="file")
lp_find_message_column :: proc(table: ^snout_core.Table) -> ^snout_core.Column {
	for &col in table.columns {
		if col.kind != .String { continue }
		if hunt_ieq(col.name, "msg") || hunt_ieq(col.name, "message") {
			return &col
		}
	}
	return nil
}

@(private="file")
lp_find_timestamp_column :: proc(table: ^snout_core.Table) -> ^snout_core.Column {
	for &col in table.columns {
		if col.kind != .Timestamp && col.kind != .String { continue }
		if hunt_ieq(col.name, "timestamp") || hunt_ieq(col.name, "ts") ||
		   hunt_ieq(col.name, "time") || hunt_ieq(col.name, "@timestamp") {
			return &col
		}
	}
	return nil
}
