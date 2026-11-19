#!/bin/bash
set -euo pipefail
test_directory="$(cd "$(dirname "$0")" && pwd)"
source_directory="$test_directory/../Sources/LocalVerbatim"
test_build="$(mktemp -d "${TMPDIR:-/tmp}/localverbatim-swift-tests.XXXXXX")"
trap 'rm -rf "$test_build"' EXIT
test_module_cache="${LOCALVERBATIM_TEST_MODULE_CACHE:-$test_build/module-cache}"

# Test private capture helpers against the production source without copying
# their implementation into a test fixture. No recording devices are opened.
cat "$source_directory/AudioCapture.swift" "$test_directory/test_audio.swift" > "$test_build/audio_all.swift"
swiftc -swift-version 5 -target arm64-apple-macos15.0 -parse-as-library \
  -module-cache-path "$test_module_cache" "$test_build/audio_all.swift" "$source_directory/Models.swift" "$source_directory/MeetingFiles.swift" "$source_directory/FillerReducer.swift" "$source_directory/AppSettings.swift" "$source_directory/AsyncTimeout.swift" -o "$test_build/audio_tests"
"$test_build/audio_tests"

swiftc -swift-version 5 -target arm64-apple-macos15.0 -parse-as-library \
  -module-cache-path "$test_module_cache" \
  "$source_directory/AudioCapture.swift" "$source_directory/Models.swift" "$source_directory/MeetingFiles.swift" "$source_directory/FillerReducer.swift" "$source_directory/AppSettings.swift" "$source_directory/AsyncTimeout.swift" \
  "$source_directory/Recovery.swift" "$test_directory/test_recovery.swift" -o "$test_build/recovery_tests"
"$test_build/recovery_tests"

swiftc -swift-version 5 -target arm64-apple-macos15.0 -parse-as-library \
  -module-cache-path "$test_module_cache" \
  "$source_directory/AudioCapture.swift" "$source_directory/Models.swift" "$source_directory/MeetingFiles.swift" "$source_directory/FillerReducer.swift" "$source_directory/AppSettings.swift" "$source_directory/AsyncTimeout.swift" \
  "$test_directory/test_overlap.swift" -o "$test_build/overlap_tests"
"$test_build/overlap_tests"

swiftc -swift-version 5 -target arm64-apple-macos15.0 -parse-as-library \
  -module-cache-path "$test_module_cache" \
  "$source_directory/AudioCapture.swift" "$source_directory/Models.swift" "$source_directory/MeetingFiles.swift" "$source_directory/FillerReducer.swift" "$source_directory/AppSettings.swift" "$source_directory/AsyncTimeout.swift" "$source_directory/RefinementPlanner.swift" \
  "$test_directory/test_refinement.swift" -o "$test_build/refinement_tests"
"$test_build/refinement_tests"
