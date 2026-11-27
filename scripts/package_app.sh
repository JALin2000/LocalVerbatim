#!/bin/bash
# Build a fresh, self-contained app. Local ad-hoc signing is the default;
# public signing requires an existing Developer ID Application identity.
set -euo pipefail
package_source="$(cd "$(dirname "$0")/.." && pwd)"
if [ "$#" -lt 2 ]; then
  echo "Usage: $0 STANDALONE_RUNTIME OUTPUT_APP [--include-8bit | --download-model] [--identity IDENTITY]" >&2
  exit 2
fi
package_runtime="$(cd "$1" && pwd)"
package_requested_output="$2"
shift 2
package_variant=""
package_identity=""
while [ "$#" -gt 0 ]; do
  case "$1" in
    --include-8bit|--download-model)
      test -z "$package_variant" || { echo 'Choose only one model variant' >&2; exit 2; }
      package_variant="$1"; shift ;;
    --identity)
      test "$#" -ge 2 && test -n "$2" && test -z "$package_identity" || { echo 'Provide exactly one signing identity' >&2; exit 2; }
      package_identity="$2"; shift 2 ;;
    *) echo "Unknown option: $1" >&2; exit 2 ;;
  esac
done
if [ -e "$package_requested_output" ] || [ -L "$package_requested_output" ]; then
  echo "Refusing to overwrite existing output: $package_requested_output" >&2; exit 2
fi
case "$package_requested_output" in
  /*.app) ;;
  *) echo 'OUTPUT_APP must be an absolute .app path' >&2; exit 2 ;;
esac
if [ ! -x "$package_runtime/bin/python" ] || [ -f "$package_runtime/pyvenv.cfg" ]; then
  echo 'Expected a standalone Python installation, not a virtual environment' >&2; exit 2
fi
# Reject an unavailable or wrong identity before compiling/copying a large app.
if [ -n "$package_identity" ]; then
  /usr/bin/python3 -I -B - "$package_source/scripts" "$package_identity" <<'PY'
import sys
sys.path.insert(0, sys.argv[1])
from sign_app import identity_from_keychain
identity_from_keychain(sys.argv[2])
PY
fi
mkdir -p "$(dirname "$package_requested_output")"
package_stage="$(mktemp -d "$(dirname "$package_requested_output")/.localverbatim-app.XXXXXX")"
trap 'rm -rf "$package_stage"' EXIT
package_output="$package_stage/LocalVerbatim.app"
package_support="$package_output/Contents/Resources/Support"
package_cache="${LOCALVERBATIM_BUILD_CACHE:-${LOCALSCRIBE_BUILD_CACHE:-$package_source/.build-cache}}"
mkdir -p "$package_output/Contents/MacOS" "$package_support" "$package_cache"
xcrun swiftc -O -swift-version 5 -parse-as-library \
  -target arm64-apple-macos15.0 -module-cache-path "$package_cache" \
  "$package_source"/Sources/LocalVerbatim/*.swift -o "$package_output/Contents/MacOS/LocalVerbatim"
cp "$package_source/scripts/Info.plist" "$package_output/Contents/Info.plist"
cp "$package_source/scripts/AppIcon.icns" "$package_output/Contents/Resources/AppIcon.icns"

# Only these release inputs enter the app. Never copy the checkout, home,
# installed app, user settings, recordings, diagnostics or development docs.
/bin/cp -cR "$package_runtime" "$package_support/runtime"
mkdir -p "$package_support/engine" "$package_support/models"
cp "$package_source"/engine/worker.py "$package_source"/engine/manage_model.py "$package_source"/engine/model-manifest.json "$package_source"/engine/model-manifest-8bit.json "$package_support/engine/"
# Keep resource additions explicit and reviewable.
/bin/cp -R "$package_source/Resources/en.lproj" "$package_source/Resources/zh-Hans.lproj" "$package_output/Contents/Resources/"
mkdir -p "$package_output/Contents/Resources/Legal"
cp "$package_source/LICENSE" "$package_source/NOTICE" "$package_source/THIRD_PARTY_NOTICES.md" "$package_output/Contents/Resources/Legal/"
/bin/cp -R "$package_source/LICENSES" "$package_output/Contents/Resources/Legal/"
cp "$package_source/requirements.lock.txt" "$package_support/requirements.lock.txt"
if [ -f "$package_source/scripts/runtime-artifacts.json" ]; then
  cp "$package_source/scripts/runtime-artifacts.json" "$package_support/runtime-artifacts.json"
fi
if [ "$package_variant" != '--download-model' ]; then
  /bin/cp -cR "$package_source/models/Qwen3-ASR-1.7B-bf16" "$package_support/models/Qwen3-ASR-1.7B-bf16"
fi
if [ "$package_variant" = '--include-8bit' ]; then
  /bin/cp -cR "$package_source/models/Qwen3-ASR-1.7B-8bit" "$package_support/models/Qwen3-ASR-1.7B-8bit"
fi
# Validate links/native layout before executing the copied runtime.
/usr/bin/python3 -I -B "$package_source/scripts/sign_app.py" "$package_output" --adhoc --dry-run >/dev/null
PYTHONDONTWRITEBYTECODE=1 "$package_support/runtime/bin/python" -I -B \
  "$package_source/scripts/verify_bundled_runtime.py" "$package_support/runtime"
# Finish every content mutation before the first signature.
/usr/bin/xattr -cr "$package_output"
if [ -n "$package_identity" ]; then
  /usr/bin/python3 -I -B "$package_source/scripts/sign_app.py" "$package_output" --identity "$package_identity"
else
  /usr/bin/python3 -I -B "$package_source/scripts/sign_app.py" "$package_output" --adhoc
fi
# Exercise native imports and a small Metal operation after final signing.
PYTHONDONTWRITEBYTECODE=1 "$package_support/runtime/bin/python" -I -B \
  "$package_source/scripts/verify_bundled_runtime.py" "$package_support/runtime"
package_verify_options=(--verify-only)
if [ -n "$package_identity" ]; then package_verify_options+=(--require-developer-id); fi
/usr/bin/python3 -I -B "$package_source/scripts/sign_app.py" "$package_output" "${package_verify_options[@]}"
mv "$package_output" "$package_requested_output"
echo "Packaged $package_requested_output"
if [ -n "$package_identity" ]; then
  echo 'Developer ID signed; notarization and real-device release checks remain required.'
else
  echo 'Ad-hoc signed for local testing only; not a notarized public release.'
fi
