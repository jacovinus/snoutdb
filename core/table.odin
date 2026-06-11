package snout_core

get_column :: proc(table: ^Table, name: string) -> (^Column, bool) {
	for &column in table.columns {
		if column.name == name {
			return &column, true
		}
	}
	return nil, false
}

count_rows :: proc(table: ^Table) -> int {
	return table.row_count
}

free_table :: proc(table: ^Table) {
	if table == nil {
		return
	}

	allocator := table.allocator
	for &column in table.columns {
		delete(column.name, allocator)
		for value in column.strings {
			delete(value, allocator)
		}
		delete(column.strings, allocator)
		delete(column.int64s, allocator)
		delete(column.float64s, allocator)
		delete(column.bools, allocator)
		delete(column.null_mask, allocator)
	}
	delete(table.columns, allocator)
	delete(table.name, allocator)
	table^ = {}
}
