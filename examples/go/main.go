// SnoutDB Go example — calls libsnout via cgo.
//
// Run from the repo root:
//   cd examples/go && go run main.go
package main

/*
#cgo CFLAGS:  -I../../include
#cgo LDFLAGS: -L../../ -lsnout -Wl,-rpath,../../
#include "snoutdb.h"
#include <stdlib.h>
*/
import "C"
import (
	"fmt"
	"os"
	"path/filepath"
	"runtime"
	"unsafe"
)

// typeNames maps SNOUT_TYPE_* constants to readable strings.
var typeNames = map[C.int]string{
	0: "String",
	1: "Int64",
	2: "Float64",
	3: "Bool",
	4: "Timestamp",
}

func checkTable(t *C.SnoutTable, label string) *C.SnoutTable {
	if t == nil {
		msg := C.GoString(C.snout_last_error())
		fmt.Fprintf(os.Stderr, "error [%s]: %s\n", label, msg)
		os.Exit(1)
	}
	return t
}

func checkResult(r *C.SnoutResult, label string) *C.SnoutResult {
	if r == nil {
		msg := C.GoString(C.snout_last_error())
		fmt.Fprintf(os.Stderr, "error [%s]: %s\n", label, msg)
		os.Exit(1)
	}
	return r
}

// repoRoot returns the absolute path to the repo root (two levels up from this file).
func repoRoot() string {
	_, file, _, _ := runtime.Caller(0)
	return filepath.Join(filepath.Dir(file), "..", "..")
}

// makeWhereArray builds a C array of strings for snout_query's where_exprs.
// Each filter is a triplet: col, op, val.
func makeWhereArray(filters [][]string) (**C.char, C.int) {
	flat := make([]string, 0)
	for _, f := range filters {
		flat = append(flat, f...)
	}
	if len(flat) == 0 {
		return nil, 0
	}
	arr := make([]*C.char, len(flat))
	for i, s := range flat {
		arr[i] = C.CString(s)
	}
	return (**C.char)(unsafe.Pointer(&arr[0])), C.int(len(flat))
}

func freeWhereArray(arr **C.char, count C.int) {
	if arr == nil {
		return
	}
	slice := (*[1 << 20]*C.char)(unsafe.Pointer(arr))[:count:count]
	for _, s := range slice {
		C.free(unsafe.Pointer(s))
	}
}

func resultValue(r *C.SnoutResult, row, col int, colType C.int) string {
	if C.snout_result_is_null(r, C.int(row), C.int(col)) != 0 {
		return "NULL"
	}
	switch colType {
	case 1: // Int64
		return fmt.Sprintf("%d", int64(C.snout_result_get_int64(r, C.int(row), C.int(col))))
	case 2: // Float64
		return fmt.Sprintf("%.6f", float64(C.snout_result_get_float64(r, C.int(row), C.int(col))))
	default:
		s := C.snout_result_get_string(r, C.int(row), C.int(col))
		if s == nil {
			return "NULL"
		}
		return C.GoString(s)
	}
}

