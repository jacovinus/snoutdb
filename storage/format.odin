package storage

import snout_core "../core"

HEADER_SIZE :: 32
FOOTER_SIZE :: 16
MAJOR_VERSION :: 2
MINOR_VERSION :: 0
LITTLE_ENDIAN_MARKER :: 1
MAX_NAME_SIZE :: 1 << 20
MAX_COLUMN_COUNT :: 65_535
CHUNK_SIZE :: 65_536
Column_Chunk_Header_Size :: 32
ENCODING_PLAIN :: u8(0)
ENCODING_DICTIONARY :: u8(1)

HEADER_MAGIC := [8]byte{'S', 'N', 'O', 'U', 'T', 'D', 'B', 0}
FOOTER_MAGIC := [8]byte{'S', 'N', 'O', 'U', 'T', 'E', 'N', 'D'}

// Used by v1 reader only.
Column_Meta :: struct {
	null_mask_size: u64,
	data_size:      u64,
}

// Per-column statistics for one chunk, computed during write.
Column_Chunk_Layout :: struct {
	encoding:        u8,
	null_count:      u32,
	min:             u64,
	max:             u64,
	null_mask_bytes: int,
	data_bytes:      int,
}

Chunk_Layout :: struct {
	row_start: int,
	row_count: int,
	columns:   []Column_Chunk_Layout,
}

V2_Layout :: struct {
	chunk_count:   int,
	chunks:        []Chunk_Layout,
	file_size:     u64,
	footer_offset: u64,
}

persisted_type_id :: proc(kind: snout_core.Column_Type) -> (u8, bool) {
	switch kind {
	case .String:
		return 1, true
	case .Int64:
		return 2, true
	case .Float64:
		return 3, true
	case .Bool:
		return 4, true
	case .Timestamp:
		return 5, true
	case .Unknown:
		return 0, false
	}
	return 0, false
}

column_type_from_id :: proc(type_id: u8) -> (snout_core.Column_Type, bool) {
	switch type_id {
	case 1:
		return .String, true
	case 2:
		return .Int64, true
	case 3:
		return .Float64, true
	case 4:
		return .Bool, true
	case 5:
		return .Timestamp, true
	}
	return .Unknown, false
}

checked_add :: proc(a, b: u64) -> (u64, bool) {
	if a > max(u64)-b {
		return 0, false
	}
	return a + b, true
}

checked_mul :: proc(a, b: u64) -> (u64, bool) {
	if a != 0 && b > max(u64)/a {
		return 0, false
	}
	return a * b, true
}

expected_null_mask_size :: proc(row_count: u64) -> (u64, bool) {
	with_padding, ok := checked_add(row_count, 7)
	if !ok {
		return 0, false
	}
	return with_padding / 8, true
}

bytes_match :: proc(data: []byte, expected: []byte) -> bool {
	if len(data) != len(expected) {
		return false
	}
	for value, index in data {
		if value != expected[index] {
			return false
		}
	}
	return true
}
