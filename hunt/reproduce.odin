package hunt

import "base:runtime"
import "core:fmt"
import "core:strings"

// shell_quote returns a POSIX-shell-safe single-quoted form of s. Embedded
// single quotes are escaped via the canonical '\'' trick.
shell_quote :: proc(s: string, allocator := context.allocator) -> string {
	b := strings.builder_make(allocator)
	strings.write_byte(&b, '\'')
	for r in s {
		if r == '\'' {
			strings.write_string(&b, `'\''`)
		} else {
			strings.write_rune(&b, r)
		}
	}
	strings.write_byte(&b, '\'')
	return strings.to_string(b)
}

// shell_quote_if_needed only quotes when the value contains a shell-special
// character. Used by the table renderer where readability matters more than
// strict portability.
shell_quote_if_needed :: proc(s: string, allocator := context.allocator) -> string {
	if needs_shell_quoting(s) {
		return shell_quote(s, allocator)
	}
	out, _ := strings.clone(s, allocator)
	return out
}

@(private="file")
needs_shell_quoting :: proc(s: string) -> bool {
	if len(s) == 0 { return true }
	for r in s {
		switch r {
		case 'a'..='z', 'A'..='Z', '0'..='9', '_', '-', '.', '/', ':':
			continue
		case:
			return true
		}
	}
	return false
}

// ── Command builder ────────────────────────────────────────────────────────

// Repro_Builder accumulates pre-quoted argv-style tokens joined with single
// spaces. `repro_arg` quotes the value; `repro_literal` does not.
Repro_Builder :: struct {
	parts:     [dynamic]string,
	allocator: runtime.Allocator,
}

repro_builder_make :: proc(allocator := context.allocator) -> Repro_Builder {
	return Repro_Builder{
		parts     = make([dynamic]string, 0, 16, allocator),
		allocator = allocator,
	}
}

repro_literal :: proc(b: ^Repro_Builder, s: string) {
	cloned, _ := strings.clone(s, b.allocator)
	append(&b.parts, cloned)
}

repro_arg :: proc(b: ^Repro_Builder, s: string) {
	append(&b.parts, shell_quote_if_needed(s, b.allocator))
}

repro_finish :: proc(b: ^Repro_Builder, allocator := context.allocator) -> string {
	out := strings.join(b.parts[:], " ", allocator)
	for p in b.parts { delete(p, b.allocator) }
	delete(b.parts)
	return out
}

// ── Where / Sort clause types ───────────────────────────────────────────────

Where_Op :: enum {
	Eq,
	Ne,
	Lt,
	Le,
	Gt,
	Ge,
	Is_Null,
	Not_Null,
}

Where_Clause :: struct {
	column: string,
	op:     Where_Op,
	value:  string, // ignored when op == .Is_Null or .Not_Null
}

Sort_Dir :: enum {
	Asc,
	Desc,
}

Sort_Clause :: struct {
	key: string,
	dir: Sort_Dir,
}

where_op_name :: proc(op: Where_Op) -> string {
	switch op {
	case .Eq:        return "eq"
	case .Ne:        return "ne"
	case .Lt:        return "lt"
	case .Le:        return "le"
	case .Gt:        return "gt"
	case .Ge:        return "ge"
	case .Is_Null:   return "is-null"
	case .Not_Null:  return "not-null"
	}
	return "eq"
}

sort_dir_name :: proc(d: Sort_Dir) -> string {
	if d == .Desc { return "desc" }
	return "asc"
}

// ── High-level command constructors ────────────────────────────────────────

// query_repro builds `./snout -f <source> group=<col> -- <agg>` plus optional
// --where / --sort / --limit clauses, with shell-safe quoting throughout.
// Appends --logformat/--logpattern when the source is a log file.
query_repro :: proc(
	config: Hunt_Config,
	group_col: string,
	aggregates: []string,
	filters: []Where_Clause,
	sort_terms: []Sort_Clause,
	limit: int,
	allocator := context.allocator,
) -> string {
	b := repro_builder_make(allocator)

	repro_literal(&b, "./snout")
	repro_literal(&b, "-f")
	repro_arg(&b, config.source_path)

	if group_col != "" {
		group_token := strings.concatenate({"group=", group_col}, context.temp_allocator)
		repro_literal(&b, group_token)
	}
	repro_literal(&b, "--")
	for agg in aggregates { repro_literal(&b, agg) }

	for w in filters {
		repro_literal(&b, "--where")
		repro_literal(&b, w.column)
		repro_literal(&b, where_op_name(w.op))
		if w.op != .Is_Null && w.op != .Not_Null {
			repro_arg(&b, w.value)
		}
	}
	for t in sort_terms {
		repro_literal(&b, "--sort")
		repro_literal(&b, t.key)
		repro_literal(&b, sort_dir_name(t.dir))
	}
	if limit > 0 {
		repro_literal(&b, "--limit")
		repro_literal(&b, fmt.tprintf("%d", limit))
	}

	append_log_options(&b, config)

	return repro_finish(&b, allocator)
}

// stats_repro builds a stats-style command appropriate for the source kind.
stats_repro :: proc(
	config: Hunt_Config,
	column: string,
	allocator := context.allocator,
) -> string {
	cmd := "stats"
	switch config.source_kind {
	case .CSV:   cmd = "csv-stats"
	case .JSONL: cmd = "jsonl-stats"
	case .Snout: cmd = "stats"
	case .Log:
		// Logs have no dedicated stats command; emit a query instead.
		avg_arg := strings.concatenate({"avg=", column}, context.temp_allocator)
		p95_arg := strings.concatenate({"p95=", column}, context.temp_allocator)
		p99_arg := strings.concatenate({"p99=", column}, context.temp_allocator)
		return query_repro(
			config, column,
			[]string{avg_arg, p95_arg, p99_arg, "count=rows"},
			[]Where_Clause{}, []Sort_Clause{}, 0, allocator,
		)
	case .Unknown:
		cmd = "stats"
	}
	b := repro_builder_make(allocator)
	repro_literal(&b, "./snout")
	repro_literal(&b, cmd)
	repro_arg(&b, config.source_path)
	repro_arg(&b, column)
	return repro_finish(&b, allocator)
}

@(private="file")
append_log_options :: proc(b: ^Repro_Builder, c: Hunt_Config) {
	if c.source_kind != .Log { return }
	if c.log_format_name == "" { return }
	repro_literal(b, "--logformat")
	repro_literal(b, c.log_format_name)
	if c.log_pattern != "" {
		repro_literal(b, "--logpattern")
		repro_arg(b, c.log_pattern)
	}
}
