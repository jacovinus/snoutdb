package hunt

import "core:io"
import "core:fmt"
import "core:os"
import "core:sys/posix"

// Color_Mode controls ANSI escape emission. CLI flag `--color` maps directly.
Color_Mode :: enum {
	Auto,    // emit only when writer is a TTY and NO_COLOR is unset
	Always,
	Never,
}

// resolve_color_mode resolves Auto by inspecting stdout's TTY status and the
// NO_COLOR environment variable.
resolve_color_mode :: proc(requested: Color_Mode) -> Color_Mode {
	if requested == .Always { return .Always }
	if requested == .Never  { return .Never }
	// Auto path.
	if os.get_env("NO_COLOR", context.temp_allocator) != "" { return .Never }
	if !is_stdout_tty() { return .Never }
	return .Always
}

// ── ANSI emission ──────────────────────────────────────────────────────────

ANSI_RESET   :: "\x1b[0m"
ANSI_BOLD    :: "\x1b[1m"
ANSI_RED     :: "\x1b[31m"
ANSI_GREEN   :: "\x1b[32m"
ANSI_YELLOW  :: "\x1b[33m"
ANSI_BLUE    :: "\x1b[34m"
ANSI_MAGENTA :: "\x1b[35m"
ANSI_CYAN    :: "\x1b[36m"
ANSI_BRIGHT_WHITE :: "\x1b[97m"
ANSI_BRIGHT_RED     :: "\x1b[91m"
ANSI_BRIGHT_GREEN   :: "\x1b[92m"
ANSI_BRIGHT_YELLOW  :: "\x1b[93m"
ANSI_BRIGHT_BLUE    :: "\x1b[94m"
ANSI_BRIGHT_MAGENTA :: "\x1b[95m"
ANSI_BRIGHT_CYAN    :: "\x1b[96m"

// level_color returns an ANSI sequence for the given level. Empty string when
// color is disabled. Semantics:
//   critical → bold magenta (loud)
//   error    → bold red     (attention)
//   warn     → yellow       (caution)
//   info     → green        (healthy / nominal)
//   debug    → bright cyan  (diagnostic)
//   trace    → bright blue
//   unknown  → bright white
level_color :: proc(l: Log_Level, mode: Color_Mode) -> string {
	if mode != .Always { return "" }
	switch l {
	case .Critical: return ANSI_BOLD + ANSI_MAGENTA
	case .Error:    return ANSI_BOLD + ANSI_RED
	case .Warn:     return ANSI_YELLOW
	case .Info:     return ANSI_GREEN
	case .Debug:    return ANSI_BRIGHT_CYAN
	case .Trace:    return ANSI_BRIGHT_BLUE
	case .Unknown:  return ANSI_BRIGHT_WHITE
	}
	return ""
}

level_bright_color :: proc(l: Log_Level, mode: Color_Mode) -> string {
	if mode != .Always { return "" }
	switch l {
	case .Critical: return ANSI_BOLD + ANSI_BRIGHT_MAGENTA
	case .Error:    return ANSI_BOLD + ANSI_BRIGHT_RED
	case .Warn:     return ANSI_BOLD + ANSI_BRIGHT_YELLOW
	case .Info:     return ANSI_BOLD + ANSI_BRIGHT_GREEN
	case .Debug:    return ANSI_BOLD + ANSI_BRIGHT_CYAN
	case .Trace:    return ANSI_BOLD + ANSI_BRIGHT_BLUE
	case .Unknown:  return ANSI_BOLD + ANSI_BRIGHT_WHITE
	}
	return ""
}

color_reset :: proc(mode: Color_Mode) -> string {
	if mode != .Always { return "" }
	return ANSI_RESET
}

@(private="file")
is_stdout_tty :: proc() -> bool {
	// CI environments report a TTY but rarely want color.
	if os.get_env("CI", context.temp_allocator) != "" { return false }
	term := os.get_env("TERM", context.temp_allocator)
	if term == "dumb" { return false }
	// Real check: file descriptor 1 (stdout) must be a terminal device.
	// posix.isatty returns true only when stdout is connected to a TTY —
	// it returns false when stdout has been redirected to a file or pipe.
	return bool(posix.isatty(posix.STDOUT_FILENO))
}

// write_colored_word writes `s` wrapped in the level color, with a reset
// immediately after. Use this to color a single keyword (e.g. the level label)
// without colorising the rest of the line.
write_colored_word :: proc(writer: io.Writer, s: string, l: Log_Level, mode: Color_Mode) {
	prefix := level_color(l, mode)
	if prefix == "" {
		fmt.wprint(writer, s)
		return
	}
	fmt.wprint(writer, prefix)
	fmt.wprint(writer, s)
	fmt.wprint(writer, color_reset(mode))
}

write_accent_word :: proc(writer: io.Writer, s: string, mode: Color_Mode) {
	write_styled_word(writer, s, ANSI_BOLD + ANSI_CYAN, mode)
}

write_bold_word :: proc(writer: io.Writer, s: string, mode: Color_Mode) {
	write_styled_word(writer, s, ANSI_BOLD, mode)
}

write_muted_word :: proc(writer: io.Writer, s: string, mode: Color_Mode) {
	_ = mode
	fmt.wprint(writer, s)
}

write_axis_word :: proc(writer: io.Writer, s: string, mode: Color_Mode) {
	write_styled_word(writer, s, ANSI_BRIGHT_WHITE, mode)
}

write_readable_word :: proc(writer: io.Writer, s: string, mode: Color_Mode) {
	write_styled_word(writer, s, ANSI_BRIGHT_WHITE, mode)
}

write_bright_level_word :: proc(
	writer: io.Writer,
	s: string,
	level: Log_Level,
	mode: Color_Mode,
) {
	write_styled_word(writer, s, level_bright_color(level, mode), mode)
}

@(private="file")
write_styled_word :: proc(writer: io.Writer, s, style: string, mode: Color_Mode) {
	if mode != .Always {
		fmt.wprint(writer, s)
		return
	}
	fmt.wprint(writer, style)
	fmt.wprint(writer, s)
	fmt.wprint(writer, ANSI_RESET)
}
