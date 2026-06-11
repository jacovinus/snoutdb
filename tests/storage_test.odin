package tests

import "core:encoding/endian"
import "core:os"
import "core:strings"
import "core:testing"
import snout_core "../core"
import aggregate "../exec"
import ingest "../ingest"
import storage "../storage"

COMPLEX_FIXTURE_PATH :: "tests/fixtures/complex_metrics.csv"
ROUND_TRIP_PATH :: "/tmp/snoutdb-task0002-roundtrip.snout"

@(test)
simple_table_round_trips :: proc(t: ^testing.T) {
	source, err := ingest.read_csv_table(FIXTURE_PATH, "simple_metrics")
	testing.expect_value(t, err, snout_core.Error.None)
	if err != .None {
		return
	}
	defer snout_core.free_table(&source)

	data, storage_err := storage.serialize_table(&source)
	testing.expect_value(t, storage_err, snout_core.Error.None)
	if storage_err != .None {
		return
	}
	defer delete(data)

	loaded, read_err := storage.deserialize_table(data)
	testing.expect_value(t, read_err, snout_core.Error.None)
	if read_err != .None {
		return
	}
	defer snout_core.free_table(&loaded)

	testing.expect_value(t, loaded.name, source.name)
	testing.expect_value(t, loaded.row_count, source.row_count)
	testing.expect_value(t, len(loaded.columns), len(source.columns))
	for column, index in loaded.columns {
		testing.expect_value(t, column.name, source.columns[index].name)
		testing.expect_value(t, column.kind, source.columns[index].kind)
	}
	status, found := snout_core.get_column(&loaded, "status")
	testing.expect(t, found)
	if found {
		testing.expect_value(t, status.int64s[2], i64(500))
	}
}

@(test)
complex_table_round_trips_through_file :: proc(t: ^testing.T) {
	_ = os.remove(ROUND_TRIP_PATH)
	defer os.remove(ROUND_TRIP_PATH)

	source, err := ingest.read_csv_table(COMPLEX_FIXTURE_PATH, "complex_metrics")
	testing.expect_value(t, err, snout_core.Error.None)
	if err != .None {
		return
	}
	defer snout_core.free_table(&source)

	write_err := storage.write_snout_file(ROUND_TRIP_PATH, &source)
	testing.expect_value(t, write_err, snout_core.Error.None)
	if write_err != .None {
		return
	}

	loaded, read_err := storage.read_snout_file(ROUND_TRIP_PATH)
	testing.expect_value(t, read_err, snout_core.Error.None)
	if read_err != .None {
		return
	}
	defer snout_core.free_table(&loaded)

	testing.expect_value(t, loaded.row_count, 25)
	testing.expect_value(t, len(loaded.columns), 10)

	latency, found := snout_core.get_column(&loaded, "latency_ms")
	testing.expect(t, found)
	if found {
		testing.expect(t, latency.nullable)
		testing.expect(t, latency.null_mask[15])
	}

	cached, cached_found := snout_core.get_column(&loaded, "cached")
	testing.expect(t, cached_found)
	if cached_found {
		testing.expect(t, cached.bools[0])
		testing.expect(t, !cached.bools[1])
	}

	response_seconds, response_found := snout_core.get_column(&loaded, "response_seconds")
	testing.expect(t, response_found)
	if response_found {
		testing.expect_value(t, response_seconds.float64s[13], 0.510)
	}

	note, note_found := snout_core.get_column(&loaded, "note")
	testing.expect(t, note_found)
	if note_found {
		testing.expect_value(t, note.strings[1], "client said \"hello\"")
		testing.expect_value(t, note.strings[2], "payment failed, retry scheduled")
	}
}

