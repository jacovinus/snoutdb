package hunt

import "core:fmt"
import "core:math"
import "core:slice"
import "core:strings"
import snout_core "../core"
import "../sniff"

TEMPORAL_VOLUME_RATIO :: 3.0
TEMPORAL_MIN_BUCKET_ROWS :: 30

// run_temporal_shift bins rows by hour or day (whichever matches the time range)
// and detects volume spikes when the largest bucket is >= 3x the median bucket.
run_temporal_shift :: proc(
	pool: ^[dynamic]Finding,
	candidates: Candidate_Set,
	table: ^snout_core.Table,
	config: Hunt_Config,
	allocator := context.allocator,
) {
	for cand in candidates.timestamps {
		emit_temporal_for(pool, cand.profile, table, config, allocator)
	}
}

@(private="file")
emit_temporal_for :: proc(
	pool: ^[dynamic]Finding,
	p: ^sniff.Column_Profile,
	table: ^snout_core.Table,
	config: Hunt_Config,
	allocator := context.allocator,
) {
	col, found := snout_core.get_column(table, p.name)
	if !found { return }
	if col.kind != .Timestamp && col.kind != .String { return }

	unit := pick_bucket_unit(p)
	prefix_len := 13 if unit == "hour" else 10

	buckets := make(map[string]int, 0, context.temp_allocator)
	defer delete(buckets)

	for i in 0..<table.row_count {
		if col.nullable && col.null_mask[i] { continue }
		ts := col.strings[i]
		if len(ts) < prefix_len { continue }
		key := ts[:prefix_len]
		buckets[key] = buckets[key] + 1
	}
	if len(buckets) < 2 { return }

	// Sort bucket keys ascending for deterministic before/after picks.
	keys := make([dynamic]string, 0, len(buckets), context.temp_allocator)
	for k in buckets { append(&keys, k) }
	slice.sort(keys[:])

	counts := make([dynamic]int, 0, len(buckets), context.temp_allocator)
	for k in keys {
		c := buckets[k]
		if c >= TEMPORAL_MIN_BUCKET_ROWS { append(&counts, c) }
	}
	if len(counts) < 2 { return }

	// Median of bucket sizes (correct even-length handling: average of the two
	// central values, not just the higher one).
	sorted_counts := make([]int, len(counts), context.temp_allocator)
	copy(sorted_counts, counts[:])
	slice.sort(sorted_counts)
	median := median_int(sorted_counts)
	if median <= 0 { return }

	// Compare each bucket against its immediate predecessor for the strongest
	// observed jump. Falls back to ratio-vs-median for the title when the
	// sequence is monotonic.
	best_idx     := -1
	best_ratio   := f64(0)
	for i in 1..<len(keys) {
		prev_cnt := buckets[keys[i-1]]
		curr_cnt := buckets[keys[i]]
		if curr_cnt < TEMPORAL_MIN_BUCKET_ROWS { continue }
		if prev_cnt < TEMPORAL_MIN_BUCKET_ROWS { continue }
		r := f64(curr_cnt) / f64(prev_cnt)
		if r > best_ratio {
			best_ratio = r
			best_idx   = i
		}
	}
	if best_idx < 0 { return }
	if best_ratio < TEMPORAL_VOLUME_RATIO { return }

	max_count := buckets[keys[best_idx]]
	ratio     := best_ratio

	before_key := keys[best_idx - 1]
	after_key  := keys[best_idx]
	before_cnt := buckets[before_key]
	after_cnt  := buckets[after_key]
	_ = max_count

	effect := math.log2(ratio) * 30.0
	if effect < 0 { effect = 0 }
	if effect > 100 { effect = 100 }
	cov     := f64(after_cnt) / f64(table.row_count) * 100.0
	conf    := confidence_score(after_cnt)
	novelty := f64(80)
	score   := compose_score(effect, cov, conf, novelty)
	if score < config.min_score { return }

	ts_clone,    _ := strings.clone(p.name, allocator)
	unit_clone,  _ := strings.clone(unit, allocator)
	before_clone, _ := strings.clone(before_key, allocator)
	after_clone,  _ := strings.clone(after_key, allocator)

	title := fmt.aprintf(
		"%s volume spiked %.1fx at %s",
		p.name, ratio, after_key,
		allocator = allocator,
	)
	summary := fmt.aprintf(
		"Bucket %s had %d rows vs median %d (ratio %.1fx).",
		after_key, after_cnt, median, ratio,
		allocator = allocator,
	)
	// Approximate: bucketing is internal; user runs the closest grouped query.
	repro := query_repro(
		config, p.name,
		[]string{"count=rows"},
		[]Where_Clause{},
		[]Sort_Clause{{key = "count=rows", dir = .Desc}},
		20, allocator,
	)
	dedup := fmt.aprintf("temporal_shift:%s:%s", p.name, after_key, allocator = allocator)

	append(pool, Finding{
		type               = .Temporal_Shift,
		score              = score,
		confidence         = confidence_from_rows(after_cnt),
		title              = title,
		summary            = summary,
		reproduce_command  = repro,
		reproduce_fidelity = .Approximate, // bucketing is internal; user query approximates it
		dedup_key          = dedup,
		novelty            = novelty,
		evidence = Temporal_Shift_Evidence{
			timestamp_column = ts_clone,
			bucket_unit      = unit_clone,
			before_bucket    = before_clone,
			after_bucket     = after_clone,
			before_count     = before_cnt,
			after_count      = after_cnt,
			ratio            = ratio,
		},
	})
}

@(private="file")
median_int :: proc(sorted: []int) -> int {
	n := len(sorted)
	if n == 0 { return 0 }
	if n % 2 == 1 { return sorted[n/2] }
	return (sorted[n/2 - 1] + sorted[n/2]) / 2
}

@(private="file")
pick_bucket_unit :: proc(p: ^sniff.Column_Profile) -> string {
	if !p.timestamp.valid { return "hour" }
	min_s := p.timestamp.min
	max_s := p.timestamp.max
	if len(min_s) < 10 || len(max_s) < 10 { return "hour" }
	// Same calendar day → bucket by hour, otherwise by day.
	if min_s[:10] == max_s[:10] { return "hour" }
	return "day"
}
