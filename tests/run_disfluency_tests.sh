#!/bin/bash
set -euo pipefail
test_directory="$(cd "$(dirname "$0")" && pwd)"
source_directory="$test_directory/../Sources/LocalVerbatim"
test_build="$(mktemp -d "${TMPDIR:-/tmp}/localverbatim-disfluency-tests.XXXXXX")"
trap 'rm -rf "$test_build"' EXIT
test_module_cache="${LOCALVERBATIM_TEST_MODULE_CACHE:-$test_build/module-cache}"
swiftc -swift-version 5 -target arm64-apple-macos15.0 -parse-as-library \
  -module-cache-path "$test_module_cache" \
  "$source_directory/FillerReducer.swift" "$test_directory/test_disfluency.swift" \
  -o "$test_build/disfluency_tests"
"$test_build/disfluency_tests"
