package hunt

import "core:fmt"
import "core:io"
import "core:strings"
import snout_core "../core"

Output_Format :: enum {
	Table,
	Markdown,
	JSON,
	JSONL,
}

// Layout constants. Tuned for an 100-column terminal — comfortable on laptops,
// readable when copy-pasted into PR descriptions.
@(private="file") MAX_LINE_WIDTH :: 100
@(private="file") MAX_TEXT_WIDTH ::  72 // max width for templates / titles within a row
@(private="file") SEVERITY_STACK_WIDTH :: 48
@(private="file") VERBOSE_HISTOGRAM_WIDTH :: 48
@(private="file") VERBOSE_SAMPLE_MAX_CHARS :: 240
@(private="file") VERBOSE_METADATA_COLUMN :: 15
@(private="file") VERBOSE_SEPARATOR :: "────────────────────────────────────────────────────────────────────────"

render_report :: proc(
	writer: io.Writer,
	report: ^Hunt_Report,
	format: Output_Format,
	color: Color_Mode = .Never,
	verbose: bool = false,
) -> snout_core.Error {
	switch format {
	case .Table: return render_table(writer, report, color, verbose)
	case .Markdown: return render_markdown(writer, report, verbose)
	case .JSON:  return render_json(writer, report)
	case .JSONL: return render_jsonl(writer, report)
	}
	return .None
}

// ── Markdown format ─────────────────────────────────────────────────────────

render_markdown :: proc(
	writer: io.Writer,
	report: ^Hunt_Report,
	verbose: bool = false,
) -> snout_core.Error {
	fmt.wprintln(writer, "# Snout hunt report")

	if len(report.severity_summary) > 0 {
		fmt.wprintln(writer)
		fmt.wprintln(writer, "## Severity")
		fmt.wprintln(writer)
		fmt.wprintln(writer, "| Level | Events | Share |")
		fmt.wprintln(writer, "| --- | ---: | ---: |")
		for item in report.severity_summary {
			fmt.wprintfln(
				writer,
				"| **%s** | %d | %.1f%% |",
				strings.to_upper(log_level_name(item.level), context.temp_allocator),
				item.count,
				item.share * 100.0,
			)
		}
	}

	if len(report.frequent_patterns) > 0 {
		fmt.wprintln(writer)
		fmt.wprintln(writer, "## Frequent patterns")
		fmt.wprintln(writer)
		fmt.wprintln(writer, "| Level | Count | Time range | Pattern |")
		fmt.wprintln(writer, "| --- | ---: | --- | --- |")
		for pattern in report.frequent_patterns {
			message := markdown_inline(pattern.message_template)
			if message == "" { message = markdown_inline(pattern.message) }
			fmt.wprintfln(
				writer,
				"| **%s** | %d | %s | %s |",
				strings.to_upper(log_level_name(pattern.level), context.temp_allocator),
				pattern.count,
				markdown_inline(format_time_range_short(pattern.first_seen, pattern.last_seen)),
				message,
			)
		}
	}

	fmt.wprintln(writer)
	fmt.wprintfln(writer, "## Attention (%d %s)", len(report.findings), truffle_word(len(report.findings)))
	if len(report.findings) == 0 {
		fmt.wprintln(writer)
		fmt.wprintln(writer, "No attention findings.")
		return .None
	}

	for finding, i in report.findings {
		render_markdown_finding(writer, finding, i + 1, verbose)
	}
	return .None
}

@(private="file")
render_markdown_finding :: proc(
	writer: io.Writer,
	finding: Finding,
	position: int,
	verbose: bool,
) {
	tag, _ := finding_tag(finding)
	fmt.wprintln(writer)
	fmt.wprintfln(
		writer,
		"### %d. %s · score %d",
		position,
		tag,
		finding.score,
	)
	fmt.wprintln(writer)
	fmt.wprintfln(writer, "**%s**", markdown_inline(finding.title))

	count := finding_match_count(finding)
	total := finding_total_rows(finding)
	if count > 0 {
		if total > 0 {
			fmt.wprintfln(
				writer,
				"- **Events:** %d / %d (%.1f%%)",
				count,
				total,
				finding_share(finding) * 100.0,
			)
		} else {
			fmt.wprintfln(writer, "- **Events:** %d", count)
		}
	}
	if first, last, ok := finding_time_range(finding); ok {
		fmt.wprintfln(
			writer,
			"- **Time range:** %s",
			markdown_inline(format_time_range_long(first, last)),
		)
	}

	if !verbose {
		if finding.reproduce_command != "" {
			fmt.wprintfln(writer, "- **Reproduce:** `%s`", markdown_inline(finding.reproduce_command))
		}
		return
	}

	#partial switch evidence in finding.evidence {
	case Log_Pattern_Evidence:
		if len(evidence.histogram) > 0 {
			narrow := rebucket_histogram(evidence.histogram, VERBOSE_HISTOGRAM_WIDTH)
			fmt.wprintln(writer)
			fmt.wprintln(writer, "**Activity**")
			fmt.wprintln(writer)
			fmt.wprintln(writer, "```text")
			fmt.wprintfln(writer, "%s", render_sparkline(narrow))
			fmt.wprintfln(writer, "%s", timeline_axis(len(narrow)))
			fmt.wprintfln(
				writer,
				"%s",
				histogram_axis_3(evidence.range_start, evidence.range_end, len(narrow)),
			)
			fmt.wprintln(writer, "```")

			peak_idx, peak_value := histogram_peak(evidence.histogram)
			if peak_value > 0 {
				peak_at := bucket_time(
					evidence.range_start,
					evidence.range_end,
					peak_idx,
					len(evidence.histogram),
				)
				fmt.wprintfln(writer, "- **Peak:** %d events @ %s", peak_value, peak_at)
			}
		}
		if evidence.first_seen != "" {
			fmt.wprintfln(writer, "- **First match:** %s", evidence.first_seen)
			fmt.wprintfln(writer, "- **Last match:** %s", evidence.last_seen)
		}
		sample := finding_sample(finding)
		if sample != "" {
			fmt.wprintln(writer)
			fmt.wprintln(writer, "**Sample**")
			fmt.wprintln(writer)
			fmt.wprintln(writer, "```text")
			fmt.wprintfln(
				writer,
				"%s",
				truncate_one_line(sample, VERBOSE_SAMPLE_MAX_CHARS, context.temp_allocator),
			)
			fmt.wprintln(writer, "```")
		}
	case:
		fmt.wprintln(writer)
		fmt.wprintln(writer, "**Evidence**")
		fmt.wprintln(writer)
		render_markdown_evidence(writer, evidence)
	}

	if finding.reproduce_command != "" {
		fmt.wprintln(writer)
		fmt.wprintfln(
			writer,
			"**Reproduce (%s)**",
			reproduce_fidelity_name(finding.reproduce_fidelity),
		)
		fmt.wprintln(writer)
		fmt.wprintln(writer, "```sh")
		fmt.wprintfln(writer, "%s", finding.reproduce_command)
		fmt.wprintln(writer, "```")
	}
}