@(test)
stats_survive_round_trip :: proc(t: ^testing.T) {
	source, err := ingest.read_csv_table(COMPLEX_FIXTURE_PATH, "complex_metrics")
	testing.expect_value(t, err, snout_core.Error.None)
	if err != .None {
		return
	}
	defer snout_core.free_table(&source)

	data, storage_err := storage.serialize_table(&source)
	testing.expect_value(t, storage_err, snout_core.Error.None)
	if storage_err != .None {
		return
	}
	defer delete(data)

	loaded, read_err := storage.deserialize_table(data)
	testing.expect_value(t, read_err, snout_core.Error.None)
	if read_err != .None {
		return
	}
	defer snout_core.free_table(&loaded)

	stats, stats_err := aggregate.numeric_stats(&loaded, "latency_ms")
	testing.expect_value(t, stats_err, snout_core.Error.None)
	testing.expect_value(t, stats.count, 24)
	testing.expect_value(t, stats.null_count, 1)
	testing.expect_value(t, stats.sum, 1865.0)
	testing.expect_value(t, stats.min, 2.0)
	testing.expect_value(t, stats.max, 510.0)
}

@(test)
serialized_output_is_deterministic :: proc(t: ^testing.T) {
	table, err := ingest.read_csv_table(COMPLEX_FIXTURE_PATH, "complex_metrics")
	testing.expect_value(t, err, snout_core.Error.None)
	if err != .None {
		return
	}
	defer snout_core.free_table(&table)

	first, first_err := storage.serialize_table(&table)
	testing.expect_value(t, first_err, snout_core.Error.None)
	if first_err != .None {
		return
	}
	defer delete(first)

	second, second_err := storage.serialize_table(&table)
	testing.expect_value(t, second_err, snout_core.Error.None)
	if second_err != .None {
		return
	}
	defer delete(second)

	testing.expect(t, equal_bytes(first, second))
}

@(test)
invalid_magic_is_rejected :: proc(t: ^testing.T) {
	data := serialized_simple_table(t)
	if data == nil {
		return
	}
	defer delete(data)

	data[0] = 'X'
	_, err := storage.deserialize_table(data)
	testing.expect_value(t, err, snout_core.Error.Invalid_Magic)
}

@(test)
unsupported_version_is_rejected :: proc(t: ^testing.T) {
	data := serialized_simple_table(t)
	if data == nil {
		return
	}
	defer delete(data)

	endian.unchecked_put_u16le(data[8:], 3)
	_, err := storage.deserialize_table(data)
	testing.expect_value(t, err, snout_core.Error.Unsupported_Version)
}

@(test)
unsupported_endianness_is_rejected :: proc(t: ^testing.T) {
	data := serialized_simple_table(t)
	if data == nil {
		return
	}
	defer delete(data)

	data[12] = 2
	_, err := storage.deserialize_table(data)
	testing.expect_value(t, err, snout_core.Error.Unsupported_Endianness)
}

@(test)
truncated_files_are_rejected :: proc(t: ^testing.T) {
	data := serialized_simple_table(t)
	if data == nil {
		return
	}
	defer delete(data)

	points := [?]int{1, 31, 40, len(data)/2, len(data)-1}
	for point in points {
		_, err := storage.deserialize_table(data[:point])
		testing.expectf(t, err != .None, "expected truncation at byte %d to fail", point)
	}
}

@(test)
invalid_type_identifier_is_rejected :: proc(t: ^testing.T) {
	data := serialized_simple_table(t)
	if data == nil {
		return
	}
	defer delete(data)

	type_offset, ok := first_column_type_offset(data)
	testing.expect(t, ok)
	if !ok {
		return
	}
	data[type_offset] = 255
	_, err := storage.deserialize_table(data)
	testing.expect_value(t, err, snout_core.Error.Invalid_Type)
}

@(test)
invalid_declared_size_is_rejected :: proc(t: ^testing.T) {
	data := serialized_simple_table(t)
	if data == nil {
		return
	}
	defer delete(data)

	endian.unchecked_put_u64le(data[16:], u64(len(data)+1))
	_, err := storage.deserialize_table(data)
	testing.expect_value(t, err, snout_core.Error.Invalid_File_Size)
}

@(test)
invalid_footer_is_rejected :: proc(t: ^testing.T) {
	data := serialized_simple_table(t)
	if data == nil {
		return
	}
	defer delete(data)

	data[len(data)-16] = 'X'
	_, err := storage.deserialize_table(data)
	testing.expect_value(t, err, snout_core.Error.Invalid_Footer)
}

