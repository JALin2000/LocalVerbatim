# Third-party software and models

LocalVerbatim's original code, documentation and icon use the root [Apache-2.0 license](LICENSE). Third-party components retain their own copyrights and licenses. The application includes readable notices and required covered source under `Contents/Resources/Legal/`.

The Apple Silicon application runtime contains **CPython 3.13.15 and 42 Python distributions**, recorded in [the installed-package inventory](LICENSES/dependency-inventory.json). [The native inventory](LICENSES/native-binary-inventory.json) records the 37 regular Mach-O files and their dynamic library dependencies. [The license guide](LICENSES/README.md) explains the static native components, source provenance, copyright notices and MPL source availability.

This is an application-specific Qwen3-ASR runtime. SciPy and its bundled GCC/quadmath libraries, pip, and Tcl/Tk are excluded. The development requirements retain the complete 43-package lock; retained MLX Audio metadata still declares SciPy. The shipped app uses its tested mono 16 kHz NumPy-array Qwen3-ASR path and does not provide every MLX Audio model or resampling API. Notice copies for excluded development components are retained as provenance and do not indicate their binaries are shipped.

| Principal component | Role | License / attribution |
|---|---|---|
| [Qwen3-ASR](https://github.com/QwenLM/Qwen3-ASR) / [1.7B model](https://huggingface.co/Qwen/Qwen3-ASR-1.7B) | Speech recognition | Apache-2.0; Alibaba Cloud; [preserved license](LICENSES/upstream/Qwen3-ASR.LICENSE). Model weights are downloaded separately using the pinned manifest. |
| [MLX BF16 conversion](https://huggingface.co/mlx-community/Qwen3-ASR-1.7B-bf16) | Model conversion used by the app | Model card declares Apache-2.0; MLX Community; revision in `engine/model-manifest.json`. |
| [MLX 8-bit conversion](https://huggingface.co/mlx-community/Qwen3-ASR-1.7B-8bit) | Optional on-demand model weights | Model card declares Apache-2.0. MLX Community revision in `engine/model-manifest-8bit.json`. |
| [MLX](https://github.com/ml-explore/mlx), MLX Metal and [MLX Audio](https://github.com/Neywa-Labs/mlx-audio) | Apple Silicon inference and ASR implementation | MIT; Apple, Prince Canuma and contributors; additional embedded-component notices are preserved. |
| [CPython](https://www.python.org/) | Python interpreter | PSF and historical terms plus separately licensed incorporated components; [details](LICENSES/README.md). |
| Transformers, Hugging Face Hub, Tokenizers, SafeTensors and hf-xet | Model loading, download and tokenization | Primarily Apache-2.0, with separately licensed Rust and other dependencies. |
| SentencePiece, NumPy, PortAudio, miniaudio and other packages | Tokenization, arrays and audio support | Apache, BSD, MIT and other component-specific terms; see the inventories and original texts. |
| tqdm; colored and option-ext Rust crates | Progress and supporting utilities | MIT/MPL-2.0 or MPL-2.0 as specified by each project. Readable covered sources and the full MPL text are supplied; [source locations](LICENSES/README.md#mpl-source-availability). |

The icon uses original geometric paths. No third-party artwork or application code was copied into the icon. macOS system frameworks and system-rendered symbols are platform-provided resources.

## 中文说明

LocalVerbatim 原创部分使用 Apache-2.0；模型、Python 和其他依赖保留各自的许可。安装包在 `Contents/Resources/Legal/` 内附带许可、版权声明，以及 MPL 所涉及组件的可读源码。本次应用运行时包含 Python 3.13.15 和 42 个 Python 依赖，面向已验证的 Qwen3-ASR 调用路径；不包含 SciPy 及其 GCC/quadmath 动态库，也不包含 pip 和 Tcl/Tk。完整开发环境仍使用 43 项依赖清单。保留的历史或可选组件许可文本不表示相应二进制已包含在安装包中。模型权重根据固定版本清单另外下载。
