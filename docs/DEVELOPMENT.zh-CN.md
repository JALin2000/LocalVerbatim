# 构建、测试与打包

[English](DEVELOPMENT.md) · [README](../README.zh-CN.md)

## 工具要求

- Apple Silicon、macOS 15+、原生 arm64 终端，不支持 Rosetta/x86 Python。
- 带 macOS 15+ SDK 的 Xcode Command Line Tools，可用 `xcode-select --install` 安装。Swift 使用 Swift 5 语言模式，Package.swift 声明工具版本 5.10。
- 安装 [uv](https://docs.astral.sh/uv/getting-started/installation/)，用来获取 Python 3.13.15 并安装依赖。已有 Homebrew 的用户可运行 `brew install uv`，使用应用本身不需要 Homebrew。
- 在本地 APFS 卷运行打包脚本，其中使用了 macOS clonefile 文件复制。
- 安装工具、依赖及可选下载模型时需要联网。源码包有意不包含模型和运行时。

从 [JALin2000/LocalVerbatim](https://github.com/JALin2000/LocalVerbatim) 获取源码：

```sh
git clone https://github.com/JALin2000/LocalVerbatim.git
cd LocalVerbatim
```

以下命令均在此目录执行，其中包含 `Package.swift` 和 `setup.command`。v0.5.0 提供明确标注未经公证的预览安装包，见[安装说明](INSTALL.zh-CN.md)。提交修改前请阅读[参与贡献](../CONTRIBUTING.md)。

## 开发版应用

```sh
bash setup.command
open LocalVerbatim.app
```

初始化脚本检查架构和构建工具，在 `runtime/` 建立 arm64 Python 3.13.15 环境，安装固定版本依赖，编译并临时签名。默认不下载模型；可在应用首次使用向导中下载或导入。

也可以明确要求在终端下载并校验模型：

```sh
bash setup.command --download-model
```

下载脚本复用 `engine/manage_model.py` 的版本、大小和哈希校验，不向服务器发送录音。虚拟环境移动后不保证可用；如果移动源码目录，应重新创建开发环境。

修改 Swift 后重新构建：

```sh
bash scripts/build.sh
```

此开发版 `.app` 需要与 `runtime/`、`engine/` 保持同目录，开发数据也保存在源码目录。需要可单独移动的应用时，使用下文的独立打包流程。重新编译会改变临时签名，可能需要刷新 macOS 隐私权限。

## 测试

在已完成初始化的源码目录运行：

```sh
runtime/bin/python -B -m unittest discover -s tests -p 'test_*.py' -v
bash tests/run_swift_tests.sh
bash tests/run_lifecycle_tests.sh
bash tests/run_engine_tests.sh
bash tests/run_ux_tests.sh
bash tests/run_disfluency_tests.sh
```

测试使用生成的样例、临时数据目录和替代进程，不请求麦克风权限，不加载或下载识别模型。Python 输入测试依赖环境中的 NumPy，进程协议测试需要 `runtime/bin/python`。

公开分发安装包前仍需人工检查麦克风、系统音频、全局快捷键和首次授权。测试使用合成或明确可丢弃的音频，不把真实会议提交到仓库。

## 独立应用与 DMG

使用新的输出路径；打包脚本拒绝覆盖已有产物。独立运行时不能使用开发版虚拟环境代替。

```sh
release_work="$(mktemp -d /tmp/localverbatim-release.XXXXXX)"
bash scripts/prepare_runtime.sh "$release_work/runtime-build"
LOCALVERBATIM_BUILD_CACHE="$release_work/swift-cache" bash scripts/package_app.sh \
  "$release_work/runtime-build/runtime" "$release_work/LocalVerbatim.app" --download-model
bash scripts/package_dmg.sh "$release_work/LocalVerbatim.app" \
  "$release_work/LocalVerbatim-0.5.0-preview-mac-arm64.dmg" --preview
shasum -a 256 "$release_work/LocalVerbatim-0.5.0-preview-mac-arm64.dmg"
```

`--download-model` 生成不带权重、首次使用时下载或导入模型的应用。运行时、识别引擎、原创图标、项目许可证和已整理的第三方许可会复制进应用；许可文件位于 `Contents/Resources/Legal/`，DMG 也包含中英文安装说明。

省略该选项会从 `models/Qwen3-ASR-1.7B-bf16` 打包模型。分发此变体前，需要核对具体权重及内嵌原生库的许可。可选的 `--include-8bit` 路径还需要将固定版本的 8 位权重放入 `models/Qwen3-ASR-1.7B-8bit`。公开安装包使用 `--download-model`，用户可在首次向导或**设置 → 转写**选择、下载或导入任一版本。

这些脚本生成**临时签名的试用包**，不等于已公证的公开发行版；不会自动安装到 Applications，也不会上传。公开发安装包前完成[发布清单](RELEASE_CHECKLIST.md)。

## 源码包检查

在干净的发布目录运行检查，不包含生成的运行时、模型、录音或 `.app`。包含这些产物的开发目录会被有意拒绝。

```sh
python3 scripts/check_source_release.py .
```

源码压缩包只包含明确批准的代码、文档和许可文件，不应直接压缩带个人数据的工作目录。检查器同时检查本地 Markdown 引用、明显凭证格式和个人主目录路径，但不代替完整安全审计。

## 架构与可复现性

SwiftUI/AppKit 负责桌面界面，ScreenCaptureKit 和 AVFoundation 采集音频。独立 Python 进程通过 MLX 推理，使用 JSON 行协议通信。独立安装版将设置和会议保存在应用包之外；一份模型串行处理两条音轨的有限长度片段。

开发环境的 `requirements.lock.txt` 固定完整依赖版本。独立安装包另外使用 [`scripts/runtime-artifacts.json`](../scripts/runtime-artifacts.json)，固定 CPython 的官方来源与 SHA-256，以及具体 macOS arm64 wheel 的官方来源、大小和 SHA-256；准备脚本校验后离线安装。独立包只提供本应用的 Qwen3-ASR、16 kHz 单声道数组识别流程，会移除未使用的 SciPy、测试数据和打包工具。它不是完整 MLX Audio SDK：上游元数据保留了 SciPy 依赖声明，应用验证器明确核对这一个已知差异；开发环境仍安装完整依赖。

模型清单另行固定模型版本、文件大小和哈希。构建通过不等于产物逐字节可复现，也不等于已完成全新 Mac 首装测试。预览版与 Developer ID 签名、公证的具体步骤见 [macOS 发行打包](MAC_RELEASE.md)。

v0.4.4 将应用、可执行文件、Swift target 和源码路径统一为 LocalVerbatim，中文显示名为本地逐字稿，识别行为不变。为了兼容现有安装，历史应用标识 `local.localscribe.meeting-recorder` 和默认数据根目录 `LocalScribe` 有意保留。开发／测试路径覆盖使用 `LOCALVERBATIM_ROOT`，旧的 `LOCALSCRIBE_ROOT` 仍作为备用兼容入口；构建缓存也兼容旧环境变量。正式 Developer ID 签名身份仍待配置。