@(private="file")
render_markdown_evidence :: proc(writer: io.Writer, evidence: Evidence) {
	switch value in evidence {
	case Concentration_Evidence:
		fmt.wprintfln(writer, "- **Dimension:** %s = %s", value.dimension, markdown_inline(value.value))
		fmt.wprintfln(writer, "- **Coverage:** %d / %d rows (%.1f%%)", value.matching_rows, value.total_rows, value.share * 100.0)
	case Error_Hotspot_Evidence:
		fmt.wprintfln(writer, "- **Dimension:** %s = %s", value.dimension, markdown_inline(value.value))
		fmt.wprintfln(writer, "- **Impact:** %d / %d errors (%.1fx baseline)", value.matching_errors, value.total_errors, value.ratio)
	case Metric_Outlier_Evidence:
		fmt.wprintfln(writer, "- **Metric:** %s", value.metric)
		fmt.wprintfln(writer, "- **Distribution:** median %.2f · p95 %.2f · p99 %.2f · max %.2f", value.median, value.p95, value.p99, value.max_value)
	case Null_Anomaly_Evidence:
		fmt.wprintfln(writer, "- **Column:** %s", value.column)
		fmt.wprintfln(writer, "- **Nulls:** %d / %d rows (%.1f%%)", value.null_count, value.total_rows, value.null_ratio * 100.0)
	case Temporal_Shift_Evidence:
		fmt.wprintfln(writer, "- **Timestamp:** %s", value.timestamp_column)
		fmt.wprintfln(writer, "- **Shift:** %s (%d) → %s (%d) · %.1fx", value.before_bucket, value.before_count, value.after_bucket, value.after_count, value.ratio)
	case Top_Contributor_Evidence:
		fmt.wprintfln(writer, "- **Dimension:** %s = %s", value.dimension, markdown_inline(value.value))
		fmt.wprintfln(writer, "- **Primary metric:** %.1f%% of %s total", value.share * 100.0, value.metric)
		if len(value.extra_metrics) > 0 {
			fmt.wprintfln(writer, "- **Also dominates:**")
			for ms in value.extra_metrics {
				fmt.wprintfln(writer, "  - %s — %.0f%%", ms.metric, ms.share * 100.0)
			}
		}
	case Log_Pattern_Evidence:
	}
}

@(private="file")
markdown_inline :: proc(text: string) -> string {
	flat := truncate_one_line(text, 10_000, context.temp_allocator)
	b := strings.builder_make(context.temp_allocator)
	for i in 0..<len(flat) {
		byte := flat[i]
		switch byte {
		case '|':
			strings.write_string(&b, "\\|")
		case '`':
			strings.write_byte(&b, '\'')
		case:
			strings.write_byte(&b, byte)
		}
	}
	return strings.to_string(b)
}

// ── Table format ────────────────────────────────────────────────────────────

render_table :: proc(
	writer: io.Writer,
	report: ^Hunt_Report,
	color: Color_Mode = .Never,
	verbose: bool = false,
) -> snout_core.Error {
	mode := resolve_color_mode(color)

	if len(report.severity_summary) > 0 {
		render_severity_block(writer, report.severity_summary, mode)
	} else if report.schema_overview != nil {
		render_overview_block(writer, report.schema_overview, mode)
	}
	if len(report.frequent_patterns) > 0 {
		render_frequent_block(writer, report.frequent_patterns, mode)
	}
	render_findings_block(writer, report.findings, mode, verbose)
	return .None
}

// ── Overview (non-log inputs) ───────────────────────────────────────────────

@(private="file")
render_overview_block :: proc(writer: io.Writer, so: ^Schema_Overview, mode: Color_Mode) {
	write_section_header(writer, "overview", "────────", mode)

	// Line 1: row + column count with role breakdown.
	role_summary := overview_role_summary(so)
	fmt.wprint(writer, "  ")
	write_bold_word(writer, "rows", mode)
	fmt.wprintf(writer, " %s   ", format_number(so.row_count))
	write_bold_word(writer, "columns", mode)
	fmt.wprintf(writer, " %d  %s\n", so.column_count, role_summary)

	if so.time_range_start != "" {
		fmt.wprint(writer, "  ")
		write_bold_word(writer, "time", mode)
		fmt.wprintf(writer, " %s → %s\n", so.time_range_start, so.time_range_end)
	}

	if len(so.top_dimensions) > 0 {
		fmt.wprintln(writer)
		write_bold_word(writer, "  key dimensions", mode)
		fmt.wprintln(writer)
		for d in so.top_dimensions {
			fmt.wprintf(writer, "  %-18s  top: %-16s  (%.0f%%",
				d.name, d.top_value, d.top_share * 100.0)
			if d.distinct_count > 0 {
				fmt.wprintf(writer, ", %d distinct", d.distinct_count)
			}
			fmt.wprintln(writer, ")")
		}
	}

	if len(so.top_null_columns) > 0 {
		fmt.wprintln(writer)
		write_bold_word(writer, "  missing data", mode)
		fmt.wprintln(writer)
		for n in so.top_null_columns {
			fmt.wprintf(writer, "  %-18s  %d nulls (%.1f%%)\n",
				n.name, n.null_count, n.null_ratio * 100.0)
		}
	}

	fmt.wprintln(writer)
}

@(private="file")
overview_role_summary :: proc(so: ^Schema_Overview) -> string {
	parts := make([dynamic]string, 0, 4, context.temp_allocator)
	if so.timestamp_columns > 0 {
		append(&parts, fmt.tprintf("%d timestamp", so.timestamp_columns))
	}
	if so.dimension_columns > 0 {
		append(&parts, fmt.tprintf("%d dimension", so.dimension_columns))
	}
	if so.metric_columns > 0 {
		append(&parts, fmt.tprintf("%d metric", so.metric_columns))
	}
	if so.identifier_columns > 0 {
		append(&parts, fmt.tprintf("%d identifier", so.identifier_columns))
	}
	if len(parts) == 0 { return "" }
	body := strings.join(parts[:], " · ", context.temp_allocator)
	return fmt.tprintf("(%s)", body)
}

