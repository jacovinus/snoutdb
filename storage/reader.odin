package storage

import "base:runtime"
import "core:encoding/endian"
import "core:os"
import "core:strings"
import snout_core "../core"

Byte_Reader :: struct {
	data:   []byte,
	offset: int,
	limit:  int,
}

read_snout_file :: proc(
	path: string,
	allocator := context.allocator,
) -> (snout_core.Table, snout_core.Error) {
	data, os_err := os.read_entire_file(path, allocator)
	if os_err != nil {
		return {}, .Io
	}
	defer delete(data, allocator)
	return deserialize_table(data, allocator)
}

deserialize_table :: proc(
	data: []byte,
	allocator := context.allocator,
) -> (snout_core.Table, snout_core.Error) {
	if len(data) < HEADER_SIZE + FOOTER_SIZE {
		return {}, .Unexpected_End_Of_File
	}
	if !bytes_match(data[:8], HEADER_MAGIC[:]) {
		return {}, .Invalid_Magic
	}

	reader := Byte_Reader{data = data, limit = len(data)}
	reader.offset = 8

	ok: bool
	major: u16
	major, ok = read_u16(&reader)
	if !ok {
		return {}, .Unexpected_End_Of_File
	}
	minor: u16
	minor, ok = read_u16(&reader)
	if !ok {
		return {}, .Unexpected_End_Of_File
	}
	endianness: u8
	endianness, ok = read_u8(&reader)
	if !ok {
		return {}, .Unexpected_End_Of_File
	}
	if endianness != LITTLE_ENDIAN_MARKER {
		return {}, .Unsupported_Endianness
	}
	reserved: []byte
	reserved, ok = read_bytes(&reader, 3)
	if !ok {
		return {}, .Unexpected_End_Of_File
	}
	for value in reserved {
		if value != 0 {
			return {}, .Invalid_File_Size
		}
	}
	declared_size: u64
	declared_size, ok = read_u64(&reader)
	if !ok {
		return {}, .Unexpected_End_Of_File
	}
	footer_offset_u64: u64
	footer_offset_u64, ok = read_u64(&reader)
	if !ok {
		return {}, .Unexpected_End_Of_File
	}
	if declared_size != u64(len(data)) {
		return {}, .Invalid_File_Size
	}
	if footer_offset_u64 != u64(len(data) - FOOTER_SIZE) || footer_offset_u64 > u64(max(int)) {
		return {}, .Invalid_Footer
	}
	footer_offset := int(footer_offset_u64)

	switch major {
	case 1:
		return deserialize_table_v1(data, reader, footer_offset, minor, allocator)
	case 2:
		if minor > MINOR_VERSION {
			return {}, .Unsupported_Version
		}
		return deserialize_table_v2(data, reader, footer_offset, allocator)
	}
	return {}, .Unsupported_Version
}

