package storage

import "base:runtime"
import "core:encoding/endian"
import "core:fmt"
import "core:os"
import snout_core "../core"

Byte_Writer :: struct {
	data:   []byte,
	offset: int,
}

serialize_table :: proc(
	table: ^snout_core.Table,
	allocator := context.allocator,
) -> ([]byte, snout_core.Error) {
	layout, layout_err := calculate_layout_v2(table, context.temp_allocator)
	if layout_err != .None {
		return nil, layout_err
	}

	data, alloc_err := make([]byte, int(layout.file_size), allocator)
	if alloc_err != nil {
		return nil, .Out_Of_Memory
	}
	writer := Byte_Writer{data = data}

	// Header
	write_bytes(&writer, HEADER_MAGIC[:])
	write_u16(&writer, MAJOR_VERSION)
	write_u16(&writer, MINOR_VERSION)
	write_u8(&writer, LITTLE_ENDIAN_MARKER)
	write_zeroes(&writer, 3)
	write_u64(&writer, layout.file_size)
	write_u64(&writer, layout.footer_offset)

	// Table metadata
	write_string(&writer, table.name)
	write_u64(&writer, u64(table.row_count))
	write_u32(&writer, u32(len(table.columns)))
	write_u32(&writer, u32(layout.chunk_count))

	// Column descriptors
	for column in table.columns {
		type_id, _ := persisted_type_id(column.kind)
		write_string(&writer, column.name)
		write_u8(&writer, type_id)
		write_u8(&writer, 1 if column.nullable else 0)
		write_zeroes(&writer, 2)
	}

	// Chunks
	for c in 0 ..< layout.chunk_count {
		chunk := &layout.chunks[c]
		write_u32(&writer, u32(chunk.row_count))

		for col_idx in 0 ..< len(table.columns) {
			col_layout := &chunk.columns[col_idx]
			column := &table.columns[col_idx]

			// Column chunk header (32 bytes)
			write_u8(&writer, col_layout.encoding)
			write_zeroes(&writer, 3)
			write_u32(&writer, col_layout.null_count)
			write_u64(&writer, col_layout.min)
			write_u64(&writer, col_layout.max)
			write_u64(&writer, u64(col_layout.null_mask_bytes + col_layout.data_bytes))

			// Null mask
			if column.nullable {
				write_null_mask_range(&writer, column.null_mask, chunk.row_start, chunk.row_count)
			}

			// Column data
			if col_layout.encoding == ENCODING_DICTIONARY {
				write_column_data_range_dict(&writer, column, chunk.row_start, chunk.row_count)
			} else {
				write_column_data_range(&writer, column, chunk.row_start, chunk.row_count)
			}
		}
	}

	if u64(writer.offset) != layout.footer_offset {
		delete(data, allocator)
		return nil, .Invalid_File_Size
	}
	write_bytes(&writer, FOOTER_MAGIC[:])
	write_u64(&writer, layout.file_size)
	if writer.offset != len(data) {
		delete(data, allocator)
		return nil, .Invalid_File_Size
	}
	return data, .None
}

write_snout_file :: proc(
	path: string,
	table: ^snout_core.Table,
	allocator := context.allocator,
) -> snout_core.Error {
	data, err := serialize_table(table, allocator)
	if err != .None {
		return err
	}
	defer delete(data, allocator)

	temp_path := fmt.aprintf("%s.tmp", path, allocator = allocator)
	defer delete(temp_path, allocator)

	if os_err := os.write_entire_file(temp_path, data); os_err != nil {
		_ = os.remove(temp_path)
		return .Io
	}
	if os_err := os.rename(temp_path, path); os_err != nil {
		_ = os.remove(temp_path)
		return .Io
	}
	return .None
}

