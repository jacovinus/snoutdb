package hunt

// Log_Level is the normalized severity scale used by Hunt for ranking and
// rendering. Mapping from raw level strings is intentionally case-insensitive
// and alias-aware (`err` → Error, `warn` → Warn, etc.).
Log_Level :: enum {
	Unknown,
	Trace,
	Debug,
	Info,
	Warn,
	Error,
	Critical,
}

// log_level_priority returns a 0..6 score used to rank findings whose evidence
// includes a level. Higher = more attention-worthy.
log_level_priority :: proc(l: Log_Level) -> int {
	switch l {
	case .Critical: return 6
	case .Error:    return 5
	case .Warn:     return 4
	case .Info:     return 2
	case .Debug:    return 1
	case .Trace:    return 1
	case .Unknown:  return 3 // potentially interesting, depends on context
	}
	return 0
}

// log_level_name returns the canonical lowercase label.
log_level_name :: proc(l: Log_Level) -> string {
	switch l {
	case .Critical: return "critical"
	case .Error:    return "error"
	case .Warn:     return "warn"
	case .Info:     return "info"
	case .Debug:    return "debug"
	case .Trace:    return "trace"
	case .Unknown:  return "unknown"
	}
	return "unknown"
}

// normalize_level maps a raw level string to a Log_Level. ASCII case-insensitive,
// allocation-free. Returns .Unknown for anything not in the alias table.
//
// Recognised aliases (case-insensitive):
//   Critical → critical, fatal, severe, crit
//   Error    → error, err, fail, failure
//   Warn     → warn, wrn, warning
//   Info     → info, inf, default, notice
//   Debug    → debug, dbg, verbose
//   Trace    → trace
normalize_level :: proc(s: string) -> Log_Level {
	switch len(s) {
	case 3:
		if hunt_ieq(s, "err") { return .Error }
		if hunt_ieq(s, "wrn") { return .Warn }
		if hunt_ieq(s, "inf") { return .Info }
		if hunt_ieq(s, "dbg") { return .Debug }
	case 4:
		if hunt_ieq(s, "warn") { return .Warn }
		if hunt_ieq(s, "info") { return .Info }
		if hunt_ieq(s, "crit") { return .Critical }
		if hunt_ieq(s, "fail") { return .Error }
	case 5:
		if hunt_ieq(s, "error") { return .Error }
		if hunt_ieq(s, "fatal") { return .Critical }
		if hunt_ieq(s, "debug") { return .Debug }
		if hunt_ieq(s, "trace") { return .Trace }
	case 6:
		if hunt_ieq(s, "severe") { return .Critical }
		if hunt_ieq(s, "notice") { return .Info }
	case 7:
		if hunt_ieq(s, "warning") { return .Warn }
		if hunt_ieq(s, "failure") { return .Error }
		if hunt_ieq(s, "default") { return .Info } // Adobe UXP "Default" = informational
		if hunt_ieq(s, "verbose") { return .Debug }
	case 8:
		if hunt_ieq(s, "critical") { return .Critical }
	}
	return .Unknown
}

// is_routine_level returns true for levels that should not produce attention
// findings on their own (they remain useful as frequent-context summary).
is_routine_level :: proc(l: Log_Level) -> bool {
	#partial switch l {
	case .Info, .Debug, .Trace:
		return true
	}
	return false
}

// hunt_ieq is a package-internal ASCII-case-insensitive string equality test.
hunt_ieq :: proc(a, b: string) -> bool {
	if len(a) != len(b) { return false }
	for i in 0..<len(a) {
		ca := a[i]
		cb := b[i]
		if ca >= 'A' && ca <= 'Z' { ca += 32 }
		if cb >= 'A' && cb <= 'Z' { cb += 32 }
		if ca != cb { return false }
	}
	return true
}