@(private = "file")
deserialize_table_v1 :: proc(
	data: []byte,
	reader: Byte_Reader,
	footer_offset: int,
	minor: u16,
	allocator: runtime.Allocator,
) -> (snout_core.Table, snout_core.Error) {
	if minor > 0 {
		return {}, .Unsupported_Version
	}
	reader := reader
	reader.limit = footer_offset

	table: snout_core.Table
	table.allocator = allocator
	read_err: snout_core.Error
	table.name, read_err = read_allocated_string(&reader, allocator)
	if read_err != .None {
		return {}, read_err
	}
	defer snout_core.free_table(&table)

	ok: bool
	row_count_u64: u64
	row_count_u64, ok = read_u64(&reader)
	if !ok {
		return {}, .Unexpected_End_Of_File
	}
	if row_count_u64 > u64(max(int)) {
		return {}, .Value_Too_Large
	}
	table.row_count = int(row_count_u64)

	column_count_u32: u32
	column_count_u32, ok = read_u32(&reader)
	if !ok {
		return {}, .Unexpected_End_Of_File
	}
	if column_count_u32 > MAX_COLUMN_COUNT {
		return {}, .Value_Too_Large
	}
	column_count := int(column_count_u32)
	MIN_COLUMN_METADATA_SIZE :: 24
	if column_count > (reader.limit - reader.offset) / MIN_COLUMN_METADATA_SIZE {
		return {}, .Unexpected_End_Of_File
	}
	table.columns, _ = make([]snout_core.Column, column_count, allocator)
	if column_count > 0 && table.columns == nil {
		return {}, .Out_Of_Memory
	}
	metas, alloc_err := make([]Column_Meta, column_count, context.temp_allocator)
	if alloc_err != nil {
		return {}, .Out_Of_Memory
	}

	for index in 0 ..< column_count {
		column := &table.columns[index]
		column.name, read_err = read_allocated_string(&reader, allocator)
		if read_err != .None {
			return {}, read_err
		}
		read_ok: bool
		type_id: u8
		type_id, read_ok = read_u8(&reader)
		if !read_ok {
			return {}, .Unexpected_End_Of_File
		}
		column.kind, read_ok = column_type_from_id(type_id)
		if !read_ok {
			return {}, .Invalid_Type
		}
		nullable: u8
		nullable, read_ok = read_u8(&reader)
		if !read_ok {
			return {}, .Unexpected_End_Of_File
		}
		if nullable > 1 {
			return {}, .Invalid_Null_Mask
		}
		column.nullable = nullable == 1
		column_reserved: []byte
		column_reserved, read_ok = read_bytes(&reader, 2)
		if !read_ok {
			return {}, .Unexpected_End_Of_File
		}
		if column_reserved[0] != 0 || column_reserved[1] != 0 {
			return {}, .Invalid_Column_Data
		}
		metas[index].null_mask_size, read_ok = read_u64(&reader)
		if !read_ok {
			return {}, .Unexpected_End_Of_File
		}
		metas[index].data_size, read_ok = read_u64(&reader)
		if !read_ok {
			return {}, .Unexpected_End_Of_File
		}

		expected_mask_size: u64
		if column.nullable {
			expected_mask_size, _ = expected_null_mask_size(row_count_u64)
		}
		if metas[index].null_mask_size != expected_mask_size {
			return {}, .Invalid_Null_Mask
		}
		if !validate_fixed_data_size(column.kind, row_count_u64, metas[index].data_size) {
			return {}, .Invalid_Column_Data
		}
	}

	remaining_size: u64
	for meta in metas {
		size_ok: bool
		remaining_size, size_ok = checked_add(remaining_size, meta.null_mask_size)
		if !size_ok {
			return {}, .Value_Too_Large
		}
		remaining_size, size_ok = checked_add(remaining_size, meta.data_size)
		if !size_ok {
			return {}, .Value_Too_Large
		}
	}
	if remaining_size != u64(reader.limit - reader.offset) {
		return {}, .Invalid_File_Size
	}

	for &column, index in table.columns {
		column.null_mask, _ = make([]bool, table.row_count, allocator)
		if table.row_count > 0 && column.null_mask == nil {
			return {}, .Out_Of_Memory
		}
		if column.nullable {
			mask_bytes, read_ok := read_bytes(&reader, int(metas[index].null_mask_size))
			if !read_ok {
				return {}, .Unexpected_End_Of_File
			}
			if !unpack_null_mask(column.null_mask, mask_bytes) {
				return {}, .Invalid_Null_Mask
			}
		}
	}

	for &column, index in table.columns {
		if metas[index].data_size > u64(max(int)) {
			return {}, .Value_Too_Large
		}
		data_end := reader.offset + int(metas[index].data_size)
		if data_end < reader.offset || data_end > reader.limit {
			return {}, .Unexpected_End_Of_File
		}
		read_err = read_column_data(&reader, &column, data_end, allocator)
		if read_err != .None {
			return {}, read_err
		}
		if reader.offset != data_end {
			return {}, .Invalid_Column_Data
		}
	}

	if reader.offset != footer_offset {
		return {}, .Invalid_Column_Data
	}
	footer_reader := Byte_Reader{data = data, offset = footer_offset, limit = len(data)}
	footer_magic: []byte
	footer_magic, ok = read_bytes(&footer_reader, 8)
	if !ok || !bytes_match(footer_magic, FOOTER_MAGIC[:]) {
		return {}, .Invalid_Footer
	}
	footer_size: u64
	footer_size, ok = read_u64(&footer_reader)
	if !ok || footer_size != u64(len(data)) || footer_reader.offset != len(data) {
		return {}, .Invalid_Footer
	}
	result := table
	table = {}
	return result, .None
}