@(private = "file")
calculate_layout_v2 :: proc(
	table: ^snout_core.Table,
	allocator: runtime.Allocator,
) -> (layout: V2_Layout, err: snout_core.Error) {
	if table == nil || table.row_count < 0 {
		return {}, .Invalid_Column_Data
	}
	if len(table.name) > MAX_NAME_SIZE || len(table.columns) > MAX_COLUMN_COUNT {
		return {}, .Value_Too_Large
	}

	for &column in table.columns {
		if len(column.name) > MAX_NAME_SIZE {
			return {}, .Invalid_Column_Data
		}
		if len(column.null_mask) != table.row_count {
			return {}, .Invalid_Column_Data
		}
		if _, ok := persisted_type_id(column.kind); !ok {
			return {}, .Invalid_Type
		}
		for is_null in column.null_mask {
			if is_null && !column.nullable {
				return {}, .Invalid_Null_Mask
			}
		}
	}

	chunk_count := 0
	if table.row_count > 0 {
		chunk_count = (table.row_count + CHUNK_SIZE - 1) / CHUNK_SIZE
	}

	chunks: []Chunk_Layout
	alloc_err: runtime.Allocator_Error
	chunks, alloc_err = make([]Chunk_Layout, chunk_count, allocator)
	if alloc_err != nil {
		return {}, .Out_Of_Memory
	}

	for c in 0 ..< chunk_count {
		row_start := c * CHUNK_SIZE
		chunk_row_count := min(CHUNK_SIZE, table.row_count - row_start)

		col_layouts: []Column_Chunk_Layout
		col_layouts, alloc_err = make([]Column_Chunk_Layout, len(table.columns), allocator)
		if alloc_err != nil {
			return {}, .Out_Of_Memory
		}
		chunks[c] = Chunk_Layout {
			row_start = row_start,
			row_count = chunk_row_count,
			columns   = col_layouts,
		}

		for col_idx in 0 ..< len(table.columns) {
			col_layout, col_err := compute_column_chunk(
				&table.columns[col_idx],
				row_start,
				chunk_row_count,
			)
			if col_err != .None {
				return {}, col_err
			}
			chunks[c].columns[col_idx] = col_layout
		}
	}

	// Compute file size
	total := u64(HEADER_SIZE)
	table_meta_size := u64(4 + len(table.name) + 8 + 4 + 4)
	ok: bool
	total, ok = checked_add(total, table_meta_size)
	if !ok {
		return {}, .Value_Too_Large
	}

	for &column in table.columns {
		desc_size := u64(4 + len(column.name) + 1 + 1 + 2)
		total, ok = checked_add(total, desc_size)
		if !ok {
			return {}, .Value_Too_Large
		}
	}

	for c in 0 ..< chunk_count {
		total, ok = checked_add(total, 4) // chunk_row_count
		if !ok {
			return {}, .Value_Too_Large
		}
		for &col_layout in chunks[c].columns {
			chunk_col_size := u64(
				Column_Chunk_Header_Size + col_layout.null_mask_bytes + col_layout.data_bytes,
			)
			total, ok = checked_add(total, chunk_col_size)
			if !ok {
				return {}, .Value_Too_Large
			}
		}
	}

	footer_offset := total
	total, ok = checked_add(total, FOOTER_SIZE)
	if !ok || total > u64(max(int)) {
		return {}, .Value_Too_Large
	}

	layout = V2_Layout {
		chunk_count   = chunk_count,
		chunks        = chunks,
		file_size     = total,
		footer_offset = footer_offset,
	}
	return layout, .None
}

@(private = "file")
compute_column_chunk :: proc(
	column: ^snout_core.Column,
	row_start, chunk_row_count: int,
) -> (layout: Column_Chunk_Layout, err: snout_core.Error) {
	if column.nullable {
		layout.null_mask_bytes = (chunk_row_count + 7) / 8
		for i in 0 ..< chunk_row_count {
			if column.null_mask[row_start + i] {
				layout.null_count += 1
			}
		}
	}

	switch column.kind {
	case .Int64:
		if len(column.int64s) < row_start + chunk_row_count {
			return {}, .Invalid_Column_Data
		}
		layout.data_bytes = chunk_row_count * 8
		first := true
		for i in 0 ..< chunk_row_count {
			if column.null_mask[row_start + i] {
				continue
			}
			v := column.int64s[row_start + i]
			if first {
				layout.min = u64(v)
				layout.max = u64(v)
				first = false
			} else {
				if v < i64(layout.min) {
					layout.min = u64(v)
				}
				if v > i64(layout.max) {
					layout.max = u64(v)
				}
			}
		}
	case .Float64:
		if len(column.float64s) < row_start + chunk_row_count {
			return {}, .Invalid_Column_Data
		}
		layout.data_bytes = chunk_row_count * 8
		first := true
		for i in 0 ..< chunk_row_count {
			if column.null_mask[row_start + i] {
				continue
			}
			v := column.float64s[row_start + i]
			if first {
				layout.min = transmute(u64)v
				layout.max = transmute(u64)v
				first = false
			} else {
				if v < transmute(f64)layout.min {
					layout.min = transmute(u64)v
				}
				if v > transmute(f64)layout.max {
					layout.max = transmute(u64)v
				}
			}
		}
	case .Bool:
		if len(column.bools) < row_start + chunk_row_count {
			return {}, .Invalid_Column_Data
		}
		layout.data_bytes = chunk_row_count
	case .String, .Timestamp:
		if len(column.strings) < row_start + chunk_row_count {
			return {}, .Invalid_Column_Data
		}
		// Compute plain size.
		plain_total := 0
		for i in 0 ..< chunk_row_count {
			payload := 0 if column.null_mask[row_start + i] else len(column.strings[row_start + i])
			if u64(payload) > u64(max(u32)) {
				return {}, .Value_Too_Large
			}
			plain_total += 4 + payload
		}
		// Build dictionary to compute dictionary size.
		dict_map := make(map[string]u32, 16)
		defer delete(dict_map)
		dict_payload := 0
		for i in 0 ..< chunk_row_count {
			if column.null_mask[row_start + i] {
				continue
			}
			s := column.strings[row_start + i]
			if _, exists := dict_map[s]; !exists {
				dict_map[s] = u32(len(dict_map))
				dict_payload += 4 + len(s)
			}
		}
		dict_count := len(dict_map)
		index_width := 1 if dict_count <= 256 else 2
		dict_total := 4 + dict_payload + chunk_row_count * index_width
		if dict_total < plain_total {
			layout.encoding = ENCODING_DICTIONARY
			layout.data_bytes = dict_total
		} else {
			layout.encoding = ENCODING_PLAIN
			layout.data_bytes = plain_total
		}
	case .Unknown:
		return {}, .Invalid_Type
	}
	return layout, .None
}