@(test)
empty_and_null_strings_remain_distinct :: proc(t: ^testing.T) {
	table := make_empty_and_null_table()
	defer snout_core.free_table(&table)

	data, storage_err := storage.serialize_table(&table)
	testing.expect_value(t, storage_err, snout_core.Error.None)
	if storage_err != .None {
		return
	}
	defer delete(data)

	loaded, read_err := storage.deserialize_table(data)
	testing.expect_value(t, read_err, snout_core.Error.None)
	if read_err != .None {
		return
	}
	defer snout_core.free_table(&loaded)

	note, found := snout_core.get_column(&loaded, "note")
	testing.expect(t, found)
	if found {
		testing.expect(t, note.null_mask[0])
		testing.expect(t, !note.null_mask[1])
		testing.expect_value(t, note.strings[0], "")
		testing.expect_value(t, note.strings[1], "")
		testing.expect_value(t, note.strings[2], "text")
	}
}

serialized_simple_table :: proc(t: ^testing.T) -> []byte {
	table, err := ingest.read_csv_table(FIXTURE_PATH, "simple_metrics")
	testing.expect_value(t, err, snout_core.Error.None)
	if err != .None {
		return nil
	}
	defer snout_core.free_table(&table)

	data, storage_err := storage.serialize_table(&table)
	testing.expect_value(t, storage_err, snout_core.Error.None)
	return data
}

first_column_type_offset :: proc(data: []byte) -> (int, bool) {
	if len(data) < storage.HEADER_SIZE+4 {
		return 0, false
	}
	table_name_length := int(endian.unchecked_get_u32le(data[storage.HEADER_SIZE:]))
	// v2 table metadata: name(4+len) + row_count(8) + column_count(4) + chunk_count(4)
	offset := storage.HEADER_SIZE + 4 + table_name_length + 8 + 4 + 4
	if offset > len(data)-4 {
		return 0, false
	}
	column_name_length := int(endian.unchecked_get_u32le(data[offset:]))
	type_offset := offset + 4 + column_name_length
	return type_offset, type_offset < len(data)
}

make_empty_and_null_table :: proc() -> snout_core.Table {
	table := snout_core.Table{
		name = clone_string("strings"),
		row_count = 3,
		allocator = context.allocator,
	}
	table.columns, _ = make([]snout_core.Column, 1)
	column := &table.columns[0]
	column.name = clone_string("note")
	column.kind = .String
	column.nullable = true
	column.null_mask, _ = make([]bool, 3)
	column.null_mask[0] = true
	column.strings, _ = make([]string, 3)
	column.strings[0] = clone_string("")
	column.strings[1] = clone_string("")
	column.strings[2] = clone_string("text")
	return table
}

@(test)
dictionary_encoding_round_trip :: proc(t: ^testing.T) {
	// Low-cardinality String column: 20 rows, 3 distinct values.
	// Dictionary should be chosen (much smaller than plain).
	regions := [?]string{"us-east", "us-west", "eu-west"}
	table := snout_core.Table{
		name      = clone_string("test"),
		row_count = 20,
		allocator = context.allocator,
	}
	table.columns, _ = make([]snout_core.Column, 1)
	col := &table.columns[0]
	col.name = clone_string("region")
	col.kind = .String
	col.nullable = false
	col.strings, _ = make([]string, 20)
	col.null_mask, _ = make([]bool, 20)
	for i in 0 ..< 20 {
		col.strings[i] = clone_string(regions[i % 3])
	}
	defer snout_core.free_table(&table)

	data, storage_err := storage.serialize_table(&table)
	testing.expect_value(t, storage_err, snout_core.Error.None)
	if storage_err != .None {
		return
	}
	defer delete(data)

	// Verify encoding byte in the first column chunk header = ENCODING_DICTIONARY (1).
	// Layout: HEADER(32) + name(4+4) + row_count(8) + col_count(4) + chunk_count(4)
	//         + col_descriptor: name(4+6) + type(1) + nullable(1) + reserved(2)
	//         + chunk_row_count(4) → then column chunk header starts
	table_meta_end := storage.HEADER_SIZE + 4 + 4 + 8 + 4 + 4
	col_desc_end := table_meta_end + 4 + 6 + 1 + 1 + 2
	chunk_row_count_end := col_desc_end + 4
	encoding_offset := chunk_row_count_end
	testing.expect_value(t, data[encoding_offset], u8(1)) // ENCODING_DICTIONARY

	// Round-trip: values should be preserved exactly.
	loaded, read_err := storage.deserialize_table(data)
	testing.expect_value(t, read_err, snout_core.Error.None)
	if read_err != .None {
		return
	}
	defer snout_core.free_table(&loaded)

	testing.expect_value(t, loaded.row_count, 20)
	r, found := snout_core.get_column(&loaded, "region")
	testing.expect(t, found)
	if found {
		for i in 0 ..< 20 {
			testing.expect_value(t, r.strings[i], regions[i % 3])
		}
	}
}

