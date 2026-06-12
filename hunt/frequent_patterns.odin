package hunt

import "core:slice"
import "core:strings"
import snout_core "../core"
import "../sniff"

// compute_severity_summary builds an ordered (priority desc) summary of log
// level occurrences. Returns nil when no level column is detected.
compute_severity_summary :: proc(
	report: ^sniff.Sniff_Report,
	table: ^snout_core.Table,
	allocator := context.allocator,
) -> []Severity_Summary {
	level_col := find_level_column(table)
	if level_col == nil { return nil }

	counts: [Log_Level]int
	total := 0
	for v, i in level_col.strings {
		if level_col.nullable && level_col.null_mask[i] { continue }
		counts[normalize_level(v)] += 1
		total += 1
	}
	if total == 0 { return nil }

	out := make([dynamic]Severity_Summary, 0, len(Log_Level), allocator)
	for level in Log_Level {
		if counts[level] == 0 { continue }
		append(&out, Severity_Summary{
			level = level,
			count = counts[level],
			share = f64(counts[level]) / f64(total),
		})
	}

	// Order by priority descending (Critical → Error → Warn → Unknown → Info → Debug → Trace).
	slice.sort_by(out[:], severity_less)

	_ = report
	return out[:]
}

// compute_frequent_patterns groups log messages by template, returning the
// top N patterns by count. Templates are computed via templatize so messages
// that only differ in IDs, IPs, or numbers cluster together.
//
// `frequent_limit` <= 0 disables the pattern computation.
compute_frequent_patterns :: proc(
	report: ^sniff.Sniff_Report,
	table: ^snout_core.Table,
	frequent_limit: int,
	allocator := context.allocator,
) -> []Frequent_Pattern {
	if frequent_limit <= 0 { return nil }
	msg_col := find_message_column(table)
	if msg_col == nil { return nil }
	level_col := find_level_column(table) // may be nil
	ts_col := find_timestamp_column(table) // may be nil

	Bucket :: struct {
		count:         int,
		template:      string, // owned by allocator
		representative: string, // owned by allocator
		level:         Log_Level,
		original:     string,  // owned by allocator
		first_seen:    string, // owned by allocator
		last_seen:     string, // owned by allocator
	}

	buckets := make(map[string]Bucket, 0, context.temp_allocator)
	defer delete(buckets)

	for i in 0..<table.row_count {
		if msg_col.nullable && msg_col.null_mask[i] { continue }
		msg := msg_col.strings[i]
		tmpl := templatize(msg, allocator)
		entry, exists := buckets[tmpl]
		if !exists {
			entry.template       = tmpl
			entry.representative = preserve_representative(msg, allocator)
			if level_col != nil && (!level_col.nullable || !level_col.null_mask[i]) {
				lvl_raw := level_col.strings[i]
				entry.level    = normalize_level(lvl_raw)
				entry.original, _ = strings.clone(lvl_raw, allocator)
			} else {
				entry.level = .Unknown
			}
			if ts_col != nil && (!ts_col.nullable || !ts_col.null_mask[i]) {
				ts := ts_col.strings[i]
				entry.first_seen, _ = strings.clone(ts, allocator)
				entry.last_seen,  _ = strings.clone(ts, allocator)
			}
		} else {
			// Template re-used; free the new clone (representative is kept from first).
			delete(tmpl, allocator)
			if ts_col != nil && (!ts_col.nullable || !ts_col.null_mask[i]) {
				ts := ts_col.strings[i]
				// Guard the empty-string sentinel: if first_seen was never set
				// (e.g. previous rows had null timestamps), initialise it now.
				if entry.first_seen == "" || ts < entry.first_seen {
					delete(entry.first_seen, allocator)
					entry.first_seen, _ = strings.clone(ts, allocator)
				}
				if entry.last_seen == "" || ts > entry.last_seen {
					delete(entry.last_seen, allocator)
					entry.last_seen, _ = strings.clone(ts, allocator)
				}
			}
		}
		entry.count += 1
		buckets[entry.template] = entry
	}

	if len(buckets) == 0 { return nil }

	// Sort by count desc then template asc for determinism.
	keys := make([dynamic]string, 0, len(buckets), context.temp_allocator)
	for k in buckets { append(&keys, k) }
	slice.sort(keys[:])

	// Stable pre-sort then re-sort by count desc.
	patterns := make([dynamic]Frequent_Pattern, 0, len(buckets), context.temp_allocator)
	total := 0
	for k in keys {
		b := buckets[k]
		total += b.count
	}
	for k in keys {
		b := buckets[k]
		append(&patterns, Frequent_Pattern{
			level            = b.level,
			original_level   = b.original,
			message          = b.representative,
			message_template = b.template,
			count            = b.count,
			share            = f64(b.count) / f64(total),
			first_seen       = b.first_seen,
			last_seen        = b.last_seen,
		})
	}

	slice.sort_by(patterns[:], pattern_less)

	limit := frequent_limit
	if limit > len(patterns) { limit = len(patterns) }
	out := make([]Frequent_Pattern, limit, allocator)
	for i in 0..<limit { out[i] = patterns[i] }

	// Free patterns we did not retain.
	for i in limit..<len(patterns) {
		p := patterns[i]
		delete(p.original_level, allocator)
		delete(p.message, allocator)
		delete(p.message_template, allocator)
		delete(p.first_seen, allocator)
		delete(p.last_seen, allocator)
	}
	_ = report
	return out
}