@(private="file")
format_number :: proc(n: int) -> string {
	// Insert thousand separators so 50000 → "50,000".
	if n < 1000 { return fmt.tprintf("%d", n) }
	negative := n < 0
	val := n if !negative else -n
	digits := fmt.tprintf("%d", val)
	out := strings.builder_make(context.temp_allocator)
	if negative { strings.write_byte(&out, '-') }
	remainder := len(digits) % 3
	for i in 0..<len(digits) {
		if i > 0 && (i - remainder) % 3 == 0 { strings.write_byte(&out, ',') }
		strings.write_byte(&out, digits[i])
	}
	return strings.to_string(out)
}

// ── Severity ────────────────────────────────────────────────────────────────

@(private="file")
render_severity_block :: proc(writer: io.Writer, items: []Severity_Summary, mode: Color_Mode) {
	write_section_header(writer, "severity", "────────", mode)
	render_severity_stack(writer, items, mode)
	fmt.wprintln(writer)

	max_count := 0
	for s in items {
		if s.count > max_count { max_count = s.count }
	}
	count_w := digits(max_count)
	if count_w < 3 { count_w = 3 }
	for s in items {
		count := fmt.tprintf("%d", s.count)
		pct   := fmt.tprintf("%.1f%%", s.share * 100.0)
		fmt.wprint(writer, "  ")
		write_colored_word(writer, pad_right(log_level_name(s.level), 7), s.level, mode)
		fmt.wprintfln(writer, "  %s  %6s", right_align(count, count_w), pct)
	}
	fmt.wprintln(writer)
}

@(private="file")
render_severity_stack :: proc(
	writer: io.Writer,
	items: []Severity_Summary,
	mode: Color_Mode,
) {
	if len(items) == 0 { return }
	total := 0
	for item in items { total += item.count }
	if total <= 0 { return }

	widths := make([]int, len(items), context.temp_allocator)
	used := 0
	for item, i in items {
		if item.count <= 0 { continue }
		widths[i] = item.count * SEVERITY_STACK_WIDTH / total
		if widths[i] == 0 { widths[i] = 1 }
		used += widths[i]
	}

	for used < SEVERITY_STACK_WIDTH {
		best := severity_largest_count_index(items)
		widths[best] += 1
		used += 1
	}
	for used > SEVERITY_STACK_WIDTH {
		best := severity_largest_reducible_index(widths, items)
		if best < 0 { break }
		widths[best] -= 1
		used -= 1
	}

	fmt.wprint(writer, "  ")
	write_bold_word(writer, pad_right("overview", 10), mode)
	write_muted_word(writer, "│", mode)
	for item, i in items {
		if widths[i] <= 0 { continue }
		cell := strings_repeat(severity_stack_glyph(item.level, mode), widths[i])
		write_colored_word(writer, cell, item.level, mode)
	}
	write_muted_word(writer, "│", mode)
	fmt.wprintfln(writer, "  %d events", total)
}

@(private="file")
severity_stack_glyph :: proc(level: Log_Level, mode: Color_Mode) -> string {
	if mode == .Always { return "█" }
	switch level {
	case .Critical: return "C"
	case .Error:    return "E"
	case .Warn:     return "W"
	case .Info:     return "I"
	case .Debug:    return "D"
	case .Trace:    return "T"
	case .Unknown:  return "?"
	}
	return "?"
}

@(private="file")
severity_largest_count_index :: proc(items: []Severity_Summary) -> int {
	best := 0
	for item, i in items {
		if item.count > items[best].count { best = i }
	}
	return best
}

@(private="file")
severity_largest_reducible_index :: proc(
	widths: []int,
	items: []Severity_Summary,
) -> int {
	best := -1
	for width, i in widths {
		if width <= 1 { continue }
		if best < 0 || width > widths[best] ||
		   (width == widths[best] && items[i].count > items[best].count) {
			best = i
		}
	}
	return best
}

// ── Frequent patterns ───────────────────────────────────────────────────────

@(private="file")
render_frequent_block :: proc(writer: io.Writer, items: []Frequent_Pattern, mode: Color_Mode) {
	write_section_header(writer, "frequent patterns", "─────────────────", mode)
	max_count := 0
	for p in items {
		if p.count > max_count { max_count = p.count }
	}
	count_w := digits(max_count)
	if count_w < 3 { count_w = 3 }
	any_time := false
	for p in items {
		if p.first_seen != "" { any_time = true; break }
	}
	// Reserve space for the time column when at least one row has timestamps.
	for p in items {
		label   := fmt.tprintf("[%s]", log_level_name(p.level))
		count   := fmt.tprintf("%d", p.count)
		preview := truncate_one_line(p.message_template, MAX_TEXT_WIDTH, context.temp_allocator)
		fmt.wprint(writer, "  ")
		write_colored_word(writer, pad_right(label, 9), p.level, mode)
		if any_time {
			fmt.wprintf(writer, " %s  %-15s  %s",
				right_align(count, count_w),
				format_time_range_short(p.first_seen, p.last_seen),
				preview)
		} else {
			fmt.wprintf(writer, " %s  %s", right_align(count, count_w), preview)
		}
		fmt.wprintln(writer)
	}
	fmt.wprintln(writer)
}

// ── Findings ────────────────────────────────────────────────────────────────

@(private="file")
render_findings_block :: proc(
	writer: io.Writer,
	findings: []Finding,
	mode: Color_Mode,
	verbose: bool,
) {
	n := len(findings)
	if n == 0 {
		fmt.wprintln(writer, "no attention findings")
		return
	}
	write_section_header(
		writer,
		fmt.tprintf("attention (%d %s)", n, truffle_word(n)),
		"────────────────────",
		mode,
	)

	if !verbose {
		render_findings_compact(writer, findings, mode)
		fmt.wprintln(writer)
		fmt.wprintln(writer, "Details: rerun with --verbose.")
		return
	}
	render_findings_verbose(writer, findings, mode)
}

