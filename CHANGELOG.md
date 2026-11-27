# Changelog

Version 0.4.7 is the first public source snapshot; 0.4.8 adds the first unnotarized Mac installer preview. Earlier entries describe local development versions.

## Source publication

- Publish the source under Apache-2.0 with English/Chinese setup, contribution, privacy and security guidance.
- Use invented regression fixtures and exclude recordings, transcripts, runtime, model weights, diagnostics and local development history.
- Disable Hugging Face telemetry and implicit token use in the command-line model installer as well as the app.
- Correct the SwiftPM macOS deployment declaration for Swift tools 5.10.

## 0.4.9 — recording import

- Import MP3, M4A or WAV audio for local transcription, playback, export and automatic second pass.
- Add an optional model preload and memory test. Show installed RAM and stop recognition at 90% of that capacity while retaining audio.
- Link to GitHub source and releases from About.

## 0.4.8 — installer preview

- Prepare a self-contained Apple Silicon DMG with first-run model download and explicit unnotarized-preview labeling.
- Pin the CPython archive by official URL/SHA-256 and preparation wheels by URL/size/SHA-256; install offline after verification.
- Bundle the tested Qwen3-ASR application runtime without unused SciPy/GCC libraries, packaging tools, test data or bytecode. Keep full development dependencies separate.
- Include exact runtime/native dependency inventories, embedded-component notices and required MPL source files.
- Add inside-out native signing, optional Developer ID/notarization tooling, DMG round-trip signature checks and a private-data release checker.

## 0.4.7

- Add conservative Chinese repetition cleanup to the existing filler toggle for current and archived second-pass transcripts.
- Share reading cleanup between the UI, copy and manual TXT/Markdown/SRT exports. Keep stored model text, original-pass repetition behavior, timestamps and audio unchanged.
- Apply the filter to existing meetings immediately, with no extra model or transcription run.

## 0.4.6

- Keep transcript-history choices inside the application window instead of using a detached native tracking menu; collapse the list when the app loses focus.
- Remove the “Review needed” suffix from the second-pass selector and generated export headings.
- Allow repeated second passes after completion or a stop/failure. Each new run snapshots the current language, terms and background, including the last uncommitted term.
- Preserve previous passes in transcript history, including their settings and partial results; make history selectable and exportable. Keep the last complete transcript visible during a new run or after a failure.
- Keep resume/retry distinct from starting over, reject callbacks from superseded runs, and atomically preserve history before queueing new work.

## 0.4.5

- Use a single main-window scene, disable automatic window tabbing/restoration, and handle Dock/Finder reopen without creating another window.
- Detect severe repetition loops and token-limit truncation in both live and second-pass recognition. Retry the same audio without terminology/context; if necessary retry shorter windows with a mild repetition penalty. Keep raw attempts locally and reject results that still fail the check. This is a quality heuristic, not an accuracy guarantee.
- Organize recordings by date, meeting title and a stable short ID. Keep full WAV tracks visible, exports in `Transcripts/`, and working files in hidden `.localverbatim/`.
- Migrate legacy UUID folders without rewriting audio. Update folder names after title edits once recording/transcription is idle; preserve paused passes, transcripts, deletion and storage migration.

## 0.4.4

- Rename the app to LocalVerbatim, with 本地逐字稿 as its Chinese name.
- Update UI, menus, notifications, permission descriptions, application/executable names, Swift target, build scripts and bilingual documentation.
- Retain the historical bundle identifier, default data directory, existing custom paths and legacy development environment overrides. Existing meetings, recordings, models and preferences are reused without data migration.

## 0.4.3 — source preparation

- Original green waveform/card icon with editable source artwork.
- Improved Chinese/English field labels, control sizing and settings alignment.
- Prepared a clean source tree, bilingual README/install/developer guides, Apache-2.0 licensing and third-party attribution.

## 0.4.2

- Stop and resume second-pass transcription; retain recordings, original text and completed results.
- Preserve a stopped task across application restarts.

## 0.4.1

- Expanded hit areas for meeting rows, settings categories and related controls.

## 0.4.0

- Chinese/English UI, settings, themes, global shortcuts and recording diagnostics.
- Comma-separated terminology chips, filler display toggle, sticky transcript/notes tabs and separate reading positions.
- Storage migration and first-run model download/import.

## 0.3.x

- Reusable terminology templates and automatic second-pass transcription.
- Recoverable deletion of meetings and their recordings.

## 0.1–0.2

- Local microphone/system audio recording and Qwen3-ASR transcription.
- Transcript export, crash recovery, vocabulary hints and overlap cleanup.
