# Build, test and package

[简体中文](DEVELOPMENT.zh-CN.md) · [README](../README.md)

## Tools

- Apple Silicon, macOS 15+, and a native arm64 terminal. Rosetta/x86 Python is not supported.
- Xcode Command Line Tools with the macOS 15+ SDK (`xcode-select --install`). Swift is compiled in Swift 5 language mode; Package.swift declares tools version 5.10.
- [uv](https://docs.astral.sh/uv/getting-started/installation/) to obtain Python 3.13.15 and install dependencies. If you already use Homebrew, `brew install uv` is one supported option; Homebrew is not required for the app itself.
- A local APFS volume for packaging scripts that use macOS clonefile copies.
- Internet access for tool/dependency installation and the optional model download. Models/runtime are intentionally absent from the source archive.

Get the source from [JALin2000/LocalVerbatim](https://github.com/JALin2000/LocalVerbatim):

```sh
git clone https://github.com/JALin2000/LocalVerbatim.git
cd LocalVerbatim
```

Run the commands below from this directory, which contains `Package.swift` and `setup.command`. v0.5.0 has an explicitly unnotarized preview installer; see the [installation guide](INSTALL.md). See [Contributing](../CONTRIBUTING.md) before submitting changes.

## Development app

```sh
bash setup.command
open LocalVerbatim.app
```

Setup checks architecture and build tools, creates `runtime/` with arm64 Python 3.13.15, installs the pinned requirements, compiles Swift and ad-hoc signs the development app. It does not download a model unless `--download-model` is supplied. The first-run app guide can download/import the model instead.

To download the verified model explicitly from the terminal:

```sh
bash setup.command --download-model
```

The model download helper reuses `engine/manage_model.py` and its pinned size/hash manifest. It does not send recordings to a server. A development environment cannot be moved reliably after creation; recreate its virtual environment if you move the source folder.

After Swift edits, rebuild with:

```sh
bash scripts/build.sh
```

Keep this development `.app` in the source directory. It locates `runtime/` and `engine/` beside itself, and stores local development data there. For an independently movable app, use the packaging steps below. Rebuilding a trial app changes its ad-hoc signature and may require refreshing its macOS privacy permission.

## Tests

Run from an initialized source directory:

```sh
runtime/bin/python -B -m unittest discover -s tests -p 'test_*.py' -v
bash tests/run_swift_tests.sh
bash tests/run_lifecycle_tests.sh
bash tests/run_engine_tests.sh
bash tests/run_ux_tests.sh
bash tests/run_disfluency_tests.sh
```

These tests use generated fixtures, temporary data directories and process doubles. They do not request microphone access or load/download ASR weights. Python input tests use NumPy from the development runtime; engine protocol tests require `runtime/bin/python` to exist.

Manual microphone/system audio, global shortcut and first-run permission tests remain necessary before distributing an installer. Record synthetic/disposable audio for testing; do not add real meeting content to a repository.

## Standalone app and DMG

Use fresh output paths; packaging refuses to overwrite existing products. The standalone runtime must not be the development virtual environment.

```sh
release_work="$(mktemp -d /tmp/localverbatim-release.XXXXXX)"
bash scripts/prepare_runtime.sh "$release_work/runtime-build"
LOCALVERBATIM_BUILD_CACHE="$release_work/swift-cache" bash scripts/package_app.sh \
  "$release_work/runtime-build/runtime" "$release_work/LocalVerbatim.app" --download-model
bash scripts/package_dmg.sh "$release_work/LocalVerbatim.app" \
  "$release_work/LocalVerbatim-0.5.0-preview-mac-arm64.dmg" --preview
shasum -a 256 "$release_work/LocalVerbatim-0.5.0-preview-mac-arm64.dmg"
```

`--download-model` produces an app without weights, ready for the first-run download/import guide. The runtime, engine, original icon, root license and collected third-party notices are copied into the app. Legal materials are in `Contents/Resources/Legal/`; the DMG also includes English/Chinese installation notes.

Omitting that option bundles the local BF16 model from `models/Qwen3-ASR-1.7B-bf16`. Do not distribute that variant before verifying the exact model and bundled-native-library attribution requirements. The optional `--include-8bit` path needs the pinned 8-bit weights in `models/Qwen3-ASR-1.7B-8bit`. Public packages use `--download-model`. The setup guide and **Settings → Transcription** let the user choose, download or import either variant.

These scripts create **ad-hoc signed trial packages**, not notarized public releases. They neither install to Applications nor publish anywhere. Complete [the release checklist](RELEASE_CHECKLIST.md) before distributing binaries.

## Source archive

Run the source checker on a clean publication directory (no generated runtime, models, recordings or `.app`). Development folders with those artifacts intentionally fail the check.

```sh
python3 scripts/check_source_release.py .
```

Include only the approved source/documentation/license files when preparing an archive. Do not create an archive of a working directory containing personal data. The checker also checks local Markdown references and obvious credential/home-directory patterns; it is a guardrail, not a comprehensive security scan.

## Architecture and reproducibility

SwiftUI/AppKit own the desktop UI; ScreenCaptureKit and AVFoundation receive audio. A separate Python process runs MLX inference and communicates through JSON lines. Settings and user recordings live outside a standalone app bundle. One model processes bounded audio windows from both tracks serially.

The development `requirements.lock.txt` pins the full dependency versions. Standalone packages additionally use [`scripts/runtime-artifacts.json`](../scripts/runtime-artifacts.json), pinning official CPython by URL/SHA-256 and specific macOS arm64 wheels by URL/size/SHA-256. Preparation verifies the downloads and installs offline. The standalone app supports its Qwen3-ASR/16 kHz mono-array recognition path; it removes unused SciPy, test data and build tools. It is not the full MLX Audio SDK: upstream metadata retains its broader SciPy requirement, and the app verifier checks this one documented gap. Development still installs the complete dependency set.

The model manifest separately pins its revision, sizes and hashes. A successful build does not establish byte-for-byte reproducibility or clean-Mac first-install coverage. See [macOS release packaging](MAC_RELEASE.md) for preview builds and Developer ID signing/notarization.

Version 0.4.4 updates the app, executable, Swift target and source paths to LocalVerbatim, with 本地逐字稿 as its Chinese display name. Recognition behavior is unchanged. The historical bundle identifier `local.localscribe.meeting-recorder` and default data root `LocalScribe` are retained intentionally for existing installations. `LOCALVERBATIM_ROOT` is the current development/test override; the older `LOCALSCRIBE_ROOT` remains accepted as a fallback. Build caches likewise accept the older environment variable. A public Developer ID signing identity remains pending.
