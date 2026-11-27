#!/bin/bash
set -euo pipefail
test_directory="$(cd "$(dirname "$0")" && pwd)"
source_directory="$test_directory/../Sources/LocalVerbatim"
test_build="$(mktemp -d "${TMPDIR:-/tmp}/localverbatim-lifecycle-tests.XXXXXX")"
trap 'rm -rf "$test_build"' EXIT
test_module_cache="${LOCALVERBATIM_TEST_MODULE_CACHE:-$test_build/module-cache}"

# Recovery shares a pure windowing helper with capture. Compile that exact
# production enum without bringing in the real device-owning AudioCapture.
awk 'BEGIN { print "import Foundation" }
  /^enum AudioWindowing \{/ { in_enum = 1 }
  in_enum { print }
  in_enum && /^}/ { exit }' "$source_directory/AudioCapture.swift" > "$test_build/AudioWindowing.swift"

# Link production lifecycle, persistence and recovery logic against deterministic
# doubles, without compiling the real capture or model process implementations.
swiftc -swift-version 5 -target arm64-apple-macos15.0 -parse-as-library \
  -module-cache-path "$test_module_cache" \
  "$test_build/AudioWindowing.swift" \
  "$source_directory/Models.swift" "$source_directory/MeetingFiles.swift" "$source_directory/FillerReducer.swift" "$source_directory/MeetingStore.swift" \
  "$source_directory/RefinementPlanner.swift" \
  "$source_directory/Recovery.swift" "$source_directory/AppSettings.swift" \
  "$source_directory/StorageMigration.swift" "$source_directory/VocabularyCore.swift" \
  "$test_directory/test_lifecycle.swift" \
  -o "$test_build/lifecycle_tests"

for scenario in quit-during-start quit-during-stop failed-start-preserves-audio multiple-stops-during-start template-inheritance import-refinement automatic-refinement refinement-resume recording-priority refinement-failure-retry refinement-stop-resume refinement-stop-waiting-planning delete-meeting-and-audio delete-failure-preserves-meeting delete-recording-guards tagged-terminology storage-migration legacy-file-organization rename-when-idle organization-conflicts refinement-rerun-current-hints refinement-rerun-paused refinement-rerun-save-failure; do
  LOCALVERBATIM_ROOT="$test_build/$scenario" "$test_build/lifecycle_tests" "$scenario"
done
