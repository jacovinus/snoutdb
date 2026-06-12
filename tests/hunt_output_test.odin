package tests

import "core:fmt"
import "core:strings"
import "core:testing"
import snout_core "../core"
import hunt "../hunt"
import tablefmt "../terminal"

@(test)
hunt_verbose_ranking_reserves_space_for_info_patterns :: proc(t: ^testing.T) {
	findings := make([]hunt.Finding, 12)
	defer delete(findings)
	for i in 0..<10 {
		findings[i] = hunt.Finding{
			type      = .Concentration,
			score     = 90 - i,
			title     = fmt.tprintf("priority-%d", i),
			dedup_key = fmt.tprintf("priority-%d", i),
			evidence  = hunt.Concentration_Evidence{},
		}
	}
	for i in 10..<12 {
		findings[i] = hunt.Finding{
			type      = .Log_Pattern,
			score     = 63,
			title     = fmt.tprintf("info-%d", i),
			dedup_key = fmt.tprintf("info-%d", i),
			evidence = hunt.Log_Pattern_Evidence{
				level = .Info,
			},
		}
	}

	config := hunt.DEFAULT_HUNT_CONFIG
	config.limit = 10
	config.include_info_patterns = true
	ranked := hunt.rank_findings(findings, config)
	defer delete(ranked)

	testing.expect_value(t, len(ranked), 10)
	info_count := 0
	for finding in ranked {
		if evidence, ok := finding.evidence.(hunt.Log_Pattern_Evidence); ok &&
		   evidence.level == .Info {
			info_count += 1
		}
	}
	testing.expect_value(t, info_count, 2)
}

@(test)
hunt_verbose_ranking_orders_log_levels_by_severity :: proc(t: ^testing.T) {
	levels := [?]hunt.Log_Level{
		.Info,
		.Warn,
		.Trace,
		.Error,
		.Debug,
		.Critical,
	}
	findings := make([]hunt.Finding, len(levels))
	defer delete(findings)
	for level, i in levels {
		findings[i] = hunt.Finding{
			type      = .Log_Pattern,
			score     = 70,
			title     = hunt.log_level_name(level),
			dedup_key = hunt.log_level_name(level),
			evidence  = hunt.Log_Pattern_Evidence{level = level},
		}
	}

	config := hunt.DEFAULT_HUNT_CONFIG
	config.limit = 0
	config.include_info_patterns = true
	ranked := hunt.rank_findings(findings, config)
	defer delete(ranked)

	expected := [?]hunt.Log_Level{
		.Critical,
		.Error,
		.Warn,
		.Info,
		.Debug,
		.Trace,
	}
	testing.expect_value(t, len(ranked), len(expected))
	for finding, i in ranked {
		evidence := finding.evidence.(hunt.Log_Pattern_Evidence)
		testing.expect_value(t, evidence.level, expected[i])
	}
}

@(test)
hunt_severity_summary_renders_stacked_overview :: proc(t: ^testing.T) {
	severity := [?]hunt.Severity_Summary{
		{level = .Error, count = 22, share = 0.042},
		{level = .Warn, count = 73, share = 0.138},
		{level = .Info, count = 432, share = 0.818},
		{level = .Debug, count = 1, share = 0.002},
	}
	report := hunt.Hunt_Report{severity_summary = severity[:]}

	builder := strings.builder_make()
	defer strings.builder_destroy(&builder)
	err := hunt.render_report(
		strings.to_writer(&builder),
		&report,
		.Table,
		.Never,
		false,
	)
	testing.expect_value(t, err, snout_core.Error.None)
	rendered := strings.to_string(builder)
	testing.expect(t, strings.contains(rendered, "overview"))
	testing.expect(t, strings.contains(rendered, "│EE"))
	testing.expect(t, strings.contains(rendered, "WW"))
	testing.expect(t, strings.contains(rendered, "II"))
	testing.expect(t, strings.contains(rendered, "D│  528 events"))
}