@(test)
dictionary_encoding_with_nulls_round_trip :: proc(t: ^testing.T) {
	// Nullable String column: 12 rows, every 3rd row is null, 2 distinct non-null values.
	table := snout_core.Table{
		name      = clone_string("test"),
		row_count = 12,
		allocator = context.allocator,
	}
	table.columns, _ = make([]snout_core.Column, 1)
	col := &table.columns[0]
	col.name = clone_string("label")
	col.kind = .String
	col.nullable = true
	col.strings, _ = make([]string, 12)
	col.null_mask, _ = make([]bool, 12)
	for i in 0 ..< 12 {
		if i % 3 == 0 {
			col.null_mask[i] = true
			col.strings[i] = clone_string("")
		} else {
			col.strings[i] = clone_string("yes" if i % 3 == 1 else "no")
		}
	}
	defer snout_core.free_table(&table)

	data, storage_err := storage.serialize_table(&table)
	testing.expect_value(t, storage_err, snout_core.Error.None)
	if storage_err != .None {
		return
	}
	defer delete(data)

	loaded, read_err := storage.deserialize_table(data)
	testing.expect_value(t, read_err, snout_core.Error.None)
	if read_err != .None {
		return
	}
	defer snout_core.free_table(&loaded)

	r, found := snout_core.get_column(&loaded, "label")
	testing.expect(t, found)
	if found {
		for i in 0 ..< 12 {
			if i % 3 == 0 {
				testing.expect(t, r.null_mask[i])
			} else {
				testing.expect(t, !r.null_mask[i])
				expected := "yes" if i % 3 == 1 else "no"
				testing.expect_value(t, r.strings[i], expected)
			}
		}
	}
}

@(test)
high_cardinality_falls_back_to_plain :: proc(t: ^testing.T) {
	// 10 rows, all distinct long strings → plain is smaller than dictionary.
	values := [?]string{
		"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
		"bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb",
		"cccccccccccccccccccccccccccccccc",
		"dddddddddddddddddddddddddddddddd",
		"eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee",
		"ffffffffffffffffffffffffffffffff",
		"gggggggggggggggggggggggggggggggg",
		"hhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhh",
		"iiiiiiiiiiiiiiiiiiiiiiiiiiiiiiii",
		"jjjjjjjjjjjjjjjjjjjjjjjjjjjjjj",
	}
	table := snout_core.Table{
		name      = clone_string("test"),
		row_count = 10,
		allocator = context.allocator,
	}
	table.columns, _ = make([]snout_core.Column, 1)
	col := &table.columns[0]
	col.name = clone_string("uid")
	col.kind = .String
	col.nullable = false
	col.strings, _ = make([]string, 10)
	col.null_mask, _ = make([]bool, 10)
	for i in 0 ..< 10 {
		col.strings[i] = clone_string(values[i])
	}
	defer snout_core.free_table(&table)

	data, storage_err := storage.serialize_table(&table)
	testing.expect_value(t, storage_err, snout_core.Error.None)
	if storage_err != .None {
		return
	}
	defer delete(data)

	// Verify encoding byte = ENCODING_PLAIN (0).
	table_meta_end := storage.HEADER_SIZE + 4 + 3 + 8 + 4 + 4 // name="uid" len=3
	col_desc_end := table_meta_end + 4 + 3 + 1 + 1 + 2
	encoding_offset := col_desc_end + 4
	testing.expect_value(t, data[encoding_offset], u8(0)) // ENCODING_PLAIN

	// Values survive round-trip.
	loaded, read_err := storage.deserialize_table(data)
	testing.expect_value(t, read_err, snout_core.Error.None)
	if read_err != .None {
		return
	}
	defer snout_core.free_table(&loaded)

	uid, found := snout_core.get_column(&loaded, "uid")
	testing.expect(t, found)
	if found {
		for i in 0 ..< 10 {
			testing.expect_value(t, uid.strings[i], values[i])
		}
	}
}

