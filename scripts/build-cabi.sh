#!/usr/bin/env bash
# Build the SnoutDB C shared library (libsnout.dylib / libsnout.so).
set -euo pipefail

cd "$(dirname "$0")/.."

MODE="${1:-release}"

if [[ "$MODE" == "debug" ]]; then
    ODIN_FLAGS=(-debug)
    echo "Building libsnout (debug)..."
else
    ODIN_FLAGS=(-o:speed)
    echo "Building libsnout (release)..."
fi

odin build ./cabi -build-mode:shared -out:libsnout "${ODIN_FLAGS[@]}"

case "$(uname -s)" in
	Darwin) LIB_NAME="libsnout.dylib" ;;
	Linux)  LIB_NAME="libsnout.so" ;;
	*)
		echo "error: unsupported platform" >&2
		exit 1
		;;
esac

SIZE=$(du -h "$LIB_NAME" | awk '{print $1}')
echo "Done: $LIB_NAME (${SIZE})"
echo ""
echo "Exported symbols:"
if [[ "$(uname -s)" == "Darwin" ]]; then
	nm -gU "$LIB_NAME" | grep ' _snout_' | sed 's/^[^ ]* [^ ]* /  /'
else
	nm -D "$LIB_NAME" | grep ' snout_' | sed 's/^[^ ]* [^ ]* /  /'
fi