@(test)
hunt_compact_output_keeps_count_before_pattern :: proc(t: ^testing.T) {
	histogram := [?]int{3, 0, 1, 0}
	findings := [?]hunt.Finding{
		{
			type  = .Log_Pattern,
			score = 82,
			title = "Failed request {number}",
			evidence = hunt.Log_Pattern_Evidence{
				level                  = .Error,
				message_template       = "Failed request {number}",
				representative_message = "Failed request 42",
				matching_rows          = 4,
				total_rows             = 100,
				share                  = 0.04,
				histogram              = histogram[:],
			},
		},
	}
	report := hunt.Hunt_Report{
		row_count = 100,
		findings  = findings[:],
	}

	builder := strings.builder_make()
	defer strings.builder_destroy(&builder)
	err := hunt.render_report(
		strings.to_writer(&builder),
		&report,
		.Table,
		.Never,
		false,
	)
	testing.expect_value(t, err, snout_core.Error.None)
	rendered := strings.to_string(builder)
	testing.expect(t, strings.contains(rendered, "(4×)  Failed request {number}"))
	testing.expect(t, strings.contains(rendered, "│"))
	testing.expect(t, strings.contains(rendered, "____"))
	testing.expect(t, strings.contains(rendered, "Details: rerun with --verbose."))
}

@(test)
hunt_compact_histogram_keeps_axis_and_level_color_readable :: proc(t: ^testing.T) {
	histogram := [?]int{3, 0, 1, 0}
	findings := [?]hunt.Finding{
		{
			type  = .Log_Pattern,
			score = 82,
			title = "Failed request",
			evidence = hunt.Log_Pattern_Evidence{
				level                  = .Error,
				message_template       = "Failed request",
				representative_message = "Failed request",
				matching_rows          = 4,
				total_rows             = 100,
				share                  = 0.04,
				histogram              = histogram[:],
			},
		},
	}
	report := hunt.Hunt_Report{row_count = 100, findings = findings[:]}

	builder := strings.builder_make()
	defer strings.builder_destroy(&builder)
	err := hunt.render_report(
		strings.to_writer(&builder),
		&report,
		.Table,
		.Always,
		false,
	)
	testing.expect_value(t, err, snout_core.Error.None)
	rendered := strings.to_string(builder)
	testing.expect(t, strings.contains(rendered, hunt.ANSI_BRIGHT_WHITE + "_"))
	testing.expect(
		t,
		strings.contains(rendered, hunt.ANSI_BOLD + hunt.ANSI_BRIGHT_RED),
	)
}

@(test)
hunt_verbose_output_bounds_samples_and_identifies_findings :: proc(t: ^testing.T) {
	sample_builder := strings.builder_make()
	defer strings.builder_destroy(&sample_builder)
	strings.write_string(&sample_builder, `{"payload":"`)
	for _ in 0..<600 {
		strings.write_byte(&sample_builder, 'x')
	}
	strings.write_string(&sample_builder, `"}`)
	long_sample := strings.to_string(sample_builder)

	histogram := [?]int{3, 0, 0, 1, 0, 2, 0, 0}
	command :=
		"./snout -f application.log group=level -- count=rows --where level eq error --limit 10"
	findings := [?]hunt.Finding{
		{
			type              = .Log_Pattern,
			score             = 82,
			title             = "Failed request {number}",
			reproduce_command = command,
			reproduce_fidelity = .Approximate,
			evidence = hunt.Log_Pattern_Evidence{
				level                  = .Error,
				message_template       = "Failed request {number}",
				representative_message = long_sample,
				matching_rows          = 6,
				total_rows             = 100,
				share                  = 0.06,
				first_seen             = "2026-06-12T10:00:00Z",
				last_seen              = "2026-06-12T11:00:00Z",
				range_start            = "2026-06-12T09:00:00Z",
				range_end              = "2026-06-12T12:00:00Z",
				histogram              = histogram[:],
			},
		},
		{
			type              = .Log_Pattern,
			score             = 75,
			title             = "Connection closed",
			reproduce_command = command,
			reproduce_fidelity = .Approximate,
			evidence = hunt.Log_Pattern_Evidence{
				level                  = .Error,
				message_template       = "Connection closed",
				representative_message = "Connection closed",
				matching_rows          = 2,
				total_rows             = 100,
				share                  = 0.02,
			},
		},
	}
	report := hunt.Hunt_Report{
		row_count = 100,
		findings  = findings[:],
	}

	builder := strings.builder_make()
	defer strings.builder_destroy(&builder)
	err := hunt.render_report(
		strings.to_writer(&builder),
		&report,
		.Table,
		.Never,
		true,
	)
	testing.expect_value(t, err, snout_core.Error.None)
	rendered := strings.to_string(builder)

	testing.expect(t, strings.contains(rendered, "1/2  [82]  ERROR"))
	testing.expect(t, strings.contains(rendered, "2/2  [75]  ERROR"))
	testing.expect(t, strings.contains(rendered, "Activity  "))
	testing.expect(t, strings.contains(rendered, "|····"))
	testing.expect(t, strings.contains(rendered, "Peak      "))
	testing.expect(t, strings.contains(rendered, "First match"))
	testing.expect(t, strings.contains(rendered, "Last match "))
	testing.expect(t, strings.contains(rendered, "sample truncated"))
	testing.expect(t, strings.contains(rendered, "findings 1–2  ·  approximate"))

	remaining := rendered
	for line in strings.split_lines_iterator(&remaining) {
		testing.expect(
			t,
			tablefmt.display_width(line) <= 100,
			"verbose output line exceeds layout width",
		)
	}
}

