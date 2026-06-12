package hunt

import "core:fmt"
import "core:strings"

// Compact uses 32 buckets — wide enough to spot bursts, narrow enough to fit
// next to the message in 100-column terminals. Verbose uses 64 for a richer
// picture (the user explicitly asked for detail).
HISTOGRAM_BUCKETS         :: 32
HISTOGRAM_BUCKETS_VERBOSE :: 64

// SPARKLINE_LEVELS — Unicode block characters scaled by bucket density.
// Empty space for zero (not `·`): it preserves the visual contrast between
// "no events here" and "small spike here", which `·` blurred out.
@(private="file")
SPARKLINE_LEVELS := [?]string{" ", "▁", "▂", "▃", "▄", "▅", "▆", "▇", "█"}

// iso_to_seconds returns a monotonic second count from an ISO-8601 timestamp.
// Only the date and time portion are read (timezone suffix ignored), which is
// fine for comparing timestamps within the same file.
// Inputs shorter than 19 chars (YYYY-MM-DDTHH:MM:SS) return 0.
iso_to_seconds :: proc(s: string) -> i64 {
	if len(s) < 19 { return 0 }
	y  := parse_uint2or4(s, 0, 4)
	mo := parse_uint2or4(s, 5, 7)
	d  := parse_uint2or4(s, 8, 10)
	h  := parse_uint2or4(s, 11, 13)
	mi := parse_uint2or4(s, 14, 16)
	se := parse_uint2or4(s, 17, 19)
	if y < 0 || mo < 1 || mo > 12 || d < 1 { return 0 }

	// Days from year 0 (Julian-ish approximation, accurate enough for monotonic
	// ordering inside any sensible log window).
	days := i64(y) * 365 + i64(y) / 4 - i64(y) / 100 + i64(y) / 400
	months := [?]int{31, 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31}
	for i in 0..<(mo - 1) { days += i64(months[i]) }
	if mo > 2 && is_leap_year(y) { days += 1 }
	days += i64(d - 1)
	return days * 86_400 + i64(h) * 3600 + i64(mi) * 60 + i64(se)
}

@(private="file")
parse_uint2or4 :: proc(s: string, start, end: int) -> int {
	if end > len(s) { return -1 }
	n := 0
	for i in start..<end {
		c := s[i]
		if c < '0' || c > '9' { return -1 }
		n = n * 10 + int(c - '0')
	}
	return n
}

@(private="file")
is_leap_year :: proc(y: int) -> bool {
	if y % 400 == 0 { return true }
	if y % 100 == 0 { return false }
	return y % 4 == 0
}

// timestamp_to_bucket maps `ts` into one of `n` bins covering `[start, end]`.
// Returns -1 when the input falls outside the range or is unparseable.
timestamp_to_bucket :: proc(ts: string, start, end: i64, n: int) -> int {
	if n <= 0 || end <= start { return -1 }
	v := iso_to_seconds(ts)
	if v == 0 { return -1 }
	if v < start || v > end { return -1 }
	// Clamp at n-1 for the rightmost edge case.
	idx := int((v - start) * i64(n) / (end - start + 1))
	if idx >= n { idx = n - 1 }
	return idx
}

// compute_time_range scans the timestamp column for the file-wide ISO-8601
// first/last extremes. Returns "", "" when the column is empty or absent.
compute_time_range :: proc(strings_col: []string, null_mask: []bool, nullable: bool) -> (string, string) {
	first := ""
	last  := ""
	for v, i in strings_col {
		if nullable && null_mask[i] { continue }
		if v == "" { continue }
		if first == "" || v < first { first = v }
		if last  == "" || v > last  { last  = v }
	}
	return first, last
}

// render_sparkline renders `buckets` as a Unicode block sparkline. Empty
// buckets are rendered as a space. The bar height is scaled to the largest
// bucket value so single events still register as a minimum-height bar.
render_sparkline :: proc(buckets: []int) -> string {
	if len(buckets) == 0 { return "" }
	max_val := 0
	for c in buckets {
		if c > max_val { max_val = c }
	}
	b := strings.builder_make(context.temp_allocator)
	if max_val == 0 {
		for _ in 0..<len(buckets) { strings.write_string(&b, SPARKLINE_LEVELS[0]) }
		return strings.to_string(b)
	}
	last := len(SPARKLINE_LEVELS) - 1
	for c in buckets {
		if c == 0 {
			strings.write_string(&b, SPARKLINE_LEVELS[0])
			continue
		}
		idx := 1 + (c - 1) * (last - 1) / max_val
		if idx > last { idx = last }
		strings.write_string(&b, SPARKLINE_LEVELS[idx])
	}
	return strings.to_string(b)
}