@(private="file")
render_findings_compact :: proc(writer: io.Writer, findings: []Finding, mode: Color_Mode) {
	show_hist := false
	for f in findings {
		if e, ok := f.evidence.(Log_Pattern_Evidence); ok && len(e.histogram) > 0 {
			show_hist = true; break
		}
	}
	for f in findings {
		score := fmt.tprintf("[%d]", f.score)
		tag, level := finding_tag(f)
		count := finding_match_count(f)
		count_str := count > 0 ? fmt.tprintf("(%d×)", count) : ""
		hist_str := ""
		if show_hist {
			if e, ok := f.evidence.(Log_Pattern_Evidence); ok && len(e.histogram) > 0 {
				// Resample to a narrower bar so the compact line stays readable.
				narrow := rebucket_histogram(e.histogram, HISTOGRAM_BUCKETS)
				hist_str = render_compact_histogram(narrow, e.level, mode)
			} else {
				hist_str = strings_repeat(" ", HISTOGRAM_BUCKETS)
			}
		}
		text_budget := MAX_TEXT_WIDTH - len(count_str) - 1
		summary := finding_one_line(f, text_budget)
		fmt.wprintf(writer, "  %-5s ", score)
		write_colored_word(writer, pad_right(tag, 7), level, mode)
		if show_hist {
			// Bracket the bottom-aligned baseline so its time range is explicit.
			fmt.wprintf(writer, " │%s│ ", hist_str)
		}
		if count_str != "" {
			fmt.wprintfln(writer, " %s  %s", count_str, summary)
		} else {
			fmt.wprintfln(writer, " %s", summary)
		}
	}
}

@(private="file")
strings_repeat :: proc(s: string, n: int) -> string {
	b := strings.builder_make(context.temp_allocator)
	for _ in 0..<n { strings.write_string(&b, s) }
	return strings.to_string(b)
}

@(private="file")
render_findings_verbose :: proc(writer: io.Writer, findings: []Finding, mode: Color_Mode) {
	fmt.wprintln(writer)
	for f, i in findings {
		if i > 0 {
			fmt.wprintln(writer)
			write_muted_word(writer, VERBOSE_SEPARATOR, mode)
			fmt.wprintln(writer)
			fmt.wprintln(writer)
		}
		render_verbose_finding(writer, f, i + 1, len(findings), mode)
	}
	render_reproduce_footer(writer, findings, mode)
}

@(private="file")
write_section_header :: proc(
	writer: io.Writer,
	title, underline: string,
	mode: Color_Mode,
) {
	write_accent_word(writer, title, mode)
	fmt.wprintln(writer)
	write_muted_word(writer, underline, mode)
	fmt.wprintln(writer)
}

@(private="file")
render_verbose_finding :: proc(
	writer: io.Writer,
	f: Finding,
	position, total_findings: int,
	mode: Color_Mode,
) {
	tag, level := finding_tag(f)
	count := finding_match_count(f)
	total := finding_total_rows(f)
	share := finding_share(f)

	write_muted_word(writer, fmt.tprintf("%d/%d", position, total_findings), mode)
	fmt.wprint(writer, "  ")
	write_accent_word(writer, fmt.tprintf("[%d]", f.score), mode)
	fmt.wprint(writer, "  ")
	write_colored_word(writer, tag, level, mode)
	if count > 0 && total > 0 {
		fmt.wprintf(writer, "   %d events", count)
		write_muted_word(writer, fmt.tprintf("  ·  %.1f%%", share * 100.0), mode)
	}
	if first, last, ok := finding_time_range(f); ok {
		write_muted_word(
			writer,
			fmt.tprintf("  ·  %s", format_time_range_short(first, last)),
			mode,
		)
	}
	fmt.wprintln(writer)

	if f.title != "" {
		fmt.wprintln(writer)
		if mode == .Always { fmt.wprint(writer, ANSI_BOLD) }
		write_wrapped_block(writer, "  ", f.title, MAX_LINE_WIDTH)
		if mode == .Always { fmt.wprint(writer, ANSI_RESET) }
	}

	#partial switch e in f.evidence {
	case Log_Pattern_Evidence:
		if len(e.histogram) > 0 {
			narrow := rebucket_histogram(e.histogram, VERBOSE_HISTOGRAM_WIDTH)
			bar := render_sparkline(narrow)
			fmt.wprintln(writer)
			write_metadata_label(writer, "Activity", mode)
			write_bright_level_word(writer, bar, e.level, mode)
			fmt.wprintln(writer)
			fmt.wprint(writer, strings_repeat(" ", VERBOSE_METADATA_COLUMN))
			write_axis_word(writer, timeline_axis(len(narrow)), mode)
			fmt.wprintln(writer)
			fmt.wprint(writer, strings_repeat(" ", VERBOSE_METADATA_COLUMN))
			write_axis_word(
				writer,
				histogram_axis_3(e.range_start, e.range_end, len(narrow)),
				mode,
			)
			fmt.wprintln(writer)
			peak_idx, peak_val := histogram_peak(e.histogram)
			if peak_val > 0 {
				peak_at := bucket_time(e.range_start, e.range_end, peak_idx, len(e.histogram))
				write_peak_row(writer, peak_val, peak_at, mode)
			}
		}
		if e.first_seen != "" {
			write_metadata_row(writer, "First match", e.first_seen, mode)
			write_metadata_row(writer, "Last match", e.last_seen, mode)
		}
		sample := finding_sample(f)
		if sample != "" {
			write_sample_preview(writer, sample, mode)
		}
	case:
		write_evidence_lines(writer, f.evidence, mode)
	}
}

@(private="file")
timeline_axis :: proc(width: int) -> string {
	if width < 3 { return "|" }
	mid := width / 2
	b := strings.builder_make(context.temp_allocator)
	for i in 0..<width {
		if i == 0 || i == mid || i == width - 1 {
			strings.write_byte(&b, '|')
		} else {
			strings.write_string(&b, "·")
		}
	}
	return strings.to_string(b)
}

@(private="file")
write_metadata_label :: proc(writer: io.Writer, label: string, mode: Color_Mode) {
	fmt.wprint(writer, "  ")
	// Guarantee at least one trailing space so labels longer than the column
	// width never visually collide with the value.
	padded := pad_right(label, VERBOSE_METADATA_COLUMN - 2)
	if len(padded) == len(label) {
		padded = strings.concatenate({label, " "}, context.temp_allocator)
	}
	write_bold_word(writer, padded, mode)
}

@(private="file")
write_metadata_row :: proc(
	writer: io.Writer,
	label, value: string,
	mode: Color_Mode,
) {
	write_metadata_label(writer, label, mode)
	fmt.wprintfln(writer, "%s", value)
}

@(private="file")
write_peak_row :: proc(
	writer: io.Writer,
	count: int,
	time: string,
	mode: Color_Mode,
) {
	write_metadata_label(writer, "Peak", mode)
	fmt.wprintf(writer, "%d events ", count)
	write_accent_word(writer, "@", mode)
	fmt.wprintfln(writer, " %s", time)
}

