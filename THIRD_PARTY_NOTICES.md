# Third-party software and models

The original app, documentation and icon use the root [Apache-2.0 license](LICENSE). That does not relicense any third-party material. This source tree does not contain executable dependencies, model weights, real meeting recordings or third-party application code.

## Principal components

| Component | Role | Upstream license / attribution |
|---|---|---|
| [Qwen3-ASR](https://github.com/QwenLM/Qwen3-ASR) / [1.7B weights](https://huggingface.co/Qwen/Qwen3-ASR-1.7B) | Local speech recognition | Apache-2.0; Alibaba Cloud; [preserved upstream license](LICENSES/upstream/Qwen3-ASR.LICENSE) |
| [MLX BF16 conversion](https://huggingface.co/mlx-community/Qwen3-ASR-1.7B-bf16) | Converted model used by this app | Model card declares Apache-2.0; MLX Community; pinned revision in the source tree's `engine/model-manifest.json` |
| [MLX](https://github.com/ml-explore/mlx) | Apple Silicon inference arrays/runtime | MIT; see the installed-package license copies under LICENSES/dependencies |
| [MLX Audio](https://github.com/Neywa-Labs/mlx-audio) | ASR model implementation | MIT; Prince Canuma and contributors; preserved package license |
| [CPython](https://www.python.org/) | Python interpreter in standalone builds | Python Software Foundation license and included historical notices; [license text](LICENSES/python/LICENSE.txt) |
| [Transformers](https://github.com/huggingface/transformers), [Hugging Face Hub](https://github.com/huggingface/huggingface_hub), [Tokenizers](https://github.com/huggingface/tokenizers), [SentencePiece](https://github.com/google/sentencepiece) | Model loading, download and tokenization | Primarily Apache-2.0; each project's notices apply; see inventory and preserved texts |
| NumPy, SciPy and other Python packages | Audio processing and runtime support | Various licenses, including component-specific notices; do not replace them with the app's Apache license |

The complete observed Python distribution list is in [dependency-inventory.json](LICENSES/dependency-inventory.json), with versions and relative paths to the preserved license texts. It covers the **44 distributions present in the tested v0.4.3 runtime**, including pip and its vendored notices. The runtime itself is not included here.

## Provenance and boundaries

Most license copies were preserved verbatim from the tested packages' distribution metadata. SentencePiece and Tokenizers did not include license files in the inspected wheel/package directories; copies from their upstream repositories are provided under [LICENSES/upstream](LICENSES/README.md), with Git blob identifiers recorded in [upstream-provenance.json](LICENSES/upstream-provenance.json). These upstream snapshots are not represented as a full audit of the exact wheel source releases.

The model download selects operational files by a pinned manifest. Its license and model provenance are supplied with the application under `Contents/Resources/Legal/`, rather than requiring another model-weight download. The editable icon uses only original geometric paths; no third-party artwork or logos are embedded in it. macOS framework APIs and system-rendered symbols are platform-provided resources, not third-party images redistributed as the original icon.

## Before distributing a binary

Re-check the exact runtime and weights being shipped. Preserve package copyright/license notices, inspect the licenses of embedded native libraries (including those inside Python and wheels), and satisfy any applicable source availability or notice requirements. The top-level package metadata alone is not a complete native-library license inventory. In particular, bundled notices can contain additional terms and exceptions; do not infer the whole bundle's license from a package's short label.

The packaging scripts include the collected texts. Full native dependency provenance and binary redistribution review remain a release gate, recorded in the source tree's `docs/RELEASE_CHECKLIST.md`. Keep these notices when redistributing or updating the runtime; do not claim that every dependency is Apache-2.0 or MIT.

## 中文说明

本项目原创部分使用 Apache-2.0；第三方模型、Python 和各依赖保留自己的版权与许可。本目录包含依赖许可副本和版本清单，不包含它们的可执行文件或模型权重。两个缺少随包许可文件的依赖已补充上游文本，并明确记录来源；正式发行安装包前仍须核对具体版本及内嵌原生库的完整许可，不把上游快照或元数据清单当成已完成的二进制合规审计。
