# Third-party notices and release evidence

This directory preserves third-party texts without translating or relicensing them. The original LocalVerbatim code remains under the root Apache-2.0 license. The example attribution in that license's appendix is part of the standard license text; project attribution is in `NOTICE`.

## Shipped application runtime

[dependency-inventory.json](dependency-inventory.json) describes the **42 installed Python distributions** in the Apple Silicon Qwen3-ASR application runtime. [native-binary-inventory.json](native-binary-inventory.json) records its **37 regular Mach-O files**, architectures, pre-packaging hashes and dynamic library load commands. Symlink aliases are not counted as additional binaries. Code signing changes file hashes; package integrity is checked separately.

The full development lock contains 43 packages. The application deliberately excludes SciPy and its `libgfortran`, `libgcc_s` and LGPL `libquadmath` libraries. It also excludes pip, ensurepip, Tcl/Tk and development/test resources. The retained MLX Audio metadata still declares SciPy; this bundle supports the app's tested Qwen3-ASR mono 16 kHz NumPy-array path, not the complete MLX Audio SDK or every resampling/model API. Restoring excluded components requires renewed review.

The inventories are evidence for these exact artifacts, not a claim that every possible dependency has been inferred from binary symbols. Static dependencies were additionally checked against matching upstream sources and build recipes. `scripts/collect_license_inventory.py` recreates the installed-package and Mach-O inventories without importing runtime packages.

## Native components

| Shipped component | Basis and notices |
|---|---|
| CPython 3.13.15, Astral build 20260807 | [Build inventory](python-build-standalone-inventory.json), the matching full archive's `PYTHON.json`, [PSF/historical license](python/LICENSE.txt), [CPython incorporated-software notices](native-sources/cpython-3.13.15/Doc/license.rst) and [source header notices](inline-notices/cpython-3.13.15.txt). |
| CPython's bzip2 1.0.8, libffi 3.4.6, mpdecimal 4.0.0, Expat 2.8.2, OpenSSL 3.5.7, SQLite 3.53.1, XZ/liblzma 5.8.3, libuuid 1.0.3 | The linked modules, exact source hashes, permissive/public-domain terms and copied build notices are in the [build inventory](python-build-standalone-inventory.json). `readline` uses macOS libedit, not GNU readline. libedit, ncurses/panel, zlib and Apple frameworks are platform libraries rather than redistributed binaries. |
| MLX / MLX Metal 0.32.4 | MIT; includes pocketfft and other source-header attributions, nanobind 3.1.0, its pinned robin-map submodule, fmt 12.1.0, nlohmann JSON 3.11.3, pinned gguf-tools and Apple metal-cpp 26. [Source artifacts](native-source-inventory.json), [supplemental provenance](supplemental-provenance.json), [inline notices](inline-notices/mlx-0.32.4.txt). Apple Accelerate/Metal system frameworks are not copied into the app. |
| NumPy 2.5.4 | This arm64 macOS 14+ wheel links Apple's Accelerate and contains no OpenBLAS or GCC runtime dylibs. Preserve all supplied NumPy/random/pocketfft/LAPACK/other component notices; the generic wheel notice can mention libraries not present in this platform wheel. |
| PortAudio 19.7.0 in sounddevice 0.5.6 | MIT-style notice in [PortAudio license](native-sources/portaudio-19.7.0/LICENSE.txt); version from the exact sounddevice source archive's macOS build recipe. Windows ASIO binaries are not shipped. |
| miniaudio 1.73 | Python wrapper MIT, embedded miniaudio and decoder terms preserved in the wheel license and [inline notices](inline-notices/miniaudio-1.73.txt), including stb_vorbis. |
| SentencePiece 0.2.3 | Apache-2.0 plus bundled darts-clone BSD, libsais Apache-2.0 and rapidhash BSD-2-Clause notices from the exact source archive and [header notices](inline-notices/sentencepiece-0.2.3.txt). |
| PyYAML 6.0.3 / libyaml 0.2.5 | MIT; [libyaml notice](native-sources/libyaml-0.2.5/License). CFFI 2.1.1 dynamically uses macOS libffi in this wheel; the separately statically linked CPython copy has its own notice above. |
| hf-xet, Tokenizers, Pydantic Core, SafeTensors | Exact-version source archives and checksum-pinned Rust crate notices are preserved. [Rust dependency inventory](rust-dependency-inventory.json) is a **conservative Cargo.lock union**, including optional, platform, build and test dependencies; it does not assert all entries are linked into arm64 binaries. [Rust standard-library inventory](rust-standard-library-inventory.json) identifies compiler commits found in each binary and preserves the associated runtime copyright maps and licenses; [standard-library crate inventory](rust-standard-crate-inventory.json) supplements it. Compiler executables are not shipped. |

## MPL source availability

`tqdm` 4.70.1 is distributed with its readable Python source in the app at `Contents/Resources/Support/runtime/lib/python3.13/site-packages/tqdm/`, under its original MIT/MPL-2.0 terms. The original license remains alongside its distribution metadata.

The exact, unmodified sources of MPL-2.0 crates [colored 3.1.1](corresponding-source/colored-3.1.1/) and [option-ext 0.2.0](corresponding-source/option-ext-0.2.0/) are provided here, including their build manifests and license texts. They are conservatively supplied because they occur in hf-xet's locked dependency graph, whether or not a particular optimized path is linked. The [complete MPL-2.0 license](MPL-2.0.txt) is included. These source directories are copied into the app's `Contents/Resources/Legal/LICENSES/` directory. Recipients may use, modify and redistribute covered source under its original terms; the app's license does not restrict those rights.

## Provenance and scope

- `dependencies/` preserves notices from installed wheels, including notices embedded outside `.dist-info` where present. Historical SciPy and pip notice copies are retained for development provenance; their presence is not an assertion that those packages are shipped.
- [source-inventory.json](source-inventory.json) records exact-version PyPI source archive URLs/hashes and extracted notices. The MLX wheels do not provide an sdist; matching upstream tag provenance is recorded instead. Source-notice supplements can mention optional or development-only code.
- [inline-notice-inventory.json](inline-notice-inventory.json) identifies archives and copied native copyright/license comment blocks. Original block text is retained, with source-member labels added outside it.
- [native-source-inventory.json](native-source-inventory.json) and [supplemental-provenance.json](supplemental-provenance.json) record fetched native notices and hashes. Rust crate archives were checked against their exact Cargo.lock checksums; missing macOS-relevant crate notices were supplemented from recorded source commits or exact release tags. Explicit non-macOS lockfile entries are marked as not shipped.
- `upstream/` retains Qwen model and original Tokenizers/SentencePiece license snapshots. Exact-release Tokenizers/SentencePiece notices are also provided under `source-notices/`; the older snapshots alone are not used as binary provenance.
- GPL/LGPL texts appearing in notices for excluded SciPy libraries, alternate-license choices, source test material or compiler metadata do not mean those components are included in the application binary. The actual retained files and dynamic links are listed separately.

The app packaging script copies this directory and `THIRD_PARTY_NOTICES.md` into `Contents/Resources/Legal/`. Keep those texts and covered source files together when redistributing this build. Changed package versions, platforms, compiler runtimes or additional model APIs require a new inventory and review.
