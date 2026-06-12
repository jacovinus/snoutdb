package hunt

import "core:math"

// compose_score combines the four signals into a single 0..100 integer score.
// Weights are fixed per D4 in TASK-0018.
compose_score :: proc(effect_size, coverage, confidence, novelty: f64) -> int {
	clamped_effect     := clamp_01_100(effect_size)
	clamped_coverage   := clamp_01_100(coverage)
	clamped_confidence := clamp_01_100(confidence)
	clamped_novelty    := clamp_01_100(novelty)

	raw := clamped_effect * 0.40 +
	       clamped_coverage * 0.25 +
	       clamped_confidence * 0.20 +
	       clamped_novelty * 0.15

	rounded := math.round(raw)
	if rounded < 0 { return 0 }
	if rounded > 100 { return 100 }
	return int(rounded)
}

// confidence_from_rows returns a confidence value in [0.0, 1.0] saturating at
// roughly 30+ matching rows. The shape is sqrt-based to give partial credit to
// small samples without overcrediting them.
confidence_from_rows :: proc(matching_rows: int) -> f64 {
	if matching_rows <= 0 { return 0.0 }
	v := math.sqrt(f64(matching_rows) / 30.0)
	if v > 1.0 { return 1.0 }
	return v
}

// confidence_score returns the 0..100 confidence component used by compose_score.
confidence_score :: proc(matching_rows: int) -> f64 {
	return confidence_from_rows(matching_rows) * 100.0
}

// coverage_score returns matching_rows / total_rows * 100, clamped.
coverage_score :: proc(matching_rows, total_rows: int) -> f64 {
	if total_rows <= 0 { return 0.0 }
	return f64(matching_rows) / f64(total_rows) * 100.0
}

@(private="file")
clamp_01_100 :: proc(v: f64) -> f64 {
	if v < 0 { return 0 }
	if v > 100 { return 100 }
	return v
}