@(private="file")
severity_less :: proc(a, b: Severity_Summary) -> bool {
	pa := log_level_priority(a.level)
	pb := log_level_priority(b.level)
	if pa != pb { return pa > pb }
	if a.count != b.count { return a.count > b.count }
	return int(a.level) < int(b.level)
}

// pattern_less orders frequent patterns so that:
//   1. Non-routine levels (Critical / Error / Warn / Unknown) come first,
//      regardless of count. RFC-0011 goal: "Rank errors above routine
//      informational volume."
//   2. Within the same routine-class, sort by count desc.
//   3. Ties broken by template ascending.
@(private="file")
pattern_less :: proc(a, b: Frequent_Pattern) -> bool {
	a_routine := is_routine_level(a.level)
	b_routine := is_routine_level(b.level)
	if a_routine != b_routine { return !a_routine }
	// Same routine-class: order non-routine by severity priority (Critical>Error>Warn>Unknown).
	if !a_routine {
		pa := log_level_priority(a.level)
		pb := log_level_priority(b.level)
		if pa != pb { return pa > pb }
	}
	if a.count != b.count { return a.count > b.count }
	return a.message_template < b.message_template
}

@(private="file")
find_level_column :: proc(table: ^snout_core.Table) -> ^snout_core.Column {
	for &col in table.columns {
		if col.kind != .String { continue }
		if hunt_ieq(col.name, "level") || hunt_ieq(col.name, "severity") ||
		   hunt_ieq(col.name, "loglevel") || hunt_ieq(col.name, "log_level") {
			return &col
		}
	}
	return nil
}

@(private="file")
find_message_column :: proc(table: ^snout_core.Table) -> ^snout_core.Column {
	for &col in table.columns {
		if col.kind != .String { continue }
		if hunt_ieq(col.name, "msg")     || hunt_ieq(col.name, "message") ||
		   hunt_ieq(col.name, "log")     || hunt_ieq(col.name, "body") {
			return &col
		}
	}
	return nil
}

@(private="file")
find_timestamp_column :: proc(table: ^snout_core.Table) -> ^snout_core.Column {
	for &col in table.columns {
		if col.kind != .Timestamp && col.kind != .String { continue }
		if hunt_ieq(col.name, "timestamp") || hunt_ieq(col.name, "ts") ||
		   hunt_ieq(col.name, "time") || hunt_ieq(col.name, "@timestamp") {
			return &col
		}
	}
	return nil
}