@(private = "file")
deserialize_table_v2 :: proc(
	data: []byte,
	reader: Byte_Reader,
	footer_offset: int,
	allocator: runtime.Allocator,
) -> (snout_core.Table, snout_core.Error) {
	reader := reader
	reader.limit = footer_offset

	table: snout_core.Table
	table.allocator = allocator

	read_err: snout_core.Error
	table.name, read_err = read_allocated_string(&reader, allocator)
	if read_err != .None {
		return {}, read_err
	}
	defer snout_core.free_table(&table)

	ok: bool
	row_count_u64: u64
	row_count_u64, ok = read_u64(&reader)
	if !ok {
		return {}, .Unexpected_End_Of_File
	}
	if row_count_u64 > u64(max(int)) {
		return {}, .Value_Too_Large
	}
	table.row_count = int(row_count_u64)

	column_count_u32: u32
	column_count_u32, ok = read_u32(&reader)
	if !ok {
		return {}, .Unexpected_End_Of_File
	}
	if column_count_u32 > MAX_COLUMN_COUNT {
		return {}, .Value_Too_Large
	}
	column_count := int(column_count_u32)

	chunk_count_u32: u32
	chunk_count_u32, ok = read_u32(&reader)
	if !ok {
		return {}, .Unexpected_End_Of_File
	}
	chunk_count := int(chunk_count_u32)

	expected_chunks := 0
	if table.row_count > 0 {
		expected_chunks = (table.row_count + CHUNK_SIZE - 1) / CHUNK_SIZE
	}
	if chunk_count != expected_chunks {
		return {}, .Invalid_Column_Data
	}

	table.columns, _ = make([]snout_core.Column, column_count, allocator)
	if column_count > 0 && table.columns == nil {
		return {}, .Out_Of_Memory
	}

	for i in 0 ..< column_count {
		col := &table.columns[i]
		col.name, read_err = read_allocated_string(&reader, allocator)
		if read_err != .None {
			return {}, read_err
		}
		type_id: u8
		read_ok: bool
		type_id, read_ok = read_u8(&reader)
		if !read_ok {
			return {}, .Unexpected_End_Of_File
		}
		col.kind, read_ok = column_type_from_id(type_id)
		if !read_ok {
			return {}, .Invalid_Type
		}
		nullable: u8
		nullable, read_ok = read_u8(&reader)
		if !read_ok {
			return {}, .Unexpected_End_Of_File
		}
		if nullable > 1 {
			return {}, .Invalid_Null_Mask
		}
		col.nullable = nullable == 1
		col_reserved: []byte
		col_reserved, read_ok = read_bytes(&reader, 2)
		if !read_ok {
			return {}, .Unexpected_End_Of_File
		}
		if col_reserved[0] != 0 || col_reserved[1] != 0 {
			return {}, .Invalid_Column_Data
		}
	}

	// Allocate full column arrays upfront.
	for i in 0 ..< column_count {
		col := &table.columns[i]
		alloc_err: runtime.Allocator_Error
		col.null_mask, alloc_err = make([]bool, table.row_count, allocator)
		if alloc_err != nil && table.row_count > 0 {
			return {}, .Out_Of_Memory
		}
		switch col.kind {
		case .Int64:
			col.int64s, alloc_err = make([]i64, table.row_count, allocator)
			if alloc_err != nil && table.row_count > 0 {
				return {}, .Out_Of_Memory
			}
		case .Float64:
			col.float64s, alloc_err = make([]f64, table.row_count, allocator)
			if alloc_err != nil && table.row_count > 0 {
				return {}, .Out_Of_Memory
			}
		case .Bool:
			col.bools, alloc_err = make([]bool, table.row_count, allocator)
			if alloc_err != nil && table.row_count > 0 {
				return {}, .Out_Of_Memory
			}
		case .String, .Timestamp:
			col.strings, alloc_err = make([]string, table.row_count, allocator)
			if alloc_err != nil && table.row_count > 0 {
				return {}, .Out_Of_Memory
			}
		case .Unknown:
			return {}, .Invalid_Type
		}
	}

	// Read chunks and populate column data.
	row_start := 0
	for _ in 0 ..< chunk_count {
		chunk_row_count_u32: u32
		read_ok: bool
		chunk_row_count_u32, read_ok = read_u32(&reader)
		if !read_ok {
			return {}, .Unexpected_End_Of_File
		}
		chunk_row_count := int(chunk_row_count_u32)

		expected_chunk_rows := min(CHUNK_SIZE, table.row_count - row_start)
		if chunk_row_count != expected_chunk_rows {
			return {}, .Invalid_Column_Data
		}

		for col_idx in 0 ..< column_count {
			col := &table.columns[col_idx]

			// Column chunk header (32 bytes).
			encoding: u8
			encoding, read_ok = read_u8(&reader)
			if !read_ok {
				return {}, .Unexpected_End_Of_File
			}
			is_string_col := col.kind == .String || col.kind == .Timestamp
			if encoding == ENCODING_DICTIONARY && !is_string_col {
				return {}, .Invalid_Column_Data
			}
			if encoding != ENCODING_PLAIN && encoding != ENCODING_DICTIONARY {
				return {}, .Invalid_Column_Data
			}
			reserved_3: []byte
			reserved_3, read_ok = read_bytes(&reader, 3)
			if !read_ok {
				return {}, .Unexpected_End_Of_File
			}
			_ = reserved_3

			_null_count: u32
			_null_count, read_ok = read_u32(&reader)
			if !read_ok {
				return {}, .Unexpected_End_Of_File
			}
			_min: u64
			_min, read_ok = read_u64(&reader) // min stat (not used during read)
			if !read_ok {
				return {}, .Unexpected_End_Of_File
			}
			_max: u64
			_max, read_ok = read_u64(&reader) // max stat (not used during read)
			if !read_ok {
				return {}, .Unexpected_End_Of_File
			}
			data_size_u64: u64
			data_size_u64, read_ok = read_u64(&reader)
			if !read_ok {
				return {}, .Unexpected_End_Of_File
			}
			if data_size_u64 > u64(max(int)) {
				return {}, .Value_Too_Large
			}
			data_size := int(data_size_u64)

			// Null mask.
			null_mask_bytes := 0
			if col.nullable {
				null_mask_bytes = (chunk_row_count + 7) / 8
			}
			if null_mask_bytes > data_size {
				return {}, .Invalid_Column_Data
			}
			raw_data_size := data_size - null_mask_bytes

			if col.nullable {
				mask_bytes: []byte
				mask_bytes, read_ok = read_bytes(&reader, null_mask_bytes)
				if !read_ok {
					return {}, .Unexpected_End_Of_File
				}
				if !unpack_null_mask_range(col.null_mask, mask_bytes, row_start, chunk_row_count) {
					return {}, .Invalid_Null_Mask
				}
			}

			// Validate raw_data_size (encoding-aware).
			switch col.kind {
			case .Int64, .Float64:
				if raw_data_size != chunk_row_count * 8 {
					return {}, .Invalid_Column_Data
				}
			case .Bool:
				if raw_data_size != chunk_row_count {
					return {}, .Invalid_Column_Data
				}
			case .String, .Timestamp:
				if encoding == ENCODING_PLAIN {
					if raw_data_size < chunk_row_count * 4 {
						return {}, .Invalid_Column_Data
					}
				} else {
					// Dictionary: minimum is 4 (dict_count) + chunk_row_count (u8 indices).
					if raw_data_size < 4 + chunk_row_count {
						return {}, .Invalid_Column_Data
					}
				}
			case .Unknown:
				return {}, .Invalid_Type
			}

			data_end := reader.offset + raw_data_size
			if data_end < reader.offset || data_end > reader.limit {
				return {}, .Unexpected_End_Of_File
			}
			if encoding == ENCODING_DICTIONARY {
				read_err = read_column_data_range_dict(
					&reader,
					col,
					row_start,
					chunk_row_count,
					data_end,
					allocator,
				)
			} else {
				read_err = read_column_data_range(
					&reader,
					col,
					row_start,
					chunk_row_count,
					data_end,
					allocator,
				)
			}
			if read_err != .None {
				return {}, read_err
			}
			if reader.offset != data_end {
				return {}, .Invalid_Column_Data
			}
		}

		row_start += chunk_row_count
	}

	if reader.offset != footer_offset {
		return {}, .Invalid_Column_Data
	}
	footer_reader := Byte_Reader{data = data, offset = footer_offset, limit = len(data)}
	footer_magic: []byte
	footer_magic, ok = read_bytes(&footer_reader, 8)
	if !ok || !bytes_match(footer_magic, FOOTER_MAGIC[:]) {
		return {}, .Invalid_Footer
	}
	footer_size: u64
	footer_size, ok = read_u64(&footer_reader)
	declared_size := u64(len(data))
	if !ok || footer_size != declared_size || footer_reader.offset != len(data) {
		return {}, .Invalid_Footer
	}
	result := table
	table = {}
	return result, .None
}