// histogram_axis_3 places three labels — start, middle, end — under the
// sparkline so the user can read off any peak position visually.
@(private="file")
histogram_axis_3 :: proc(start, end: string, width: int) -> string {
	if start == "" || end == "" { return "" }
	left  := iso_month_day_clock(start)
	right := iso_month_day_clock(end)
	mid   := mid_label(start, end)
	if len(left) + len(mid) + len(right) + 2 >= width {
		return fmt.tprintf("%s → %s", left, right)
	}
	left_pad  := (width - len(left) - len(mid) - len(right)) / 2
	right_pad := width - len(left) - left_pad - len(mid) - len(right)
	b := strings.builder_make(context.temp_allocator)
	strings.write_string(&b, left)
	for _ in 0..<left_pad { strings.write_byte(&b, ' ') }
	strings.write_string(&b, mid)
	for _ in 0..<right_pad { strings.write_byte(&b, ' ') }
	strings.write_string(&b, right)
	return strings.to_string(b)
}

@(private="file")
mid_label :: proc(start, end: string) -> string {
	a := iso_to_seconds(start)
	b := iso_to_seconds(end)
	if a == 0 || b <= a { return "" }
	mid_sec := a + (b - a) / 2
	// reuse the same helper exposed from temporal.odin
	return seconds_to_iso_short_mid(mid_sec)
}

@(private="file")
seconds_to_iso_short_mid :: proc(total_sec: i64) -> string {
	// Local proxy because the temporal package function is file-private.
	// Re-implementation keeps the formatter colocated with the renderer.
	if total_sec <= 0 { return "" }
	t := total_sec
	day_seconds := i64(86400)
	days := t / day_seconds
	t %= day_seconds
	h  := int(t / 3600); t %= 3600
	mi := int(t / 60)

	y := int(days / 365)
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
		if i == 1 && ((y % 400 == 0) || (y % 100 != 0 && y % 4 == 0)) { mlen = 29 }
		if d < mlen { mo = i; break }
		d -= mlen
	}
	return fmt.tprintf("%02d-%02d %02d:%02d", mo + 1, d + 1, h, mi)
}

@(private="file")
finding_time_range :: proc(f: Finding) -> (first, last: string, ok: bool) {
	#partial switch e in f.evidence {
	case Log_Pattern_Evidence:
		if e.first_seen == "" { return "", "", false }
		return e.first_seen, e.last_seen, true
	case Temporal_Shift_Evidence:
		return e.before_bucket, e.after_bucket, true
	}
	return "", "", false
}

// format_time_range_short renders a time interval keeping at least the date
// visible — an hour without a day was useless for navigating real logs:
//   same instant       → "06-11 10:32"
//   same day           → "06-11 10:32–12:45"
//   different days     → "06-11 10:32 → 06-12 03:14"
@(private="file")
format_time_range_short :: proc(first, last: string) -> string {
	if first == "" { return "" }
	if last == "" || first == last { return iso_month_day_clock(first) }
	if len(first) >= 16 && len(last) >= 16 && first[:10] == last[:10] {
		// Same day → keep one MM-DD plus the two HH:MM points.
		return fmt.tprintf("%s %s–%s", first[5:10], first[11:16], last[11:16])
	}
	return fmt.tprintf("%s → %s", iso_month_day_clock(first), iso_month_day_clock(last))
}

// format_time_range_long always shows the full first → last span.
@(private="file")
format_time_range_long :: proc(first, last: string) -> string {
	if first == "" { return "" }
	if last == "" || first == last { return first }
	return fmt.tprintf("%s → %s", first, last)
}

@(private="file")
iso_clock :: proc(ts: string) -> string {
	if len(ts) >= 16 { return ts[11:16] }
	return ts
}

@(private="file")
iso_month_day_clock :: proc(ts: string) -> string {
	if len(ts) >= 16 {
		return fmt.tprintf("%s %s", ts[5:10], ts[11:16])
	}
	return ts
}

// finding_total_rows returns the denominator for the X / Y display.
@(private="file")
finding_total_rows :: proc(f: Finding) -> int {
	#partial switch e in f.evidence {
	case Log_Pattern_Evidence:     return e.total_rows
	case Error_Hotspot_Evidence:   return e.total_errors
	case Concentration_Evidence:   return e.total_rows
	case Null_Anomaly_Evidence:    return e.total_rows
	}
	return 0
}

@(private="file")
finding_share :: proc(f: Finding) -> f64 {
	#partial switch e in f.evidence {
	case Log_Pattern_Evidence:     return e.share
	case Error_Hotspot_Evidence:   return e.segment_rate
	case Concentration_Evidence:   return e.share
	case Null_Anomaly_Evidence:    return e.null_ratio
	case Top_Contributor_Evidence: return e.share
	}
	return 0
}

// finding_sample returns the message body worth showing in verbose mode.
// Empty when there is no representative beyond the title.
@(private="file")
finding_sample :: proc(f: Finding) -> string {
	#partial switch e in f.evidence {
	case Log_Pattern_Evidence:
		// Only meaningful when the template was variable-stripped — i.e. the
		// original message differs from the template.
		if e.representative_message == e.message_template { return "" }
		return e.representative_message
	}
	return ""
}

// write_wrapped_block writes `text` indented with `prefix`, wrapping at word
// boundaries so each output line stays ≤ `width` characters (including the
// prefix). Control chars are stripped.
@(private="file")
write_wrapped_block :: proc(writer: io.Writer, prefix, text: string, width: int) {
	flat := truncate_one_line(text, 10_000, context.temp_allocator) // strip control + tabs
	limit := width - len(prefix)
	if limit < 20 { limit = 20 }

	i := 0
	for i < len(flat) {
		end := i + limit
		if end >= len(flat) {
			fmt.wprintf(writer, "%s%s\n", prefix, flat[i:])
			break
		}
		// Try to break at the last space ≤ end. Falls back to a hard cut.
		brk := -1
		for j := end; j > i; j -= 1 {
			if flat[j] == ' ' { brk = j; break }
		}
		if brk <= i { brk = end }
		fmt.wprintf(writer, "%s%s\n", prefix, flat[i:brk])
		i = brk
		// Skip leading whitespace on the next line.
		for i < len(flat) && flat[i] == ' ' { i += 1 }
	}
}

@(private="file")
write_sample_preview :: proc(writer: io.Writer, sample: string, mode: Color_Mode) {
	preview := truncate_one_line(
		sample,
		VERBOSE_SAMPLE_MAX_CHARS,
		context.temp_allocator,
	)
	fmt.wprintln(writer)
	write_metadata_label(writer, "Sample", mode)
	write_wrapped_continuation(
		writer,
		preview,
		MAX_LINE_WIDTH,
		VERBOSE_METADATA_COLUMN,
	)
	if len(sample) > VERBOSE_SAMPLE_MAX_CHARS {
		fmt.wprint(writer, strings_repeat(" ", VERBOSE_METADATA_COLUMN))
		write_muted_word(
			writer,
			fmt.tprintf("… sample truncated (%d characters total)", len(sample)),
			mode,
		)
		fmt.wprintln(writer)
	}
}

