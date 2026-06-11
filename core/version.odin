package snout_core

import "core:strings"

VERSION_SOURCE :: #load("../VERSION")

version :: proc() -> string {
	return strings.trim_space(string(VERSION_SOURCE))
}