validate_fixed_data_size :: proc(
	kind: snout_core.Column_Type,
	row_count, data_size: u64,
) -> bool {
	switch kind {
	case .Int64, .Float64:
		expected, ok := checked_mul(row_count, 8)
		return ok && data_size == expected
	case .Bool:
		return data_size == row_count
	case .String, .Timestamp:
		minimum, ok := checked_mul(row_count, 4)
		return ok && data_size >= minimum
	case .Unknown:
		return false
	}
	return false
}

unpack_null_mask :: proc(destination: []bool, packed: []byte) -> bool {
	for row_index in 0 ..< len(destination) {
		byte_index := row_index / 8
		bit_index := row_index % 8
		destination[row_index] = packed[byte_index] & u8(1 << u32(bit_index)) != 0
	}
	if len(destination) % 8 != 0 && len(packed) > 0 {
		used_bits := len(destination) % 8
		allowed: u8 = u8((1 << u32(used_bits)) - 1)
		if packed[len(packed)-1] & ~allowed != 0 {
			return false
		}
	}
	return true
}

@(private = "file")
unpack_null_mask_range :: proc(
	destination: []bool,
	packed: []byte,
	row_start, row_count: int,
) -> bool {
	for i in 0 ..< row_count {
		byte_index := i / 8
		bit_index := i % 8
		destination[row_start + i] = packed[byte_index] & u8(1 << u32(bit_index)) != 0
	}
	if row_count % 8 != 0 && len(packed) > 0 {
		used_bits := row_count % 8
		allowed: u8 = u8((1 << u32(used_bits)) - 1)
		if packed[len(packed)-1] & ~allowed != 0 {
			return false
		}
	}
	return true
}

