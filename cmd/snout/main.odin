package main

import "core:fmt"
import "core:os"
import "core:time"
import snout_core "../../core"

main :: proc() {
	if len(os.args) < 2 {
		print_usage()
		os.exit(1)
	}
	if os.args[1] == "version" || os.args[1] == "--version" || os.args[1] == "-v" {
		fmt.printf("SnoutDB %s\n", snout_core.version())
		return
	}

	request_start := time.tick_now()
	defer print_processing_time(request_start)

	if os.args[1] == "sniff" {
		run_sniff_command(os.args[1:])
		return
	}
	if os.args[1] == "hunt" {
		run_hunt_command(os.args[1:])
		return
	}
	if len(os.args) < 3 {
		print_usage()
		os.exit(1)
	}
	if os.args[1] == "-f" {
		run_group_command(os.args[2:])
		return
	}

	switch os.args[1] {
	case "csv-info":     run_csv_info()
	case "csv-avg":      run_csv_avg()
	case "csv-stats":    run_csv_stats()
	case "csv-import":   run_csv_import()
	case "jsonl-info":   run_jsonl_info()
	case "jsonl-stats":  run_jsonl_stats()
	case "jsonl-import": run_jsonl_import()
	case "info":         run_info()
	case "stats":        run_stats()
	case "append":       run_append()
	case "consolidate":  run_consolidate()
	case "compact":      run_compact()
	case "transform":    run_transform()
	case "rollup":       run_rollup()
	case "log-info":     run_log_info()
	case "log-import":   run_log_import()
	case:
		print_usage()
		os.exit(1)
	}
}

print_usage :: proc() {
	fmt.eprintln("usage:")
	fmt.eprintln("  snout version")
	fmt.eprintln("  snout csv-info <file.csv>")
	fmt.eprintln("  snout csv-avg <file.csv> <column>")
	fmt.eprintln("  snout csv-stats <file.csv> <column>")
	fmt.eprintln("  snout csv-import <file.csv> <file.snout>")
	fmt.eprintln("  snout jsonl-info <file.jsonl>")
	fmt.eprintln("  snout jsonl-stats <file.jsonl> <column>")
	fmt.eprintln("  snout jsonl-import <file.jsonl> <file.snout>")
	fmt.eprintln("  snout info <file.snout>")
	fmt.eprintln("  snout stats <file.snout> <column>")
	fmt.eprintln("  snout append <base.snout> <extra.snout> [<extra2.snout>...] <output.snout>")
	fmt.eprintln("  snout consolidate <a.snout> <b.snout> [<c.snout>...] <output.snout>")
	fmt.eprintln("  snout compact <input.snout> <output.snout>")
	fmt.eprintln("  snout rollup <src1.snout> [src2.snout...] <output.snout> group=col,col -- agg=col ...")
	fmt.eprintln("  snout transform <input> <output.snout> op=args [op=args ...]")
	fmt.eprintln("  snout log-info <file.log> [--format clf|combined|logfmt|syslog|app|regex] [--pattern \"...\"] [--strict]")
	fmt.eprintln("  snout log-import <file.log> <out.snout> [--format ...] [--strict]")
	fmt.eprintln("  snout hunt <input> [--limit <n>] [--min-score <n>] [--format table|json|jsonl] [--verbose] [-o report.txt|report.md]")
	fmt.eprintln("  snout sniff -f <input> [--format table|json] [--top <n>] [--max-distinct <n>] [--suggestions <n>]")
	fmt.eprintln("              [--logformat clf|combined|logfmt|syslog|app|regex] [--logpattern \"...\"] [--strict]")
	fmt.eprintln("  snout -f <input> group=<column>[,<column>...] -- <aggregate>=<column|rows>... [options]")
	fmt.eprintln("    --where <column> <eq|ne|lt|le|gt|ge|contains|not-contains|icontains|is-null|not-null> [value]")
	fmt.eprintln("    --sort <group-column|aggregate=column> <asc|desc>")
	fmt.eprintln("    --limit <rows>")
	fmt.eprintln("    --format <table|csv|json|jsonl>")
	fmt.eprintln("    --logformat <clf|combined|logfmt|syslog|app|regex>")
	fmt.eprintln("    --logpattern <pattern>")
	fmt.eprintln("    --strict")
}
