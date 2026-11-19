# LocalVerbatim

[简体中文](README.zh-CN.md)

Local meeting recording and English/Mandarin transcription for Apple Silicon Macs. Chinese name: **本地逐字稿**.

<img src="Resources/Brand/AppIcon-preview.png" width="96" alt="LocalVerbatim icon">

Record your microphone and the audio playing on your computer as separate tracks. Transcribe both on your Mac, keep the original recording, and review the transcript alongside your notes.

**[Download the Mac preview DMG](https://github.com/JALin2000/LocalVerbatim/releases/download/v0.4.8-preview.1/LocalVerbatim-0.4.8-preview-mac-arm64.dmg)** · Apple Silicon · macOS 15+ · approximately 117 MB. [Release notes and checksums](https://github.com/JALin2000/LocalVerbatim/releases/tag/v0.4.8-preview.1).

**Status:** v0.4.8 preview of **LocalVerbatim / 本地逐字稿**. This installer is **ad-hoc signed and not notarized by Apple**. First launch may require **System Settings → Privacy & Security → Open Anyway** after an attempted opening; managed Macs may prohibit it. See [installation instructions](docs/INSTALL.md). Clean-Mac first-install and wider hardware/OS testing remain pending.

Upgrading from LocalScribe preserves the existing library, model, settings and templates. The historical data directory and bundle identifier intentionally remain stable; see [upgrade details](docs/INSTALL.md#upgrade-backup-and-uninstall).

## Features

- Microphone and system audio capture, with separate WAV files and source labels.
- Local Qwen3-ASR-1.7B BF16 inference through MLX; English, Mandarin and mixed-language meetings.
- Incremental transcription during recording, with an optional automatic second pass after stopping.
- Original transcript retained; stop/resume a second pass, or run it again with updated terminology. Previous passes remain selectable and exportable.
- Reusable terminology templates; new meetings inherit the last recorded meeting's terms and context.
- Instantly switch between original wording and conservative filler reduction. Second-pass text also merges obvious Chinese speech repetitions; saved model output is retained.
- Notes, playback from timestamps, TXT/Markdown/SRT export, and recoverable meeting deletion.
- Chinese/English UI, light/dark appearance, global shortcuts, configurable storage, and a two-source audio test.
- Optional Dock hiding for shortcut-started recording; the menu-bar entry stays available.

## Requirements

| Item | Current support |
|---|---|
| Computer | Apple Silicon Mac; Intel and Windows are not supported |
| OS | macOS 15 or later; minimum-version coverage still needs broader testing |
| Memory | 16 GB recommended; 8 GB configurations have not been validated |
| Model download | Approximately 4.08 GB, once; an existing matching model can be imported |
| Disk | Allow at least 6 GB for the app/model plus recordings and download workspace |
| Network | Needed for model download; recording and transcription operate locally afterward |
| Permissions | Microphone and Screen & System Audio Recording |

The app saves 16 kHz mono PCM16 audio: about 230 MB/hour for the two full tracks combined, **plus** transcription chunks and exports. Storage grows with meeting duration.

Meetings are stored in `date · meeting title [ID]/`: the two full WAV tracks are at the top level, readable exports are in `Transcripts/`, and intermediate chunks/results are in hidden `.localverbatim/`. Back up the **whole folder**, including hidden files. Legacy folders are organized automatically on upgrade; see [Installation](docs/INSTALL.md).

## Get started

Download the [Mac preview](https://github.com/JALin2000/LocalVerbatim/releases/download/v0.4.8-preview.1/LocalVerbatim-0.4.8-preview-mac-arm64.dmg) and follow the [installation guide](docs/INSTALL.md). The installer includes Python and inference dependencies; the model is downloaded or imported on first use. To build from source, follow the [developer guide](docs/DEVELOPMENT.md).

Installing the packaged app does not require Python, Homebrew or Xcode. After model setup, run **Settings → Recording → Run 10-second audio test** and confirm that both sources receive audio before an important meeting.

| Guide | English | 简体中文 |
|---|---|---|
| Install, permissions, troubleshooting, upgrade and uninstall | [Installation](docs/INSTALL.md) | [安装说明](docs/INSTALL.zh-CN.md) |
| Build, test and package | [Development](docs/DEVELOPMENT.md) | [开发说明](docs/DEVELOPMENT.zh-CN.md) |
| Local data and network access | [Privacy / 隐私](docs/PRIVACY.md) | [同一文档](docs/PRIVACY.md) |

Default global shortcuts: **Control + Option + R** starts recording, **Control + Option + S** stops, and **Control + Option + L** shows the main window. All can be changed in Settings.

## Model and limitations

The model is [Qwen3-ASR-1.7B](https://huggingface.co/Qwen/Qwen3-ASR-1.7B), using [MLX BF16 weights](https://huggingface.co/mlx-community/Qwen3-ASR-1.7B-bf16). The revision and file hashes are pinned in [the model manifest](engine/model-manifest.json). One model processes both sources serially; long recordings are read in bounded windows.

Short local tests on an M4 with 16 GB memory measured roughly **5.2–5.4 GB of ASR-process physical footprint**. This is not a whole-system measurement or a cross-device guarantee. An 8.5 GB guard stops transcription while preserving audio; sampled monitoring is not an absolute OS-enforced 10 GB cap.

- Severe repetition loops trigger bounded local retries from the audio. Failed attempts remain on disk; an unresolved failure is reported instead of accepting looping text. This does not detect every recognition error.
- Recognition can miss words, names, numbers or language switches. Review important passages against the recording; a second pass is not guaranteed to improve every sentence.
- “Me” and “Participants” identify the audio source. Multiple remote speakers are not separated by voice.
- Timestamps mark chunks, not individual words. There is no acoustic echo cancellation; headphones help avoid duplicated speaker audio.
- File import, automatic summaries, cloud sync and calendar integrations are not implemented.
- No automatic updater; signed public distribution and Windows support are future work.

## License and attribution

Original project code, documentation and the original icon are licensed under [Apache-2.0](LICENSE). See [NOTICE](NOTICE) for attribution. Third-party packages and model weights keep their own licenses; see [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md). This source tree contains neither model weights nor the Python runtime.

See the [changelog](CHANGELOG.md) and the [release checklist](docs/RELEASE_CHECKLIST.md) for preparation status.

For bug reports and changes, read [Contributing / 参与贡献](CONTRIBUTING.md). Report suspected vulnerabilities through the [security guidance / 安全说明](SECURITY.md); keep meeting recordings, transcripts and personal data out of public issues.