@(private = "file")
write_null_mask_range :: proc(
	writer: ^Byte_Writer,
	null_mask: []bool,
	row_start, row_count: int,
) {
	byte_count := (row_count + 7) / 8
	for byte_index in 0 ..< byte_count {
		value: u8
		for bit_index in 0 ..< 8 {
			row_offset := byte_index * 8 + bit_index
			if row_offset < row_count && null_mask[row_start + row_offset] {
				value |= u8(1 << u32(bit_index))
			}
		}
		write_u8(writer, value)
	}
}

@(private = "file")
write_column_data_range :: proc(
	writer: ^Byte_Writer,
	column: ^snout_core.Column,
	row_start, row_count: int,
) {
	switch column.kind {
	case .Int64:
		for i in 0 ..< row_count {
			row := row_start + i
			write_i64(writer, 0 if column.null_mask[row] else column.int64s[row])
		}
	case .Float64:
		for i in 0 ..< row_count {
			row := row_start + i
			write_f64(writer, 0 if column.null_mask[row] else column.float64s[row])
		}
	case .Bool:
		for i in 0 ..< row_count {
			row := row_start + i
			write_u8(writer, 0 if column.null_mask[row] else u8(1 if column.bools[row] else 0))
		}
	case .String, .Timestamp:
		for i in 0 ..< row_count {
			row := row_start + i
			if column.null_mask[row] {
				write_u32(writer, 0)
			} else {
				write_u32(writer, u32(len(column.strings[row])))
				write_bytes(writer, transmute([]byte)column.strings[row])
			}
		}
	case .Unknown:
	}
}

@(private = "file")
write_column_data_range_dict :: proc(
	writer: ^Byte_Writer,
	column: ^snout_core.Column,
	row_start, row_count: int,
) {
	// Rebuild dictionary in insertion order.
	dict_map := make(map[string]u32, 16)
	defer delete(dict_map)
	dict_entries := make([dynamic]string, 0, 16)
	defer delete(dict_entries)

	for i in 0 ..< row_count {
		if column.null_mask[row_start + i] {
			continue
		}
		s := column.strings[row_start + i]
		if _, exists := dict_map[s]; !exists {
			dict_map[s] = u32(len(dict_entries))
			append(&dict_entries, s)
		}
	}

	dict_count := u32(len(dict_entries))
	index_width := 1 if dict_count <= 256 else 2

	// Write dict_entry_count.
	write_u32(writer, dict_count)

	// Write dictionary entries.
	for entry in dict_entries {
		write_u32(writer, u32(len(entry)))
		write_bytes(writer, transmute([]byte)entry)
	}

	// Write indices.
	for i in 0 ..< row_count {
		idx := u32(0)
		if !column.null_mask[row_start + i] {
			idx = dict_map[column.strings[row_start + i]]
		}
		if index_width == 1 {
			write_u8(writer, u8(idx))
		} else {
			write_u16(writer, u16(idx))
		}
	}
}

write_u8 :: proc(writer: ^Byte_Writer, value: u8) {
	writer.data[writer.offset] = value
	writer.offset += 1
}

write_u16 :: proc(writer: ^Byte_Writer, value: u16) {
	endian.unchecked_put_u16le(writer.data[writer.offset:], value)
	writer.offset += 2
}

write_u32 :: proc(writer: ^Byte_Writer, value: u32) {
	endian.unchecked_put_u32le(writer.data[writer.offset:], value)
	writer.offset += 4
}

write_u64 :: proc(writer: ^Byte_Writer, value: u64) {
	endian.unchecked_put_u64le(writer.data[writer.offset:], value)
	writer.offset += 8
}

write_i64 :: proc(writer: ^Byte_Writer, value: i64) {
	write_u64(writer, u64(value))
}

write_f64 :: proc(writer: ^Byte_Writer, value: f64) {
	write_u64(writer, transmute(u64)value)
}

write_bytes :: proc(writer: ^Byte_Writer, value: []byte) {
	copy(writer.data[writer.offset:], value)
	writer.offset += len(value)
}

write_string :: proc(writer: ^Byte_Writer, value: string) {
	write_u32(writer, u32(len(value)))
	write_bytes(writer, transmute([]byte)value)
}

write_zeroes :: proc(writer: ^Byte_Writer, count: int) {
	for _ in 0 ..< count {
		write_u8(writer, 0)
	}
}