read_column_data :: proc(
	reader: ^Byte_Reader,
	column: ^snout_core.Column,
	data_end: int,
	allocator: runtime.Allocator,
) -> snout_core.Error {
	row_count := len(column.null_mask)
	switch column.kind {
	case .Int64:
		column.int64s, _ = make([]i64, row_count, allocator)
		if row_count > 0 && column.int64s == nil {
			return .Out_Of_Memory
		}
		for index in 0 ..< row_count {
			value, ok := read_i64(reader)
			if !ok {
				return .Unexpected_End_Of_File
			}
			if column.null_mask[index] {
				if value != 0 {
					return .Invalid_Column_Data
				}
			} else {
				column.int64s[index] = value
			}
		}
	case .Float64:
		column.float64s, _ = make([]f64, row_count, allocator)
		if row_count > 0 && column.float64s == nil {
			return .Out_Of_Memory
		}
		for index in 0 ..< row_count {
			value, bits, ok := read_f64(reader)
			if !ok {
				return .Unexpected_End_Of_File
			}
			if column.null_mask[index] {
				if bits != 0 {
					return .Invalid_Column_Data
				}
			} else {
				column.float64s[index] = value
			}
		}
	case .Bool:
		column.bools, _ = make([]bool, row_count, allocator)
		if row_count > 0 && column.bools == nil {
			return .Out_Of_Memory
		}
		for index in 0 ..< row_count {
			value, ok := read_u8(reader)
			if !ok {
				return .Unexpected_End_Of_File
			}
			if column.null_mask[index] {
				if value != 0 {
					return .Invalid_Column_Data
				}
			} else if value > 1 {
				return .Invalid_Column_Data
			} else {
				column.bools[index] = value == 1
			}
		}
	case .String, .Timestamp:
		column.strings, _ = make([]string, row_count, allocator)
		if row_count > 0 && column.strings == nil {
			return .Out_Of_Memory
		}
		for index in 0 ..< row_count {
			length, ok := read_u32(reader)
			if !ok {
				return .Unexpected_End_Of_File
			}
			if column.null_mask[index] && length != 0 {
				return .Invalid_Column_Data
			}
			if u64(length) > u64(data_end - reader.offset) {
				return .Unexpected_End_Of_File
			}
			value_bytes, bytes_ok := read_bytes(reader, int(length))
			if !bytes_ok {
				return .Unexpected_End_Of_File
			}
			value, alloc_err := strings.clone(string(value_bytes), allocator)
			if alloc_err != nil {
				return .Out_Of_Memory
			}
			column.strings[index] = value
		}
	case .Unknown:
		return .Invalid_Type
	}
	return .None
}