// render_sparkline_colored wraps the sparkline in the level color. When the bar
// would otherwise be a single tall column (max_val concentrated in one bucket)
// we promote it to bold so the burst really pops.
render_sparkline_colored :: proc(buckets: []int, l: Log_Level, mode: Color_Mode) -> string {
	bar := render_sparkline(buckets)
	if mode != .Always { return bar }
	return fmt.tprintf("%s%s%s", level_color(l, mode), bar, color_reset(mode))
}

// render_compact_histogram renders a bottom-aligned baseline for the compact
// report, replacing underscores with severity-colored activity bars.
render_compact_histogram :: proc(
	buckets: []int,
	l: Log_Level,
	mode: Color_Mode,
) -> string {
	if len(buckets) == 0 { return "" }

	max_val := 0
	for count in buckets {
		if count > max_val { max_val = count }
	}

	b := strings.builder_make(context.temp_allocator)
	last := len(SPARKLINE_LEVELS) - 1
	for count in buckets {
		if count == 0 {
			if mode == .Always { strings.write_string(&b, ANSI_BRIGHT_WHITE) }
			strings.write_string(&b, "_")
			if mode == .Always { strings.write_string(&b, ANSI_RESET) }
			continue
		}

		idx := 1 + (count - 1) * (last - 1) / max_val
		if idx > last { idx = last }
		if mode == .Always { strings.write_string(&b, level_bright_color(l, mode)) }
		strings.write_string(&b, SPARKLINE_LEVELS[idx])
		if mode == .Always { strings.write_string(&b, ANSI_RESET) }
	}
	return strings.to_string(b)
}

// histogram_peak returns the bucket index of the maximum count and its value.
// Returns (-1, 0) when the histogram is empty.
histogram_peak :: proc(buckets: []int) -> (idx, value: int) {
	idx = -1
	for c, i in buckets {
		if c > value { value = c; idx = i }
	}
	return
}

// bucket_time returns the ISO timestamp at the centre of `bucket_idx` for a
// file ranging from `start` to `end`. Used to label "max @ time".
bucket_time :: proc(start, end: string, bucket_idx, num_buckets: int) -> string {
	if num_buckets <= 0 { return "" }
	a := iso_to_seconds(start)
	b := iso_to_seconds(end)
	if a == 0 || b <= a { return start }
	mid := a + (b - a) * i64(bucket_idx) / i64(num_buckets)
	return seconds_to_iso_short(mid)
}

// rebucket_histogram resamples `src` (length N) into a destination of length M.
// Empty destinations or M == N short-circuit. Total mass is conserved so a
// concentrated burst stays a single tall bar rather than smearing.
rebucket_histogram :: proc(src: []int, m: int) -> []int {
	if m <= 0 { return nil }
	out := make([]int, m, context.temp_allocator)
	if len(src) == 0 { return out }
	if len(src) == m {
		copy(out, src); return out
	}
	for v, i in src {
		if v == 0 { continue }
		dst := i * m / len(src)
		if dst >= m { dst = m - 1 }
		out[dst] += v
	}
	return out
}

// seconds_to_iso_short turns a monotonic second-count back into a `MM-DD HH:MM`
// label. The conversion mirrors iso_to_seconds and is approximate by design.
@(private="file")
seconds_to_iso_short :: proc(total_sec: i64) -> string {
	if total_sec <= 0 { return "" }
	t := total_sec
	day_seconds := i64(86400)
	days := t / day_seconds
	t %= day_seconds
	h  := int(t / 3600); t %= 3600
	mi := int(t / 60)

	// Walk back from `days` to (year, month, day).
	y := int(days / 365)
	// crude correction: subtract the leap-year offset
	corr := y / 4 - y / 100 + y / 400
	d := int(days) - y * 365 - corr
	if d < 0 {
		y -= 1
		corr = y / 4 - y / 100 + y / 400
		d = int(days) - y * 365 - corr
	}
	months := [?]int{31, 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31}
	mo := 0
	for i in 0..<12 {
		mlen := months[i]
		if i == 1 && is_leap_year(y) { mlen = 29 }
		if d < mlen { mo = i; break }
		d -= mlen
	}
	return fmt.tprintf("%02d-%02d %02d:%02d", mo + 1, d + 1, h, mi)
}