@(private="file")
write_wrapped_continuation :: proc(
	writer: io.Writer,
	text: string,
	width, initial_column: int,
) {
	flat := truncate_one_line(text, 10_000, context.temp_allocator)
	first_limit := width - initial_column
	if len(flat) <= first_limit {
		fmt.wprintfln(writer, "%s", flat)
		return
	}

	first_break := find_wrap_break(flat, 0, first_limit)
	fmt.wprintfln(writer, "%s", flat[:first_break])
	i := first_break
	for i < len(flat) && flat[i] == ' ' { i += 1 }
	for i < len(flat) {
		limit := width - initial_column
		end := find_wrap_break(flat, i, limit)
		fmt.wprintf(writer, "%s%s\n", strings_repeat(" ", initial_column), flat[i:end])
		i = end
		for i < len(flat) && flat[i] == ' ' { i += 1 }
	}
}

@(private="file")
find_wrap_break :: proc(text: string, start, limit: int) -> int {
	end := start + limit
	if end >= len(text) { return len(text) }
	for j := end; j > start; j -= 1 {
		if text[j] == ' ' { return j }
	}
	return end
}

@(private="file")
write_wrapped_with_prefixes :: proc(
	writer: io.Writer,
	first_prefix, next_prefix, text: string,
	width: int,
) {
	flat := truncate_one_line(text, 10_000, context.temp_allocator)
	i := 0
	first := true
	for i < len(flat) {
		prefix := first ? first_prefix : next_prefix
		limit := width - len(prefix)
		if limit < 20 { limit = 20 }
		end := i + limit
		if end >= len(flat) {
			fmt.wprintf(writer, "%s%s\n", prefix, flat[i:])
			break
		}
		brk := -1
		for j := end; j > i; j -= 1 {
			if flat[j] == ' ' { brk = j; break }
		}
		if brk <= i { brk = end }
		fmt.wprintf(writer, "%s%s\n", prefix, flat[i:brk])
		i = brk
		for i < len(flat) && flat[i] == ' ' { i += 1 }
		first = false
	}
}

// render_reproduce_footer groups findings by reproduce command and prints each
// unique command once, listing which findings it covers. This keeps the
// command visible without repeating identical lines for every WARN finding.
@(private="file")
render_reproduce_footer :: proc(
	writer: io.Writer,
	findings: []Finding,
	mode: Color_Mode,
) {
	if len(findings) == 0 { return }

	// Collect (command, fidelity, score-list) grouped by command.
	Group :: struct {
		fidelity: Reproduce_Fidelity,
		findings: [dynamic]int,
	}
	groups := make(map[string]Group, 0, context.temp_allocator)
	defer {
		for _, g in groups { delete(g.findings) }
		delete(groups)
	}
	keys := make([dynamic]string, 0, len(findings), context.temp_allocator)

	for f, i in findings {
		if f.reproduce_command == "" { continue }
		entry, ok := groups[f.reproduce_command]
		if !ok {
			entry.fidelity = f.reproduce_fidelity
			entry.findings = make([dynamic]int, 0, 4, context.temp_allocator)
			append(&keys, f.reproduce_command)
		}
		append(&entry.findings, i + 1)
		groups[f.reproduce_command] = entry
	}
	if len(keys) == 0 { return }

	fmt.wprintln(writer)
	write_section_header(writer, "reproduce", "─────────", mode)
	for cmd in keys {
		g := groups[cmd]
		fid := reproduce_fidelity_name(g.fidelity)
		refs := format_finding_refs(g.findings[:])
		fmt.wprint(writer, "  ")
		write_accent_word(writer, fmt.tprintf("findings %s", refs), mode)
		write_muted_word(writer, fmt.tprintf("  ·  %s", fid), mode)
		fmt.wprintln(writer)
		fmt.wprint(writer, "  ")
		write_accent_word(writer, "$", mode)
		fmt.wprint(writer, " ")
		write_wrapped_continuation(writer, cmd, MAX_LINE_WIDTH, 4)
	}
}

@(private="file")
format_finding_refs :: proc(indexes: []int) -> string {
	if len(indexes) == 0 { return "" }
	if len(indexes) == 1 { return fmt.tprintf("%d", indexes[0]) }

	consecutive := true
	for i in 1..<len(indexes) {
		if indexes[i] != indexes[i-1] + 1 {
			consecutive = false
			break
		}
	}
	if consecutive {
		return fmt.tprintf("%d–%d", indexes[0], indexes[len(indexes)-1])
	}

	b := strings.builder_make(context.temp_allocator)
	for index, i in indexes {
		if i > 0 { strings.write_string(&b, ", ") }
		fmt.sbprintf(&b, "%d", index)
	}
	return strings.to_string(b)
}

@(private="file")
finding_tag :: proc(f: Finding) -> (string, Log_Level) {
	#partial switch e in f.evidence {
	case Log_Pattern_Evidence:
		return strings.to_upper(log_level_name(e.level), context.temp_allocator), e.level
	case Error_Hotspot_Evidence:
		return "ERROR",         .Error
	case Concentration_Evidence:
		return "CONC",          .Unknown
	case Metric_Outlier_Evidence:
		return "OUTLIER",       .Unknown
	case Null_Anomaly_Evidence:
		return "NULLS",         .Unknown
	case Temporal_Shift_Evidence:
		return "SPIKE",         .Unknown
	case Top_Contributor_Evidence:
		return "TOP",           .Unknown
	}
	return finding_type_name(f.type), .Unknown
}

@(private="file")
finding_match_count :: proc(f: Finding) -> int {
	#partial switch e in f.evidence {
	case Log_Pattern_Evidence:     return e.matching_rows
	case Error_Hotspot_Evidence:   return e.matching_errors
	case Concentration_Evidence:   return e.matching_rows
	case Null_Anomaly_Evidence:    return e.null_count
	case Temporal_Shift_Evidence:  return e.after_count
	}
	return 0
}

// finding_one_line picks the most informative one-line description for compact
// rendering. Strips the redundant "LEVEL pattern (N×):" prefix when present.
@(private="file")
finding_one_line :: proc(f: Finding, max_width: int) -> string {
	source := f.title
	#partial switch e in f.evidence {
	case Log_Pattern_Evidence:
		// Use the template directly; it is already normalized and lacks the
		// "LEVEL pattern" decoration.
		source = e.message_template
	}
	return truncate_one_line(source, max_width, context.temp_allocator)
}