@(test)
zero_row_table_round_trips :: proc(t: ^testing.T) {
	table := snout_core.Table{
		name      = clone_string("empty"),
		row_count = 0,
		allocator = context.allocator,
	}
	table.columns, _ = make([]snout_core.Column, 2)
	table.columns[0] = snout_core.Column{
		name      = clone_string("id"),
		kind      = .Int64,
		nullable  = false,
		int64s    = make([]i64, 0),
		null_mask = make([]bool, 0),
	}
	table.columns[1] = snout_core.Column{
		name      = clone_string("label"),
		kind      = .String,
		nullable  = true,
		strings   = make([]string, 0),
		null_mask = make([]bool, 0),
	}
	defer snout_core.free_table(&table)

	data, storage_err := storage.serialize_table(&table)
	testing.expect_value(t, storage_err, snout_core.Error.None)
	if storage_err != .None {
		return
	}
	defer delete(data)

	loaded, read_err := storage.deserialize_table(data)
	testing.expect_value(t, read_err, snout_core.Error.None)
	if read_err != .None {
		return
	}
	defer snout_core.free_table(&loaded)

	testing.expect_value(t, loaded.row_count, 0)
	testing.expect_value(t, len(loaded.columns), 2)
	testing.expect_value(t, loaded.columns[0].name, "id")
	testing.expect_value(t, loaded.columns[1].name, "label")
}

@(test)
chunk_stats_are_stored_correctly :: proc(t: ^testing.T) {
	source, err := ingest.read_csv_table(COMPLEX_FIXTURE_PATH, "complex_metrics")
	testing.expect_value(t, err, snout_core.Error.None)
	if err != .None {
		return
	}
	defer snout_core.free_table(&source)

	data, storage_err := storage.serialize_table(&source)
	testing.expect_value(t, storage_err, snout_core.Error.None)
	if storage_err != .None {
		return
	}
	defer delete(data)

	// Locate the first column chunk header.
	// Layout after HEADER_SIZE:
	//   table_name(4+len) + row_count(8) + column_count(4) + chunk_count(4)
	//   column_descriptors × 10: name(4+len) + type_id(1) + nullable(1) + reserved(2)
	//   first chunk: chunk_row_count(4), then first column chunk header(32)
	table_name_len := int(endian.unchecked_get_u32le(data[storage.HEADER_SIZE:]))
	col_desc_start := storage.HEADER_SIZE + 4 + table_name_len + 8 + 4 + 4

	// Skip all 10 column descriptors to find the start of the chunks section.
	offset := col_desc_start
	for _ in 0 ..< 10 {
		if offset+4 > len(data) {
			testing.fail(t)
			return
		}
		col_name_len := int(endian.unchecked_get_u32le(data[offset:]))
		offset += 4 + col_name_len + 1 + 1 + 2
	}

	// Now at chunk_row_count (u32).
	chunk_row_count := int(endian.unchecked_get_u32le(data[offset:]))
	testing.expect_value(t, chunk_row_count, 25)
	offset += 4

	// First column chunk header (32 bytes):
	//   encoding(1) + reserved(3) + null_count(4) + min(8) + max(8) + data_size(8)
	encoding := data[offset]
	testing.expect_value(t, encoding, u8(0)) // ENCODING_PLAIN
	null_count := endian.unchecked_get_u32le(data[offset+4:])
	testing.expect_value(t, null_count, u32(0)) // first column (region) is not nullable
}

clone_string :: proc(value: string) -> string {
	result, _ := strings.clone(value)
	return result
}

equal_bytes :: proc(a, b: []byte) -> bool {
	if len(a) != len(b) {
		return false
	}
	for value, index in a {
		if value != b[index] {
			return false
		}
	}
	return true
}
