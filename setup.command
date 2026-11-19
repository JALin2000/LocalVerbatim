#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"
case "${1:-}" in
  --help|-h) echo 'Usage: bash setup.command [--download-model]'; exit 0 ;;
  ''|--download-model) ;;
  *) echo 'Usage: bash setup.command [--download-model]' >&2; exit 2 ;;
esac
if [ "$#" -gt 1 ]; then echo 'Too many arguments' >&2; exit 2; fi
if [ "$(uname -s)" != Darwin ] || [ "$(uname -m)" != arm64 ]; then
  echo 'Apple Silicon macOS is required. Use a native arm64 terminal, not Rosetta.' >&2; exit 2
fi
if [ "$(sw_vers -productVersion | cut -d. -f1)" -lt 15 ]; then
  echo 'macOS 15 or later is required.' >&2; exit 2
fi
command -v uv >/dev/null || { echo 'Install uv first; see docs/DEVELOPMENT.md.' >&2; exit 2; }
xcrun --find swiftc >/dev/null || { echo 'Install Xcode Command Line Tools first.' >&2; exit 2; }
echo 'LocalVerbatim: preparing the isolated Python 3.13 development runtime.'
if [ ! -x runtime/bin/python ]; then
  test ! -e runtime || { echo 'Existing runtime is incomplete; move it aside before setup.' >&2; exit 2; }
  uv venv --python 3.13.15 runtime
fi
runtime/bin/python -c 'import platform, sys; assert sys.version_info[:2] == (3, 13) and platform.machine() == "arm64", "Use an arm64 Python 3.13 environment"'
uv pip install --python runtime/bin/python -r requirements.lock.txt
if [ "${1:-}" = --download-model ]; then
  runtime/bin/python scripts/download_model.py
fi
bash scripts/build.sh
echo 'Ready. Open LocalVerbatim.app in this folder. The setup guide can download the model.'
echo 'For a standalone Applications build, follow docs/DEVELOPMENT.md.'