@(private = "file")
read_column_data_range :: proc(
	reader: ^Byte_Reader,
	column: ^snout_core.Column,
	row_start, row_count: int,
	data_end: int,
	allocator: runtime.Allocator,
) -> snout_core.Error {
	switch column.kind {
	case .Int64:
		for i in 0 ..< row_count {
			value, ok := read_i64(reader)
			if !ok {
				return .Unexpected_End_Of_File
			}
			if column.null_mask[row_start + i] {
				if value != 0 {
					return .Invalid_Column_Data
				}
			} else {
				column.int64s[row_start + i] = value
			}
		}
	case .Float64:
		for i in 0 ..< row_count {
			value, bits, ok := read_f64(reader)
			if !ok {
				return .Unexpected_End_Of_File
			}
			if column.null_mask[row_start + i] {
				if bits != 0 {
					return .Invalid_Column_Data
				}
			} else {
				column.float64s[row_start + i] = value
			}
		}
	case .Bool:
		for i in 0 ..< row_count {
			value, ok := read_u8(reader)
			if !ok {
				return .Unexpected_End_Of_File
			}
			if column.null_mask[row_start + i] {
				if value != 0 {
					return .Invalid_Column_Data
				}
			} else if value > 1 {
				return .Invalid_Column_Data
			} else {
				column.bools[row_start + i] = value == 1
			}
		}
	case .String, .Timestamp:
		for i in 0 ..< row_count {
			length, ok := read_u32(reader)
			if !ok {
				return .Unexpected_End_Of_File
			}
			if column.null_mask[row_start + i] && length != 0 {
				return .Invalid_Column_Data
			}
			if u64(length) > u64(data_end - reader.offset) {
				return .Unexpected_End_Of_File
			}
			value_bytes, bytes_ok := read_bytes(reader, int(length))
			if !bytes_ok {
				return .Unexpected_End_Of_File
			}
			value, alloc_err := strings.clone(string(value_bytes), allocator)
			if alloc_err != nil {
				return .Out_Of_Memory
			}
			column.strings[row_start + i] = value
		}
	case .Unknown:
		return .Invalid_Type
	}
	return .None
}

