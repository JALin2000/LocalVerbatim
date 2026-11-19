#!/bin/bash
# Prepare an independent CPython installation, never a venv pointing to conda.
set -euo pipefail
runtime_source="$(cd "$(dirname "$0")/.." && pwd)"
if [ "$#" -ne 1 ]; then
  echo "Usage: $0 NEW_PREPARATION_DIRECTORY" >&2
  exit 2
fi
runtime_stage="$1"
if [ -e "$runtime_stage/runtime" ]; then
  echo "Refusing to overwrite $runtime_stage/runtime" >&2
  exit 2
fi
mkdir -p "$runtime_stage"
runtime_stage="$(cd "$runtime_stage" && pwd)"
runtime_version=3.13.15
runtime_cache="${UV_CACHE_DIR:-$runtime_stage/uv-cache}"
uv python install "$runtime_version" --install-dir "$runtime_stage/python-managed" \
  --no-bin --cache-dir "$runtime_cache" --no-config
/bin/cp -cR "$runtime_stage/python-managed/cpython-$runtime_version-macos-aarch64-none" "$runtime_stage/runtime"
# Select wheels for the app's minimum macOS version, even on a newer build host.
MACOSX_DEPLOYMENT_TARGET=15.0 uv pip install --python "$runtime_stage/runtime/bin/python3.13" \
  --target "$runtime_stage/runtime/lib/python3.13/site-packages" \
  --requirements "$runtime_source/requirements.lock.txt" --no-deps \
  --python-platform aarch64-apple-darwin --only-binary :all: \
  --cache-dir "$runtime_cache" --link-mode clone --no-config
# uv's standalone interpreter launchers are already relative. Its --target
# console entrypoints need the same relocation treatment.
"$runtime_stage/runtime/bin/python" -I -B - "$runtime_stage/runtime" <<'PY'
from pathlib import Path
import sys
runtime = Path(sys.argv[1])
for path in (runtime / 'lib/python3.13/site-packages/bin').glob('*'):
    if not path.is_file() or path.is_symlink():
        continue
    text = path.read_text()
    if text.startswith('#!'):
        body = text.split('\n', 1)[1]
        launcher = '''#!/bin/sh
\'''exec' "$(dirname -- "$(realpath -- "$0")")/../../../../bin/python3.13" "$0" "$@"
' \'''
'''
        path.write_text(launcher + body)
PY
PYTHONDONTWRITEBYTECODE=1 "$runtime_stage/runtime/bin/python" -I -B \
  "$runtime_source/scripts/verify_bundled_runtime.py" "$runtime_stage/runtime"
echo "Prepared $runtime_stage/runtime"