// ── Evidence rendering (verbose mode) ──────────────────────────────────────

@(private="file")
write_evidence_lines :: proc(writer: io.Writer, e: Evidence, mode: Color_Mode) {
	switch v in e {
	case Concentration_Evidence:
		write_metadata_row(writer, "Dimension", fmt.tprintf("%s = %s", v.dimension, v.value), mode)
		write_metadata_row(
			writer,
			"Coverage",
			fmt.tprintf("%d / %d rows (%.1f%%)", v.matching_rows, v.total_rows, v.share * 100.0),
			mode,
		)
	case Error_Hotspot_Evidence:
		write_metadata_row(writer, "Dimension", fmt.tprintf("%s = %s", v.dimension, v.value), mode)
		write_metadata_row(
			writer,
			"Impact",
			fmt.tprintf(
				"%d / %d errors (%.1f%% vs %.1f%% baseline, %.1fx)",
				v.matching_errors,
				v.total_errors,
				v.segment_rate * 100.0,
				v.baseline_rate * 100.0,
				v.ratio,
			),
			mode,
		)
	case Metric_Outlier_Evidence:
		write_metadata_row(writer, "Metric", v.metric, mode)
		write_metadata_row(
			writer,
			"Distribution",
			fmt.tprintf(
				"median %.2f · p95 %.2f · p99 %.2f · max %.2f · %.1fx",
				v.median,
				v.p95,
				v.p99,
				v.max_value,
				v.ratio_p99_p50,
			),
			mode,
		)
	case Null_Anomaly_Evidence:
		write_metadata_row(writer, "Column", v.column, mode)
		write_metadata_row(
			writer,
			"Nulls",
			fmt.tprintf("%d / %d rows (%.1f%%)", v.null_count, v.total_rows, v.null_ratio * 100.0),
			mode,
		)
	case Temporal_Shift_Evidence:
		write_metadata_row(writer, "Timestamp", v.timestamp_column, mode)
		write_metadata_row(
			writer,
			"Shift",
			fmt.tprintf(
				"%s (%d) → %s (%d) · %.1fx",
				v.before_bucket,
				v.before_count,
				v.after_bucket,
				v.after_count,
				v.ratio,
			),
			mode,
		)
	case Top_Contributor_Evidence:
		write_metadata_row(writer, "Dimension", fmt.tprintf("%s = %s", v.dimension, v.value), mode)
		write_metadata_row(
			writer,
			"Primary",
			fmt.tprintf(
				"%.0f%% of %s total (%.2f / %.2f)",
				v.share * 100.0,
				v.metric,
				v.contribution,
				v.total,
			),
			mode,
		)
		if len(v.extra_metrics) > 0 {
			b := strings.builder_make(context.temp_allocator)
			max_inline := min(len(v.extra_metrics), 5)
			for i in 0..<max_inline {
				if i > 0 { strings.write_string(&b, ", ") }
				ms := v.extra_metrics[i]
				strings.write_string(&b, ms.metric)
				strings.write_string(&b, fmt.tprintf(" (%.0f%%)", ms.share * 100.0))
			}
			if len(v.extra_metrics) > max_inline {
				strings.write_string(&b, fmt.tprintf(", +%d more", len(v.extra_metrics) - max_inline))
			}
			write_metadata_row(writer, "Covers", strings.to_string(b), mode)
		}
	case Log_Pattern_Evidence:
		if v.representative_message != v.message_template {
			fmt.wprintfln(writer, "    sample: %s",
				truncate_one_line(v.representative_message, MAX_LINE_WIDTH - 14, context.temp_allocator))
		}
		fmt.wprintfln(writer, "    %d / %d rows (%.1f%%)",
			v.matching_rows, v.total_rows, v.share * 100.0)
		if v.first_seen != "" {
			fmt.wprintfln(writer, "    first: %s", v.first_seen)
			fmt.wprintfln(writer, "    last:  %s", v.last_seen)
		}
	}
}

// ── Helpers ─────────────────────────────────────────────────────────────────

@(private="file")
truffle_word :: proc(n: int) -> string {
	if n == 1 { return "finding" }
	return "findings"
}

@(private="file")
digits :: proc(n: int) -> int {
	if n <= 0 { return 1 }
	v := n
	out := 0
	for v > 0 {
		v /= 10
		out += 1
	}
	return out
}

@(private="file")
right_align :: proc(s: string, width: int) -> string {
	if len(s) >= width { return s }
	pad := width - len(s)
	b := strings.builder_make(context.temp_allocator)
	for _ in 0..<pad { strings.write_byte(&b, ' ') }
	strings.write_string(&b, s)
	return strings.to_string(b)
}

@(private="file")
pad_right :: proc(s: string, width: int) -> string {
	if len(s) >= width { return s }
	pad := width - len(s)
	b := strings.builder_make(context.temp_allocator)
	strings.write_string(&b, s)
	for _ in 0..<pad { strings.write_byte(&b, ' ') }
	return strings.to_string(b)
}

// truncate_one_line flattens whitespace and clips at max_width with a single
// ellipsis. Control chars are dropped, multi-line text is collapsed.
@(private="file")
truncate_one_line :: proc(s: string, max_width: int, allocator := context.allocator) -> string {
	b := strings.builder_make(allocator)
	prev_space := false
	for i in 0..<len(s) {
		c := s[i]
		if c == '\n' || c == '\r' || c == '\t' {
			if !prev_space { strings.write_byte(&b, ' '); prev_space = true }
			continue
		}
		if c < 0x20 { continue }
		strings.write_byte(&b, c)
		prev_space = c == ' '
	}
	flat := strings.to_string(b)
	if len(flat) <= max_width { return flat }
	// Truncate at the previous ASCII boundary so we don't split a UTF-8 byte.
	cut := max_width - 1
	for cut > 0 && (flat[cut] & 0xC0) == 0x80 { cut -= 1 }
	out := strings.concatenate({flat[:cut], "…"}, allocator)
	return out
}

// ── JSON / JSONL format ─────────────────────────────────────────────────────

