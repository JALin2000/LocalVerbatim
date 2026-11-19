#!/bin/bash
# Explicit Apple upload/stapling step. Run only for a reviewed release artifact.
# Credentials are read from an existing Keychain profile, never plaintext args.
set -euo pipefail
package_source="$(cd "$(dirname "$0")/.." && pwd)"
if [ "$#" -ne 3 ]; then
  echo "Usage: $0 INPUT_APP_OR_DMG KEYCHAIN_PROFILE NEW_LOG_DIRECTORY" >&2; exit 2
fi
artifact="$1"
profile="$2"
logs="$3"
case "$artifact" in /*.app|/*.dmg) ;; *) echo 'Input must be an absolute .app or .dmg path' >&2; exit 2 ;; esac
case "$logs" in /*) ;; *) echo 'Log directory must be absolute and outside the source checkout' >&2; exit 2 ;; esac
test -n "$profile" || { echo 'An existing Keychain profile is required' >&2; exit 2; }
test -e "$artifact" && test ! -L "$artifact" || { echo 'Input must exist and must not be a symlink' >&2; exit 2; }
test ! -e "$logs" && test ! -L "$logs" || { echo 'Refusing to reuse an existing log directory' >&2; exit 2; }
/usr/bin/python3 -I -B - "$package_source" "$logs" "$artifact" <<'PY'
from pathlib import Path
import sys
source, logs, artifact = (Path(value).resolve() for value in sys.argv[1:])
if logs.is_relative_to(source) or logs.is_relative_to(artifact):
    raise SystemExit('Keep submission logs/archives outside the source checkout and app')
PY
# Both tools must be available before creating an archive or contacting Apple.
xcrun --find notarytool >/dev/null
xcrun --find stapler >/dev/null
if [[ "$artifact" == *.app ]]; then
  /usr/bin/python3 -I -B "$package_source/scripts/sign_app.py" "$artifact" --verify-only --require-developer-id
else
  hdiutil verify "$artifact"
  codesign --verify --strict "$artifact"
  /usr/bin/python3 -I -B - "$package_source/scripts" "$artifact" <<'PY'
import sys
sys.path.insert(0, sys.argv[1])
from sign_app import check_developer_signature
check_developer_signature(sys.argv[2], require_runtime=False)
PY
fi
mkdir -p "$logs"
if [[ "$artifact" == *.app ]]; then
  submission="$logs/app-for-notarization.zip"
  /usr/bin/ditto -c -k --sequesterRsrc --keepParent "$artifact" "$submission"
else
  submission="$artifact"
fi
# Preserve stdout/stderr and the submission ID even if Apple rejects or times out.
# A timeout is not acceptance; resume with notarytool wait/info using that ID.
submission_exit=0
xcrun notarytool submit "$submission" --keychain-profile "$profile" \
  --wait --timeout 30m --output-format json > "$logs/submission.json" 2> "$logs/submission-stderr.txt" || submission_exit=$?
if ! submission_id="$(/usr/bin/python3 -I -B - "$logs/submission.json" <<'PY'
import json, re, sys
result = json.load(open(sys.argv[1]))
identifier = result.get('id', '')
if not re.fullmatch(r'[0-9a-fA-F]{8}(?:-[0-9a-fA-F]{4}){3}-[0-9a-fA-F]{12}', identifier):
    raise SystemExit('No valid submission ID in notarization response')
print(identifier)
PY
)"; then
  echo "Submission did not return a valid ID. Inspect $logs; do not distribute." >&2
  exit 1
fi
xcrun notarytool log "$submission_id" --keychain-profile "$profile" "$logs/notarization-log.json"
/usr/bin/python3 -I -B - "$logs/submission.json" "$logs/notarization-log.json" <<'PY'
import json, sys
result, log = (json.load(open(path)) for path in sys.argv[1:])
if result.get('status') != 'Accepted' or log.get('status') != 'Accepted':
    raise SystemExit('Notarization was not Accepted; inspect the log. Do not distribute.')
issues = log.get('issues') or []
if issues:
    raise SystemExit('Notarization log contains issues; review them before release. No ticket was stapled.')
PY
test "$submission_exit" = 0 || { echo 'Submission command failed; inspect logs before continuing.' >&2; exit 1; }
xcrun stapler staple "$artifact"
xcrun stapler validate "$artifact"
if [[ "$artifact" == *.app ]]; then
  /usr/bin/python3 -I -B "$package_source/scripts/sign_app.py" "$artifact" --verify-only --require-developer-id
  spctl --assess --type execute --verbose=2 "$artifact"
else
  hdiutil verify "$artifact"
  codesign --verify --strict "$artifact"
  spctl --assess --type open --context context:primary-signature --verbose=2 "$artifact"
  shasum -a 256 "$artifact" > "$logs/SHA256.txt"
fi
printf 'Accepted, stapled, and Gatekeeper assessment passed: %s\n' "$artifact"
