package snout_core

import "base:runtime"

Column_Type :: enum {
	Unknown,
	String,
	Int64,
	Float64,
	Bool,
	Timestamp,
}

Error :: enum {
	None,
	Out_Of_Memory,
	Io,
	Empty_Input,
	Parse,
	Malformed_JSON,
	Multiline_Quoted_Field,
	Column_Count_Mismatch,
	Invalid_Value,
	Column_Not_Found,
	Wrong_Column_Type,
	Invalid_Magic,
	Unsupported_Version,
	Unsupported_Endianness,
	Invalid_File_Size,
	Invalid_Footer,
	Invalid_Type,
	Invalid_Null_Mask,
	Invalid_Column_Data,
	Unexpected_End_Of_File,
	Value_Too_Large,
	Expected_JSON_Object,
	Unsupported_JSON_Value,
	Duplicate_JSON_Key,
	Incompatible_JSON_Types,
	Number_Out_Of_Range,
	Line_Too_Large,
	Too_Many_Columns,
	Too_Many_Records,
	Unsupported_Input_Format,
	Invalid_Aggregate,
	Invalid_Filter_Operator,
	Invalid_Filter_Value,
	Unsupported_Filter_Operator,
	Unsupported_Group_Column_Type,
	Invalid_Aggregate_Column,
	Aggregate_Overflow,
	Malformed_Query_Arguments,
	Too_Many_Filters,
	Too_Many_Groups,
	Invalid_Sort_Direction,
	Sort_Target_Not_Found,
	Duplicate_Sort_Target,
	Too_Many_Sort_Terms,
	Duplicate_Result_Column,
	Invalid_Limit,
	Limit_Too_Large,
	Invalid_Output_Format,
	Invalid_Numeric_Output,
	Output_Write_Failed,
	Invalid_Sniff_Option,
	Sniff_Limit_Too_Large,
	Invalid_Sniff_Config,
	Invalid_Profile_Value,
	Non_Finite_Profile_Value,
	Input_Changed_During_Read,
	Csv_Field_Too_Large,
	Csv_Record_Too_Large,
	Unknown_Log_Format,
	Log_Parse_Error,
}

error_message :: proc(err: Error) -> string {
	switch err {
	case .None:
		return "no error"
	case .Out_Of_Memory:
		return "out of memory"
	case .Io:
		return "could not read input"
	case .Empty_Input:
		return "input is empty"
	case .Parse:
		return "invalid CSV input"
	case .Malformed_JSON:
		return "malformed JSON input"
	case .Multiline_Quoted_Field:
		return "multi-line quoted CSV fields are not supported"
	case .Column_Count_Mismatch:
		return "CSV row has a different number of columns than the header"
	case .Invalid_Value:
		return "value cannot be converted to the inferred column type"
	case .Column_Not_Found:
		return "column not found"
	case .Wrong_Column_Type:
		return "aggregation requires a numeric column"
	case .Invalid_Magic:
		return "invalid .snout magic bytes"
	case .Unsupported_Version:
		return "unsupported .snout version"
	case .Unsupported_Endianness:
		return "unsupported .snout endianness"
	case .Invalid_File_Size:
		return "invalid .snout file size"
	case .Invalid_Footer:
		return "invalid .snout footer"
	case .Invalid_Type:
		return "invalid persisted column type"
	case .Invalid_Null_Mask:
		return "invalid persisted null mask"
	case .Invalid_Column_Data:
		return "invalid persisted column data"
	case .Unexpected_End_Of_File:
		return "unexpected end of .snout file"
	case .Value_Too_Large:
		return "value exceeds .snout format limits"
	case .Expected_JSON_Object:
		return "expected one JSON object per line"
	case .Unsupported_JSON_Value:
		return "nested JSON objects and arrays are not supported"
	case .Duplicate_JSON_Key:
		return "duplicate key in JSON object"
	case .Incompatible_JSON_Types:
		return "incompatible JSON types in the same column"
	case .Number_Out_Of_Range:
		return "JSON number is outside the supported range"
	case .Line_Too_Large:
		return "JSONL line exceeds the size limit"
	case .Too_Many_Columns:
		return "JSONL input contains too many columns"
	case .Too_Many_Records:
		return "JSONL input contains too many records"
	case .Unsupported_Input_Format:
		return "unsupported input format"
	case .Invalid_Aggregate:
		return "invalid aggregate"
	case .Invalid_Filter_Operator:
		return "invalid filter operator"
	case .Invalid_Filter_Value:
		return "invalid filter value"
	case .Unsupported_Filter_Operator:
		return "filter operator is not supported for the column type"
	case .Unsupported_Group_Column_Type:
		return "column type cannot be used as a group key"
	case .Invalid_Aggregate_Column:
		return "aggregate requires a compatible value column"
	case .Aggregate_Overflow:
		return "integer aggregate overflow"
	case .Malformed_Query_Arguments:
		return "malformed query arguments"
	case .Too_Many_Filters:
		return "query contains too many filters"
	case .Too_Many_Groups:
		return "query produced too many groups"
	case .Invalid_Sort_Direction:
		return "invalid sort direction"
	case .Sort_Target_Not_Found:
		return "sort target is not part of the result"
	case .Duplicate_Sort_Target:
		return "duplicate sort target"
	case .Too_Many_Sort_Terms:
		return "query contains too many sort terms"
	case .Duplicate_Result_Column:
		return "duplicate result column"
	case .Invalid_Limit:
		return "invalid result limit"
	case .Limit_Too_Large:
		return "result limit is too large"
	case .Invalid_Output_Format:
		return "invalid output format"
	case .Invalid_Numeric_Output:
		return "non-finite numeric output"
	case .Output_Write_Failed:
		return "could not write output"
	case .Invalid_Sniff_Option:
		return "invalid sniff option"
	case .Sniff_Limit_Too_Large:
		return "sniff limit is too large"
	case .Invalid_Sniff_Config:
		return "invalid sniff configuration"
	case .Invalid_Profile_Value:
		return "invalid profile value"
	case .Non_Finite_Profile_Value:
		return "non-finite value found in column"
	case .Input_Changed_During_Read:
		return "input file changed between read passes"
	case .Csv_Field_Too_Large:
		return "CSV field exceeds the size limit"
	case .Csv_Record_Too_Large:
		return "CSV record exceeds the size limit"
	case .Unknown_Log_Format:
		return "log format could not be detected; use --format to specify"
	case .Log_Parse_Error:
		return "malformed log line"
	}
	return "unknown error"
}

Table :: struct {
	name:      string,
	row_count: int,
	columns:   []Column,
	allocator: runtime.Allocator,
}
