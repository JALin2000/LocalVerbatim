<div align="center">

<img src="Resources/Brand/AppIcon-preview.png" width="96" alt="LocalVerbatim 图标">

# 本地逐字稿 · LocalVerbatim

**面向 Apple Silicon Mac 的私密、离线会议录音与中英文转写应用。**

`Apple Silicon` · `macOS 15+` · `Qwen3-ASR-1.7B (MLX)` · `Apache-2.0`

**[下载 v0.5.0 预览版 DMG](https://github.com/JALin2000/LocalVerbatim/releases/download/v0.5.0-preview.1/LocalVerbatim-0.5.0-preview-mac-arm64.dmg)**（约 117 MB）· [发行说明与校验和](https://github.com/JALin2000/LocalVerbatim/releases/tag/v0.5.0-preview.1) · [English](README.md)

</div>

---

LocalVerbatim 将你的麦克风与电脑播放的声音分别录制为本地音轨，通过 MLX 在本机完成语音识别，并将原始录音、逐字稿和会议笔记统一保存在离线工作区中。

## 核心特性

- **双路采集与录音导入** — 无需会议机器人，即可把麦克风（“我”）和系统音频（“与会者”）分别保存为独立 WAV；也支持直接导入 `MP3`、`M4A`、`WAV` 音频文件转写与回放。
- **完全本地 AI 识别** — 基于 Apple Silicon MLX 运行 [Qwen3-ASR-1.7B](https://huggingface.co/Qwen/Qwen3-ASR-1.7B)，支持英语、普通话及中英混合对话。提供 [BF16](https://huggingface.co/mlx-community/Qwen3-ASR-1.7B-bf16)（高精度，4.08 GB）与 [8 位量化](https://huggingface.co/mlx-community/Qwen3-ASR-1.7B-8bit)（低内存，2.47 GB）两个版本，版本与哈希固定在 [model-manifest.json](engine/model-manifest.json) 与 [model-manifest-8bit.json](engine/model-manifest-8bit.json) 中。
- **实时初稿 + 二次识别** — 录音期间分段更新逐字稿，结束后可自动或手动结合完整录音与术语做二次识别；原始逐字稿永久保留，支持随时停止/继续、更新术语重跑及切换对比历次版本。
- **术语提示与阅读清理** — 支持保存常用术语模板、自动沿用上一场录音的术语与背景；一键无损减少语气词（二次识别结果还会合并明显的中文口头重复），底层模型原文与时间戳始终不变。
- **完整离线工作区** — 同屏记录笔记、点击时间戳同步回放、`TXT` / `Markdown` / `SRT` 导出、移入废纸篓的可恢复删除、中英文界面、浅色/深色外观，以及快捷键启动录音时可选隐藏 Dock 图标。

## 快速开始

1. **安装应用** — 下载 [v0.5.0 预览版 DMG](https://github.com/JALin2000/LocalVerbatim/releases/download/v0.5.0-preview.1/LocalVerbatim-0.5.0-preview-mac-arm64.dmg)（已内置 Python 与 MLX 运行时，无需安装 Homebrew 或 Xcode），将 **LocalVerbatim** 拖入 **Applications**。

   > [!NOTE]
   > v0.5.0 预览版使用临时签名，尚未经过 Apple 公证。首次打开时可能需要前往 **系统设置 → 隐私与安全性 → 仍要打开** 手动允许（受企业管理的 Mac 可能限制运行未公证应用）。详见[安装说明](docs/INSTALL.zh-CN.md)。

2. **下载模型并授权** — 启动应用后选择界面语言，下载或导入模型（8 GB 及以下内存推荐 `8 位量化版`，8 GB 以上推荐 `BF16`），并授予**麦克风**与**屏幕与系统音频录制**权限。
3. **自检并开始** — 在 **设置 → 录音 → 开始 10 秒收音测试** 中确认两路均有声音，即可通过主窗口、菜单栏或全局快捷键开始录音。

## 全局快捷键

| 操作 | 默认快捷键 |
|---|---|
| 开始录音 | `⌃⌥R`（`Control + Option + R`） |
| 停止录音 | `⌃⌥S`（`Control + Option + S`） |
| 显示主窗口 | `⌃⌥L`（`Control + Option + L`） |

所有快捷键均可在 **设置 → 快捷键** 中自定义，也可开启**快捷键录音时隐藏 Dock 图标**（菜单栏入口始终保留）。

## 系统要求

| 项目 | 说明 |
|---|---|
| **机型与系统** | Apple Silicon Mac，macOS 15 或更新版本 |
| **内存** | 建议 16 GB（`8 位量化`：2.47 GB；`BF16`：4.08 GB；识别进程达到本机 RAM 90% 时自动停止并保留录音） |
| **磁盘空间** | 为应用和模型预留至少 6 GB；双轨 16 kHz 单声道 PCM16 录音约 230 MB/小时 |
| **网络** | 仅下载模型时需要联网，模型就绪后可完全离线运行 |

## 文件组织

每场会议都保存在独立目录 `日期 · 会议名 [ID]/` 中：

```text
YYYY-MM-DD HH-MM · 会议名称 [ID]/
├── microphone.wav          # 完整麦克风音轨
├── system.wav              # 完整电脑声音音轨
├── Transcripts/            # 自动导出的 TXT、Markdown 与 SRT
└── .localverbatim/         # 元数据、笔记、分段音频与二次识别历史
```

从旧名 **LocalScribe** 升级时会自动复用原有会议库、模型、设置和术语模板，无需手动迁移文件。

## 使用提示

- **区分音源而非声纹**：`我` 与 `与会者` 分别对应麦克风和系统音频两路音源，暂不按声纹区分多位远端发言人。
- **建议佩戴耳机**：目前尚未内置声学回声消除，使用耳机可避免外放声音被麦克风二次收录。
- **校对关键信息**：遇到严重循环重复时会自动从原音频重试，但专有名词、数字与中英切换仍建议对照回放确认。
- **纯粹本地工具**：当前版本有意保持简洁离线，不包含云端同步、自动摘要、日历集成或自动更新。

## 源码构建与文档

```sh
git clone https://github.com/JALin2000/LocalVerbatim.git && cd LocalVerbatim
bash setup.command
open LocalVerbatim.app
```

| 文档 | 链接 |
|---|---|
| 安装、权限、升级与卸载 | [docs/INSTALL.zh-CN.md](docs/INSTALL.zh-CN.md) · [English](docs/INSTALL.md) |
| 构建、测试与打包 | [docs/DEVELOPMENT.zh-CN.md](docs/DEVELOPMENT.zh-CN.md) · [English](docs/DEVELOPMENT.md) |
| 本地数据与联网说明 | [docs/PRIVACY.md](docs/PRIVACY.md) |
| 版本更新记录 | [CHANGELOG.md](CHANGELOG.md) |

## 许可证与参与贡献

本项目原创代码、文档与图标采用 [Apache-2.0](LICENSE) 许可（署名见 [NOTICE](NOTICE)），第三方依赖及 Qwen3-ASR 权重保留各自许可（见 [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md)）。欢迎参与贡献与反馈，请先阅读 [CONTRIBUTING.md](CONTRIBUTING.md) 与 [SECURITY.md](SECURITY.md)（切勿在公开 issue 中上传真实会议录音或逐字稿）。
