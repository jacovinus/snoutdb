package tests

import "core:testing"
import snout_core "../core"

@(test)
version_matches_release_snapshot :: proc(t: ^testing.T) {
	testing.expect_value(t, snout_core.version(), "0.2.1")
}