@(test)
hunt_verbose_color_uses_accent_without_replacing_level_color :: proc(t: ^testing.T) {
	histogram := [?]int{2, 0, 1}
	findings := [?]hunt.Finding{
		{
			type  = .Log_Pattern,
			score = 91,
			title = "Database unavailable",
			evidence = hunt.Log_Pattern_Evidence{
				level                  = .Error,
				message_template       = "Database unavailable",
				representative_message = "Database unavailable",
				matching_rows          = 3,
				total_rows             = 10,
				share                  = 0.3,
				range_start            = "2026-06-12T10:00:00Z",
				range_end              = "2026-06-12T11:00:00Z",
				histogram              = histogram[:],
			},
		},
	}
	report := hunt.Hunt_Report{findings = findings[:]}

	builder := strings.builder_make()
	defer strings.builder_destroy(&builder)
	err := hunt.render_report(
		strings.to_writer(&builder),
		&report,
		.Table,
		.Always,
		true,
	)
	testing.expect_value(t, err, snout_core.Error.None)
	rendered := strings.to_string(builder)
	testing.expect(t, strings.contains(rendered, hunt.ANSI_CYAN))
	testing.expect(t, strings.contains(rendered, hunt.ANSI_RED))
	testing.expect(t, strings.contains(rendered, hunt.ANSI_BOLD))
	testing.expect(t, strings.contains(rendered, hunt.ANSI_BRIGHT_WHITE))
	testing.expect(t, strings.contains(rendered, hunt.ANSI_BRIGHT_RED))
}

@(test)
hunt_markdown_output_formats_report_sections :: proc(t: ^testing.T) {
	histogram := [?]int{3, 0, 1, 0}
	severity := [?]hunt.Severity_Summary{
		{level = .Error, count = 4, share = 1.0},
	}
	findings := [?]hunt.Finding{
		{
			type              = .Log_Pattern,
			score             = 82,
			title             = "Failed request",
			reproduce_command = "./snout -f app.log group=level -- count=rows",
			evidence = hunt.Log_Pattern_Evidence{
				level                  = .Error,
				message_template       = "Failed request",
				representative_message = "Failed request 42",
				matching_rows          = 4,
				total_rows             = 100,
				share                  = 0.04,
				first_seen             = "2026-06-12T10:00:00Z",
				last_seen              = "2026-06-12T11:00:00Z",
				range_start            = "2026-06-12T09:00:00Z",
				range_end              = "2026-06-12T12:00:00Z",
				histogram              = histogram[:],
			},
		},
	}
	report := hunt.Hunt_Report{
		severity_summary = severity[:],
		findings         = findings[:],
	}

	builder := strings.builder_make()
	defer strings.builder_destroy(&builder)
	err := hunt.render_report(
		strings.to_writer(&builder),
		&report,
		.Markdown,
		.Never,
		true,
	)
	testing.expect_value(t, err, snout_core.Error.None)
	rendered := strings.to_string(builder)
	testing.expect(t, strings.contains(rendered, "# Snout hunt report"))
	testing.expect(t, strings.contains(rendered, "| **ERROR** | 4 | 100.0% |"))
	testing.expect(t, strings.contains(rendered, "### 1. ERROR · score 82"))
	testing.expect(t, strings.contains(rendered, "**Activity**"))
	testing.expect(t, strings.contains(rendered, "```sh"))
}