@(private = "file")
read_column_data_range_dict :: proc(
	reader: ^Byte_Reader,
	column: ^snout_core.Column,
	row_start, row_count: int,
	data_end: int,
	allocator: runtime.Allocator,
) -> snout_core.Error {
	dict_count, ok := read_u32(reader)
	if !ok {
		return .Unexpected_End_Of_File
	}

	index_width := 1 if dict_count <= 256 else 2

	// Read dictionary entries into a temporary slice of byte-slices.
	// We keep them as slices into the data buffer (no allocation needed).
	dict, alloc_err := make([][]byte, int(dict_count), context.temp_allocator)
	if alloc_err != nil {
		return .Out_Of_Memory
	}
	for i in 0 ..< int(dict_count) {
		length, ok2 := read_u32(reader)
		if !ok2 {
			return .Unexpected_End_Of_File
		}
		if u64(length) > u64(data_end - reader.offset) {
			return .Unexpected_End_Of_File
		}
		entry_bytes, ok3 := read_bytes(reader, int(length))
		if !ok3 {
			return .Unexpected_End_Of_File
		}
		dict[i] = entry_bytes
	}

	// Read indices and resolve strings.
	for i in 0 ..< row_count {
		idx: u32
		if index_width == 1 {
			b, ok4 := read_u8(reader)
			if !ok4 {
				return .Unexpected_End_Of_File
			}
			idx = u32(b)
		} else {
			w, ok5 := read_u16(reader)
			if !ok5 {
				return .Unexpected_End_Of_File
			}
			idx = u32(w)
		}

		if column.null_mask[row_start + i] {
			value, clone_err := strings.clone("", allocator)
			if clone_err != nil {
				return .Out_Of_Memory
			}
			column.strings[row_start + i] = value
		} else {
			if idx >= dict_count {
				return .Invalid_Column_Data
			}
			value, clone_err := strings.clone(string(dict[idx]), allocator)
			if clone_err != nil {
				return .Out_Of_Memory
			}
			column.strings[row_start + i] = value
		}
	}
	return .None
}

read_u8 :: proc(reader: ^Byte_Reader) -> (u8, bool) {
	if reader.offset >= reader.limit {
		return 0, false
	}
	value := reader.data[reader.offset]
	reader.offset += 1
	return value, true
}

read_u16 :: proc(reader: ^Byte_Reader) -> (u16, bool) {
	value, ok := read_bytes(reader, 2)
	if !ok {
		return 0, false
	}
	return endian.unchecked_get_u16le(value), true
}

read_u32 :: proc(reader: ^Byte_Reader) -> (u32, bool) {
	value, ok := read_bytes(reader, 4)
	if !ok {
		return 0, false
	}
	return endian.unchecked_get_u32le(value), true
}

read_u64 :: proc(reader: ^Byte_Reader) -> (u64, bool) {
	value, ok := read_bytes(reader, 8)
	if !ok {
		return 0, false
	}
	return endian.unchecked_get_u64le(value), true
}

read_i64 :: proc(reader: ^Byte_Reader) -> (i64, bool) {
	value, ok := read_u64(reader)
	return i64(value), ok
}

read_f64 :: proc(reader: ^Byte_Reader) -> (f64, u64, bool) {
	bits, ok := read_u64(reader)
	return transmute(f64)bits, bits, ok
}

read_bytes :: proc(reader: ^Byte_Reader, count: int) -> ([]byte, bool) {
	if count < 0 || reader.offset > reader.limit - count {
		return nil, false
	}
	value := reader.data[reader.offset:reader.offset + count]
	reader.offset += count
	return value, true
}

read_allocated_string :: proc(
	reader: ^Byte_Reader,
	allocator: runtime.Allocator,
) -> (string, snout_core.Error) {
	length, ok := read_u32(reader)
	if !ok {
		return "", .Unexpected_End_Of_File
	}
	if length > MAX_NAME_SIZE {
		return "", .Value_Too_Large
	}
	value, bytes_ok := read_bytes(reader, int(length))
	if !bytes_ok {
		return "", .Unexpected_End_Of_File
	}
	result, alloc_err := strings.clone(string(value), allocator)
	if alloc_err != nil {
		return "", .Out_Of_Memory
	}
	return result, .None
}
