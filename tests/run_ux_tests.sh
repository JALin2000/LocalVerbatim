#!/bin/bash
set -euo pipefail
project="$(cd "$(dirname "$0")/.." && pwd)"
scratch="$(mktemp -d "${TMPDIR:-/tmp}/localverbatim-ux-tests.XXXXXX")"
trap 'rm -rf "$scratch"' EXIT
swiftc -swift-version 5 -target arm64-apple-macos15.0 -parse-as-library \
 -module-cache-path "${LOCALVERBATIM_TEST_MODULE_CACHE:-$scratch/modules}" \
 "$project/Sources/LocalVerbatim/AudioCapture.swift" "$project/Sources/LocalVerbatim/Models.swift" "$project/Sources/LocalVerbatim/MeetingFiles.swift" "$project/Sources/LocalVerbatim/FillerReducer.swift" \
 "$project/Sources/LocalVerbatim/AppSettings.swift" "$project/Sources/LocalVerbatim/AsyncTimeout.swift" \
 "$project/Sources/LocalVerbatim/StorageMigration.swift" "$project/Sources/LocalVerbatim/VocabularyCore.swift" \
 "$project/tests/test_ux.swift" -o "$scratch/check"
LOCALVERBATIM_ROOT="$scratch/data" "$scratch/check"