render_json :: proc(writer: io.Writer, report: ^Hunt_Report) -> snout_core.Error {
	fmt.wprintf(writer, "{{\"schema_version\":%d", HUNT_SCHEMA_VERSION)
	if len(report.severity_summary) > 0 {
		fmt.wprint(writer, ",\"severity\":[")
		for s, i in report.severity_summary {
			if i > 0 { fmt.wprint(writer, ",") }
			fmt.wprintf(writer, `{{"level":%s,"count":%d,"share":%.6f}}`,
				json_string(log_level_name(s.level)), s.count, s.share)
		}
		fmt.wprint(writer, "]")
	}
	if len(report.frequent_patterns) > 0 {
		fmt.wprint(writer, ",\"frequent\":[")
		for p, i in report.frequent_patterns {
			if i > 0 { fmt.wprint(writer, ",") }
			write_frequent_pattern_json(writer, p)
		}
		fmt.wprint(writer, "]")
	}
	fmt.wprint(writer, ",\"findings\":[")
	for f, i in report.findings {
		if i > 0 { fmt.wprint(writer, ",") }
		write_finding_json(writer, f)
	}
	fmt.wprintln(writer, "]}")
	return .None
}

@(private="file")
write_frequent_pattern_json :: proc(writer: io.Writer, p: Frequent_Pattern) {
	fmt.wprintf(writer,
		`{{"level":%s,"original_level":%s,"message":%s,"template":%s,"count":%d,"share":%.6f,"first_seen":%s,"last_seen":%s}}`,
		json_string(log_level_name(p.level)),
		json_string(p.original_level),
		json_string(p.message),
		json_string(p.message_template),
		p.count,
		p.share,
		json_string(p.first_seen),
		json_string(p.last_seen),
	)
}

render_jsonl :: proc(writer: io.Writer, report: ^Hunt_Report) -> snout_core.Error {
	for f in report.findings {
		write_finding_json(writer, f)
		fmt.wprintln(writer)
	}
	return .None
}

@(private="file")
write_finding_json :: proc(writer: io.Writer, f: Finding) {
	fmt.wprintf(writer,
		`{{"type":"%s","score":%d,"confidence":%.4f,"title":%s,"summary":%s,"reproduce":%s,"reproduce_fidelity":"%s","evidence":`,
		finding_type_name(f.type),
		f.score,
		f.confidence,
		json_string(f.title),
		json_string(f.summary),
		json_string(f.reproduce_command),
		reproduce_fidelity_name(f.reproduce_fidelity),
	)
	write_evidence_json(writer, f.evidence)
	fmt.wprint(writer, "}")
}

@(private="file")
write_evidence_json :: proc(writer: io.Writer, e: Evidence) {
	switch v in e {
	case Concentration_Evidence:
		fmt.wprintf(writer, `{{"dimension":%s,"value":%s,"matching_rows":%d,"total_rows":%d,"share":%.6f}}`,
			json_string(v.dimension), json_string(v.value),
			v.matching_rows, v.total_rows, v.share)
	case Error_Hotspot_Evidence:
		fmt.wprintf(writer, `{{"dimension":%s,"value":%s,"error_column":%s,"matching_errors":%d,"total_errors":%d,"segment_rate":%.6f,"baseline_rate":%.6f,"ratio":%.6f}}`,
			json_string(v.dimension), json_string(v.value), json_string(v.error_column),
			v.matching_errors, v.total_errors,
			v.segment_rate, v.baseline_rate, v.ratio)
	case Metric_Outlier_Evidence:
		fmt.wprintf(writer, `{{"metric":%s,"median":%.6f,"p95":%.6f,"p99":%.6f,"max":%.6f,"ratio_p99_p50":%.6f}}`,
			json_string(v.metric), v.median, v.p95, v.p99, v.max_value, v.ratio_p99_p50)
	case Null_Anomaly_Evidence:
		fmt.wprintf(writer, `{{"column":%s,"null_count":%d,"total_rows":%d,"null_ratio":%.6f}}`,
			json_string(v.column), v.null_count, v.total_rows, v.null_ratio)
	case Temporal_Shift_Evidence:
		fmt.wprintf(writer, `{{"column":%s,"bucket_unit":%s,"before_bucket":%s,"after_bucket":%s,"before_count":%d,"after_count":%d,"ratio":%.6f}}`,
			json_string(v.timestamp_column), json_string(v.bucket_unit),
			json_string(v.before_bucket), json_string(v.after_bucket),
			v.before_count, v.after_count, v.ratio)
	case Top_Contributor_Evidence:
		fmt.wprintf(writer,
			`{{"dimension":%s,"value":%s,"metric":%s,"contribution":%.6f,"total":%.6f,"share":%.6f,"extra_metrics":[`,
			json_string(v.dimension), json_string(v.value), json_string(v.metric),
			v.contribution, v.total, v.share)
		for ms, i in v.extra_metrics {
			if i > 0 { fmt.wprint(writer, ",") }
			fmt.wprintf(writer, `{{"metric":%s,"share":%.6f}}`,
				json_string(ms.metric), ms.share)
		}
		fmt.wprint(writer, "]}")
	case Log_Pattern_Evidence:
		fmt.wprintf(writer,
			`{{"level":%s,"original_level":%s,"template":%s,"representative":%s,"fragment":%s,"matching_rows":%d,"total_rows":%d,"share":%.6f,"first_seen":%s,"last_seen":%s,"range_start":%s,"range_end":%s,"histogram":`,
			json_string(v.level == .Critical ? "critical" : log_level_name(v.level)),
			json_string(v.original_level),
			json_string(v.message_template),
			json_string(v.representative_message),
			json_string(v.contains_fragment),
			v.matching_rows, v.total_rows, v.share,
			json_string(v.first_seen), json_string(v.last_seen),
			json_string(v.range_start), json_string(v.range_end))
		fmt.wprint(writer, "[")
		for h, i in v.histogram {
			if i > 0 { fmt.wprint(writer, ",") }
			fmt.wprintf(writer, "%d", h)
		}
		fmt.wprint(writer, "]}")
	case:
		fmt.wprint(writer, "null")
	}
}

// json_string returns a JSON-escaped, quoted form of s in temp memory.
@(private="file")
json_string :: proc(s: string) -> string {
	b := strings.builder_make(context.temp_allocator)
	strings.write_byte(&b, '"')
	for r in s {
		switch r {
		case '"':  strings.write_string(&b, `\"`)
		case '\\': strings.write_string(&b, `\\`)
		case '\n': strings.write_string(&b, `\n`)
		case '\r': strings.write_string(&b, `\r`)
		case '\t': strings.write_string(&b, `\t`)
		case:
			if r < 0x20 {
				strings.write_string(&b, fmt.tprintf(`\u%04x`, int(r)))
			} else {
				strings.write_rune(&b, r)
			}
		}
	}
	strings.write_byte(&b, '"')
	return strings.to_string(b)
}
