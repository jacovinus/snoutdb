package hunt

import "core:fmt"
import "core:math"
import "core:strings"
import snout_core "../core"
import aggregate "../exec"

METRIC_RATIO_P99_P50 :: 10.0
METRIC_RATIO_MAX_P95 :: 5.0

// run_metric_outlier flags metric columns with very heavy upper tails. Triggered
// when p99/p50 >= 10 OR max/p95 >= 5. Constants (std_dev == 0) are skipped.
run_metric_outlier :: proc(
	pool: ^[dynamic]Finding,
	candidates: Candidate_Set,
	table: ^snout_core.Table,
	config: Hunt_Config,
	allocator := context.allocator,
) {
	for cand in candidates.metrics {
		p := cand.profile
		if p.kind != .Int64 && p.kind != .Float64 { continue }
		if !p.numeric.valid { continue }
		if p.numeric.std_dev == 0 { continue }
		if p.non_null_count < config.min_rows_per_finding { continue }

		stats, err := aggregate.numeric_stats(table, p.name)
		if err != .None { continue }
		if stats.p50 == 0 { continue }

		ratio_p99_p50 := stats.p99 / stats.p50
		ratio_max_p95 := f64(0)
		if stats.p95 != 0 {
			ratio_max_p95 = stats.max / stats.p95
		}

		// Determine which trigger fired and report it accurately in the title.
		trigger_p99 := ratio_p99_p50 >= METRIC_RATIO_P99_P50
		trigger_max := ratio_max_p95 >= METRIC_RATIO_MAX_P95
		if !trigger_p99 && !trigger_max { continue }

		// Use the stronger ratio for scoring; describe the firing trigger in the title.
		best_ratio  := ratio_p99_p50
		title_label := "p99 vs median"
		if ratio_max_p95 > best_ratio {
			best_ratio  = ratio_max_p95
			title_label = "max vs p95"
		}

		effect := math.log10(best_ratio) * 50.0
		if effect < 0 { effect = 0 }
		if effect > 100 { effect = 100 }
		coverage := f64(80)
		conf     := confidence_score(stats.count)
		novelty  := f64(60)
		score    := compose_score(effect, coverage, conf, novelty)

		if score < config.min_score { continue }

		metric_clone, _ := strings.clone(p.name, allocator)
		title := fmt.aprintf(
			"%s has a heavy tail (%s = %.1fx)",
			p.name, title_label, best_ratio,
			allocator = allocator,
		)
		summary := fmt.aprintf(
			"%s shows a heavy upper tail (median=%.2f, p95=%.2f, p99=%.2f, max=%.2f).",
			p.name, stats.p50, stats.p95, stats.p99, stats.max,
			allocator = allocator,
		)
		repro := stats_repro(config, p.name, allocator)
		dedup := fmt.aprintf("metric_outlier:%s", p.name, allocator = allocator)

		append(pool, Finding{
			type               = .Metric_Outlier,
			score              = score,
			confidence         = confidence_from_rows(stats.count),
			title              = title,
			summary            = summary,
			reproduce_command  = repro,
			reproduce_fidelity = .Exact,
			dedup_key          = dedup,
			novelty            = novelty,
			evidence = Metric_Outlier_Evidence{
				metric        = metric_clone,
				median        = stats.p50,
				p95           = stats.p95,
				p99           = stats.p99,
				max_value     = stats.max,
				ratio_p99_p50 = ratio_p99_p50,
			},
		})
	}
}
