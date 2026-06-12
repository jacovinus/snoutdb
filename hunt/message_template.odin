package hunt

import "core:strings"

// Templates can be long for messages that include stack-like context (JSON
// bodies, URLs with query strings, etc.). 500 chars covers virtually every
// real-world log message without bloating frequent-pattern memory.
MAX_TEMPLATE_LEN   :: 500
MAX_REPRESENTATIVE :: 1000

// templatize replaces variable substrings in a log message with stable tokens
// so that messages differing only in IDs, IPs, timestamps, and numbers cluster
// under the same template key.
//
// The substitution is hand-rolled — no regex engine — to keep the row loop
// allocation-free and predictable. Control characters are escaped on output.
//
// Recognized substitutions:
//   <uuid>      RFC 4122 8-4-4-4-12 hex form
//   <timestamp> ISO-8601 YYYY-MM-DDTHH:MM:SS[.frac][Z|±offset]
//   <ip>        IPv4 dotted quad
//   <hex>       0x... (6 or more hex digits)
//   <id>        opaque token: ≥20 chars of [A-Za-z0-9_-] that contains both letters and digits
//   <n>         signed integer or decimal
templatize :: proc(message: string, allocator := context.allocator) -> string {
	b := strings.builder_make(context.temp_allocator)
	i := 0
	n := len(message)
	for i < n {
		// UUID
		if i + 36 <= n && is_uuid(message[i:i+36]) {
			strings.write_string(&b, "<uuid>")
			i += 36
			continue
		}
		// ISO timestamp
		if ts_len := match_iso_timestamp(message, i); ts_len > 0 {
			strings.write_string(&b, "<timestamp>")
			i += ts_len
			continue
		}
		// IPv4
		if ip_len := match_ipv4(message, i); ip_len > 0 {
			strings.write_string(&b, "<ip>")
			i += ip_len
			continue
		}
		// Hex literal 0x...
		if hx_len := match_hex(message, i); hx_len > 0 {
			strings.write_string(&b, "<hex>")
			i += hx_len
			continue
		}
		// Opaque ID (≥20 chars of [A-Za-z0-9_-] with both letters and digits)
		if id_len := match_long_id(message, i); id_len > 0 {
			strings.write_string(&b, "<id>")
			i += id_len
			continue
		}
		// Number (must start on a digit or sign-then-digit; not preceded by alnum)
		if num_len := match_number(message, i); num_len > 0 {
			strings.write_string(&b, "<n>")
			i += num_len
			continue
		}
		// Default: copy the byte, escaping control chars.
		c := message[i]
		if c < 0x20 {
			switch c {
			case '\n': strings.write_string(&b, "\\n")
			case '\r': strings.write_string(&b, "\\r")
			case '\t': strings.write_string(&b, "\\t")
			case:      strings.write_byte(&b, '?')
			}
		} else {
			strings.write_byte(&b, c)
		}
		i += 1
	}
	return clip_string(strings.to_string(b), MAX_TEMPLATE_LEN, allocator)
}

// preserve_representative copies a message verbatim (with control chars escaped
// and length-clipped) for display alongside its template.
preserve_representative :: proc(message: string, allocator := context.allocator) -> string {
	b := strings.builder_make(context.temp_allocator)
	for i in 0..<len(message) {
		c := message[i]
		if c < 0x20 {
			switch c {
			case '\n': strings.write_string(&b, "\\n")
			case '\r': strings.write_string(&b, "\\r")
			case '\t': strings.write_string(&b, "\\t")
			case:      strings.write_byte(&b, '?')
			}
		} else {
			strings.write_byte(&b, c)
		}
	}
	return clip_string(strings.to_string(b), MAX_REPRESENTATIVE, allocator)
}

// ── Pattern matchers (return match length in bytes; 0 = no match) ──────────

@(private="file")
is_uuid :: proc(s: string) -> bool {
	// 8-4-4-4-12 hex
	if len(s) != 36 { return false }
	for i in 0..<len(s) {
		c := s[i]
		if i == 8 || i == 13 || i == 18 || i == 23 {
			if c != '-' { return false }
		} else if !is_hex(c) {
			return false
		}
	}
	return true
}

