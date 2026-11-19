#!/bin/bash
# Prepare a fresh standalone runtime using only hash-locked official artifacts.
set -euo pipefail
# Inherit this into installer/interpreter queries as well as direct Python
# invocations. -B below additionally protects isolated (-I) invocations.
export PYTHONDONTWRITEBYTECODE=1
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
runtime_downloads="${RUNTIME_DOWNLOADS_DIR:-$runtime_stage/downloads}"
runtime_cache="${UV_CACHE_DIR:-$runtime_stage/uv-cache}"
runtime_bootstrap="${PYTHON_BOOTSTRAP:-python3}"
"$runtime_bootstrap" -I -B "$runtime_source/scripts/runtime_assets.py" validate "$runtime_stage" \
  --downloads "$runtime_downloads" --cache "$runtime_cache"
mkdir -p "$runtime_stage"
runtime_stage="$(cd "$runtime_stage" && pwd)"
"$runtime_bootstrap" -I -B "$runtime_source/scripts/runtime_assets.py" fetch "$runtime_stage" --downloads "$runtime_downloads"
"$runtime_bootstrap" -I -B "$runtime_source/scripts/runtime_assets.py" extract "$runtime_stage" --downloads "$runtime_downloads"
# Offline, hash-checked installation. The artifact lock selects macOS 15 arm64
# wheels explicitly and --no-deps prevents any additional package resolution.
MACOSX_DEPLOYMENT_TARGET=15.0 uv pip install --python "$runtime_stage/runtime/bin/python3.13" \
  --target "$runtime_stage/runtime/lib/python3.13/site-packages" \
  --requirements "$runtime_stage/requirements.hashed.txt" --require-hashes --no-deps \
  --no-index --find-links "$runtime_downloads" --only-binary :all: \
  --python-platform aarch64-apple-darwin --cache-dir "$runtime_cache" \
  --link-mode copy --no-config
# Confirm the unmodified upstream dependency closure before the documented
# application-only pruning (the development requirements remain unchanged).
uv pip check --python "$runtime_stage/runtime/bin/python3.13" --cache-dir "$runtime_cache" --no-config
"$runtime_stage/runtime/bin/python3.13" -I -B "$runtime_source/scripts/runtime_assets.py" finalize "$runtime_stage" --downloads "$runtime_downloads"
PYTHONDONTWRITEBYTECODE=1 "$runtime_stage/runtime/bin/python3.13" -I -B \
  "$runtime_source/scripts/verify_bundled_runtime.py" "$runtime_stage/runtime"
# Finish after all interpreter queries/checks, which can otherwise leave
# bytecode containing preparation-machine paths in a redistributable bundle.
"$runtime_bootstrap" -I -B "$runtime_source/scripts/runtime_assets.py" clean-bytecode "$runtime_stage"
echo "Prepared $runtime_stage/runtime"
