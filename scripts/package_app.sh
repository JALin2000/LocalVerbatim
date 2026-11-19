#!/bin/bash
# Build a fresh, self-contained application. Does not install or modify the
# development app, user recordings, Applications, or signing identities.
set -euo pipefail
package_source="$(cd "$(dirname "$0")/.." && pwd)"
if [ "$#" -lt 2 ]; then
  echo "Usage: $0 STANDALONE_RUNTIME OUTPUT_APP [--include-8bit | --download-model]" >&2
  exit 2
fi
package_runtime="$(cd "$1" && pwd)"
package_output="$2"
package_include_8bit="${3:-}"
case "$package_include_8bit" in
  ""|--include-8bit|--download-model) ;;
  *) echo "Unknown option: $package_include_8bit" >&2; exit 2 ;;
esac
if [ -e "$package_output" ]; then
  echo "Refusing to overwrite existing output: $package_output" >&2
  exit 2
fi
case "$package_output" in
  /*.app) ;;
  *) echo "OUTPUT_APP must be an absolute .app path" >&2; exit 2 ;;
esac
if [ ! -x "$package_runtime/bin/python" ] || [ -f "$package_runtime/pyvenv.cfg" ]; then
  echo "Expected a standalone Python installation, not a virtual environment" >&2
  exit 2
fi
package_support="$package_output/Contents/Resources/Support"
package_cache="${LOCALVERBATIM_BUILD_CACHE:-${LOCALSCRIBE_BUILD_CACHE:-$package_source/.build-cache}}"
mkdir -p "$package_output/Contents/MacOS" "$package_support" "$package_cache"
xcrun swiftc -O -swift-version 5 -parse-as-library \
  -target arm64-apple-macos15.0 -module-cache-path "$package_cache" \
  "$package_source"/Sources/LocalVerbatim/*.swift -o "$package_output/Contents/MacOS/LocalVerbatim"
cp "$package_source/scripts/Info.plist" "$package_output/Contents/Info.plist"
cp "$package_source/scripts/AppIcon.icns" "$package_output/Contents/Resources/AppIcon.icns"

# macOS clonefile copies share immutable disk extents on APFS while remaining
# independent files. All source directories are explicitly selected; meeting
# recordings, test audio and development documents cannot enter the bundle.
/bin/cp -cR "$package_runtime" "$package_support/runtime"
mkdir -p "$package_support/engine" "$package_support/models"
cp "$package_source"/engine/worker.py "$package_source"/engine/manage_model.py "$package_source"/engine/model-manifest.json "$package_support/engine/"
/bin/cp -R "$package_source/Resources/" "$package_output/Contents/Resources/"
mkdir -p "$package_output/Contents/Resources/Legal"
cp "$package_source/LICENSE" "$package_source/NOTICE" "$package_source/THIRD_PARTY_NOTICES.md" "$package_output/Contents/Resources/Legal/"
/bin/cp -R "$package_source/LICENSES" "$package_output/Contents/Resources/Legal/"
cp "$package_source/requirements.lock.txt" "$package_support/requirements.lock.txt"
if [ "$package_include_8bit" != "--download-model" ]; then
  /bin/cp -cR "$package_source/models/Qwen3-ASR-1.7B-bf16" "$package_support/models/Qwen3-ASR-1.7B-bf16"
fi
if [ "$package_include_8bit" = "--include-8bit" ]; then
  /bin/cp -cR "$package_source/models/Qwen3-ASR-1.7B-8bit" "$package_support/models/Qwen3-ASR-1.7B-8bit"
fi
PYTHONDONTWRITEBYTECODE=1 "$package_support/runtime/bin/python" -I -B \
  "$package_source/scripts/verify_bundled_runtime.py" "$package_support/runtime"
# Ad-hoc signing changes only this newly staged app; it creates no identity.
codesign --force --deep --sign - "$package_output"
codesign --verify --deep --strict "$package_output"
echo "Packaged $package_output"