@(private="file")
match_iso_timestamp :: proc(s: string, start: int) -> int {
	// YYYY-MM-DDTHH:MM:SS[.frac][Z|±HH:MM]
	if start + 19 > len(s) { return 0 }
	if !is_digit(s[start])   || !is_digit(s[start+1])  ||
	   !is_digit(s[start+2]) || !is_digit(s[start+3])  ||
	   s[start+4] != '-'   ||
	   !is_digit(s[start+5]) || !is_digit(s[start+6])  ||
	   s[start+7] != '-'   ||
	   !is_digit(s[start+8]) || !is_digit(s[start+9])  ||
	   s[start+10] != 'T' && s[start+10] != ' '       ||
	   !is_digit(s[start+11]) || !is_digit(s[start+12]) ||
	   s[start+13] != ':' ||
	   !is_digit(s[start+14]) || !is_digit(s[start+15]) ||
	   s[start+16] != ':' ||
	   !is_digit(s[start+17]) || !is_digit(s[start+18]) {
		return 0
	}
	end := start + 19
	// Optional fractional seconds.
	if end < len(s) && s[end] == '.' {
		end += 1
		for end < len(s) && is_digit(s[end]) { end += 1 }
	}
	// Optional zone.
	if end < len(s) {
		if s[end] == 'Z' {
			end += 1
		} else if s[end] == '+' || s[end] == '-' {
			zs := end + 1
			if zs + 4 <= len(s) && is_digit(s[zs]) && is_digit(s[zs+1]) &&
			   (s[zs+2] == ':' || is_digit(s[zs+2])) {
				end = zs + 5 if s[zs+2] == ':' else zs + 4
			}
		}
	}
	return end - start
}

@(private="file")
match_ipv4 :: proc(s: string, start: int) -> int {
	// Four 1-3 digit groups separated by dots.
	i := start
	for group in 0..<4 {
		digits := 0
		for i < len(s) && is_digit(s[i]) && digits < 3 {
			i += 1
			digits += 1
		}
		if digits == 0 { return 0 }
		if group < 3 {
			if i >= len(s) || s[i] != '.' { return 0 }
			i += 1
		}
	}
	// Reject if followed by another digit (would be a longer number).
	if i < len(s) && is_digit(s[i]) { return 0 }
	return i - start
}

@(private="file")
match_hex :: proc(s: string, start: int) -> int {
	if start + 8 > len(s) { return 0 }
	if s[start] != '0' || (s[start+1] != 'x' && s[start+1] != 'X') { return 0 }
	i := start + 2
	count := 0
	for i < len(s) && is_hex(s[i]) {
		i += 1
		count += 1
	}
	if count < 6 { return 0 }
	return i - start
}

@(private="file")
match_long_id :: proc(s: string, start: int) -> int {
	// Token of [A-Za-z0-9_-] length ≥20 with both letters and digits.
	i := start
	letters := 0
	digits  := 0
	for i < len(s) {
		c := s[i]
		if is_alpha(c) { letters += 1 }
		else if is_digit(c) { digits += 1 }
		else if c == '_' || c == '-' { /* ok */ }
		else { break }
		i += 1
	}
	length := i - start
	if length < 20 { return 0 }
	if letters == 0 || digits == 0 { return 0 }
	return length
}

@(private="file")
match_number :: proc(s: string, start: int) -> int {
	i := start
	if i < len(s) && (s[i] == '-' || s[i] == '+') {
		// Only consume sign if the next char is a digit and previous is not alnum.
		if i+1 >= len(s) || !is_digit(s[i+1]) { return 0 }
		if start > 0 && is_alpha(s[start-1]) { return 0 }
		i += 1
	}
	if i >= len(s) || !is_digit(s[i]) { return 0 }
	// Reject if previous char is letter/digit (mid-identifier).
	if start > 0 {
		p := s[start-1]
		if is_alpha(p) || is_digit(p) { return 0 }
	}
	for i < len(s) && is_digit(s[i]) { i += 1 }
	// Optional decimal.
	if i+1 < len(s) && s[i] == '.' && is_digit(s[i+1]) {
		i += 1
		for i < len(s) && is_digit(s[i]) { i += 1 }
	}
	return i - start
}

@(private="file")
is_digit :: proc(c: byte) -> bool { return c >= '0' && c <= '9' }
@(private="file")
is_alpha :: proc(c: byte) -> bool { return (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') }
@(private="file")
is_hex   :: proc(c: byte) -> bool { return is_digit(c) || (c >= 'a' && c <= 'f') || (c >= 'A' && c <= 'F') }

@(private="file")
clip_string :: proc(s: string, max_len: int, allocator := context.allocator) -> string {
	if len(s) <= max_len {
		out, _ := strings.clone(s, allocator)
		return out
	}
	limit := max_len
	for limit > 0 && (s[limit] & 0xC0) == 0x80 { limit -= 1 }
	return strings.concatenate({s[:limit], "…"}, allocator)
}