func main() {
	root := repoRoot()
	csvPath := filepath.Join(root, "tests/fixtures/complex_metrics_500.csv")

	fmt.Println("══════════════════════════════════════════════════════")
	fmt.Println("Go → SnoutDB via C ABI")
	fmt.Println("══════════════════════════════════════════════════════")

	// 1. Import CSV
	cPath := C.CString(csvPath)
	defer C.free(unsafe.Pointer(cPath))
	t := checkTable(C.snout_import_csv(cPath), "snout_import_csv")
	defer C.snout_close(t)

	rows := int64(C.snout_row_count(t))
	ncols := int(C.snout_column_count(t))

	fmt.Printf("\n1. Schema  (%d rows, %d columns)\n", rows, ncols)
	fmt.Printf("   %-22s %s\n", "column", "type")
	fmt.Printf("   %-22s %s\n", "----------------------", "----------")
	for c := 0; c < ncols; c++ {
		name := C.GoString(C.snout_column_name(t, C.int(c)))
		typ := typeNames[C.snout_column_type(t, C.int(c))]
		fmt.Printf("   %-22s %s\n", name, typ)
	}

	// 2. First 3 rows
	fmt.Println("\n2. First 3 rows (call_id, region, mos, result)")
	interesting := []string{"call_id", "region", "mos", "result"}
	colMap := map[string]struct{ idx, typ int }{}
	for c := 0; c < ncols; c++ {
		name := C.GoString(C.snout_column_name(t, C.int(c)))
		for _, n := range interesting {
			if n == name {
				colMap[name] = struct{ idx, typ int }{c, int(C.snout_column_type(t, C.int(c)))}
			}
		}
	}
	headerLine := "   "
	for _, n := range interesting {
		headerLine += fmt.Sprintf("%-20s  ", n)
	}
	fmt.Println(headerLine)
	for row := 0; row < 3; row++ {
		line := "   "
		for _, n := range interesting {
			info := colMap[n]
			var val string
			if C.snout_is_null(t, C.int64_t(row), C.int(info.idx)) != 0 {
				val = "NULL"
			} else {
				switch info.typ {
				case 1:
					val = fmt.Sprintf("%d", int64(C.snout_get_int64(t, C.int64_t(row), C.int(info.idx))))
				case 2:
					val = fmt.Sprintf("%.2f", float64(C.snout_get_float64(t, C.int64_t(row), C.int(info.idx))))
				default:
					s := C.snout_get_string(t, C.int64_t(row), C.int(info.idx))
					if s == nil {
						val = "NULL"
					} else {
						val = C.GoString(s)
					}
				}
			}
			line += fmt.Sprintf("%-20s  ", val)
		}
		fmt.Println(line)
	}

	// 3. Query: avg + sum + count by carrier
	fmt.Println("\n3. Query: avg(mos), avg(jitter_ms), count(*) by carrier")
	cGroups := C.CString("carrier")
	cAggs := C.CString("avg=mos avg=jitter_ms count=rows")
	cSort := C.CString("avg=mos desc")
	defer C.free(unsafe.Pointer(cGroups))
	defer C.free(unsafe.Pointer(cAggs))
	defer C.free(unsafe.Pointer(cSort))

	r := checkResult(
		C.snout_query(t, cGroups, cAggs, nil, 0, cSort, 0),
		"snout_query",
	)
	defer C.snout_result_free(r)

	rcols := int(C.snout_result_col_count(r))
	rrows := int(C.snout_result_row_count(r))
	names := make([]string, rcols)
	types := make([]C.int, rcols)
	for c := 0; c < rcols; c++ {
		names[c] = C.GoString(C.snout_result_col_name(r, C.int(c)))
		types[c] = C.snout_result_col_type(r, C.int(c))
	}
	line := "   "
	for _, n := range names {
		line += fmt.Sprintf("%-22s  ", n)
	}
	fmt.Println(line)
	for row := 0; row < rrows; row++ {
		line = "   "
		for c := 0; c < rcols; c++ {
			line += fmt.Sprintf("%-22s  ", resultValue(r, row, c, types[c]))
		}
		fmt.Println(line)
	}

	// 4. Query with filter: failed calls, p95 jitter by region
	fmt.Println("\n4. Query: p95(jitter_ms) by region  [where result eq failed]")
	where, wcount := makeWhereArray([][]string{{"result", "eq", "failed"}})
	defer freeWhereArray(where, wcount)

	cGroups2 := C.CString("region")
	cAggs2 := C.CString("p95=jitter_ms count=rows")
	cSort2 := C.CString("p95=jitter_ms desc")
	defer C.free(unsafe.Pointer(cGroups2))
	defer C.free(unsafe.Pointer(cAggs2))
	defer C.free(unsafe.Pointer(cSort2))

	r2 := checkResult(
		C.snout_query(t, cGroups2, cAggs2, where, wcount, cSort2, 0),
		"snout_query with filter",
	)
	defer C.snout_result_free(r2)

	rcols2 := int(C.snout_result_col_count(r2))
	rrows2 := int(C.snout_result_row_count(r2))
	names2 := make([]string, rcols2)
	types2 := make([]C.int, rcols2)
	for c := 0; c < rcols2; c++ {
		names2[c] = C.GoString(C.snout_result_col_name(r2, C.int(c)))
		types2[c] = C.snout_result_col_type(r2, C.int(c))
	}
	line2 := "   "
	for _, n := range names2 {
		line2 += fmt.Sprintf("%-22s  ", n)
	}
	fmt.Println(line2)
	for row := 0; row < rrows2; row++ {
		l := "   "
		for c := 0; c < rcols2; c++ {
			l += fmt.Sprintf("%-22s  ", resultValue(r2, row, c, types2[c]))
		}
		fmt.Println(l)
	}

	fmt.Println("\n✓ Done\n")
}
