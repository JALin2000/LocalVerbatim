# Installation and everyday use

[简体中文](INSTALL.zh-CN.md) · [README](../README.md)

## Before installing

Use an Apple Silicon Mac with macOS 15 or later. A 16 GB machine is recommended; 8 GB and the full supported OS range have not been validated. Intel Macs and Windows are not supported.

Allow at least 6 GB for the app and one model, with additional space for download work files and recordings. A packaged app contains its own Python runtime. No developer tools or account are needed to use that package.

Download the v0.5.0 preview DMG and `SHA256SUMS.txt` from the [GitHub release](https://github.com/JALin2000/LocalVerbatim/releases/tag/v0.5.0-preview.1). It is **ad-hoc signed and not notarized by Apple**. A checksum identifies a particular file; it does not establish an Apple-verified publisher. Managed Macs may prohibit opening this preview. Use the [developer guide](DEVELOPMENT.md) to build from source instead.

## Install the preview DMG

1. Obtain the DMG and `SHA256SUMS.txt` from the release page linked above.
2. Check the file in Terminal, substituting the path to your download:

   ```sh
   shasum -a 256 /path/to/LocalVerbatim-mac-arm64.dmg
   ```

3. Open the DMG and drag **LocalVerbatim** to **Applications**. Eject the DMG and start the app from Applications.
4. If macOS blocks this unnotarized preview, first confirm its source and checksum. Consult [Apple's instructions for opening apps safely](https://support.apple.com/en-gb/102445); after an attempted launch, the supported per-app flow is **System Settings → Privacy & Security → Open Anyway**. Do not disable Gatekeeper or remove quarantine attributes as an installation step. A damaged/malware warning should be investigated, not dismissed as an expected permission prompt.

To build instead, follow the [developer guide](DEVELOPMENT.md). The development app must stay alongside its runtime/engine; it is not the standalone Applications package.

## First launch and model installation

1. The setup guide starts in Simplified Chinese when macOS prefers Chinese and in English otherwise. Choose **Follow system**, **简体中文** or **English** at the top of the guide. The interface updates immediately.
2. Choose a **Qwen3-ASR-1.7B** model to download or import. The guide recommends **8-bit (2.47 GB)** for Macs with **8 GB RAM or less**, and **BF16 (4.08 GB)** for Macs with more than 8 GB. The installer ships without model weights.
3. Each download uses a fixed Hugging Face revision and verifies file sizes and SHA-256 hashes. Import accepts a folder matching the selected variant and revision.
4. The model download can be paused and resumed. Keep enough free space until verification completes. If the network fails, retry; partial files are retained. Recording/transcription do not require a Hugging Face login.
5. After installation, recording and recognition can run offline. The default model cache is `~/Library/Application Support/LocalScribe/Models/`; Settings → Storage shows the active location.
6. In **Settings → Transcription**, download the other variant and click **Use this model** when recording and transcription are idle. The model already in use stays selected until you switch. Upgrades keep your existing model.

**Settings → General → Interface text size** offers Small, Standard and Large. Adjust transcript text separately in the same section. Click the area around the settings panel to close it.

## Grant permissions and verify both tracks

Allow Microphone and Screen & System Audio Recording when macOS requests them. Wording varies by OS version. ScreenCaptureKit is used to receive system audio; the app does not save screen pictures or video.

Open **Settings → Recording** and select an input device. Run the **10-second audio test**, say a short sentence, and let its test tone play. Check that **both** sources report audio received, then use the separate Play buttons to confirm their contents. An enabled permission switch alone does not prove a device is delivering samples.

Use headphones during meetings to avoid speaker output entering the microphone again. With the laptop lid closed, use an external microphone; the built-in microphone may be hardware-disconnected. No accessibility/input-monitoring permission is needed for the Carbon global shortcuts used here.

## Record a meeting

1. Create a meeting and optionally edit its title, terminology and background. Separate terms with an English/Chinese comma or Return; each accepted term becomes a chip.
2. Choose automatic English/Mandarin, English or Mandarin recognition. Click **Start recording** and check the two meters.
3. Record notes while the transcript updates. Closing the window keeps recording in the menu bar; quitting the app finishes and saves the recording.
4. Stop with the button or **Control + Option + S**. If automatic second pass is enabled, it runs after pending original-transcript tasks finish.
5. **Stop second pass** preserves the original, audio and completed second-pass text. **Resume second pass** processes the remaining windows; explicitly stopped work stays stopped after reopening the app.
6. After changing terms, background or language, choose **Run second pass again** to start from the beginning with the current settings. Resume/retry keeps the previous settings and completed work. Previous passes remain available in **Transcript version**; a new run keeps the last completed text visible until it finishes.
7. Select the desired transcript version and filler setting before copying/exporting. Display filtering never rewrites the original model output.

Default shortcuts are Control + Option + R (start), S (stop), and L (show), all with the same two modifiers. Configure them in Settings → Shortcuts. Optional Dock hiding applies only to shortcut-started recordings; the menu-bar entry remains.

## Transcribe an existing recording

Click **Import recording** below **New meeting**. Choose an MP3, M4A or WAV file. The app stores a local copy and runs transcription with the current language and terminology defaults. The setting **Run a second pass on recordings and keep the original transcript** also applies to imports. Imported recordings support timestamp playback, notes, export and manual second passes.

The footer shows the recognition process's current physical footprint over installed RAM. **Preload & test memory** optionally loads the model and runs a short synthetic audio test. Recording and transcription load the model automatically.

## Troubleshooting

| Symptom | Check |
|---|---|
| Microphone meter stays flat | Correct input device, physical mute, open lid or external microphone, Microphone permission; rerun the audio test |
| System audio stays flat | Play audio, check Screen & System Audio Recording permission, then test again; some protected content may not be capturable |
| Permission appears allowed but an updated trial fails | Quit the app. In macOS privacy settings remove the stale system-audio entry and add the current Applications app. Complete any system authentication yourself and reopen. Avoid resetting unrelated permissions |
| Model download fails | Network access to Hugging Face, free disk space and the chosen cache directory. Retry to resume; do not rename incomplete files into the final model folder |
| Model/transcription stops | Read the error; memory protection may have stopped ASR. Audio is retained. Free memory and resume/retry the pending transcript task |
| External storage is missing | Reconnect the original volume or explicitly select/migrate storage in Settings; the app does not silently choose another recordings directory |
| Two copies of the same speech | Use headphones. The app does not currently provide acoustic echo cancellation |
| Unknown terms are wrong | Add concise terms/context before recording; a full second pass can use better context, but still requires review |

## Upgrade, backup and uninstall

Version 0.4.4 renames the app from LocalScribe to **LocalVerbatim** (Chinese: **本地逐字稿**). The application bundle is `LocalVerbatim.app`. It deliberately retains `local.localscribe.meeting-recorder` as its bundle identifier and `~/Library/Application Support/LocalScribe/` as its default data root. Existing custom storage paths, meeting IDs and audio paths are read unchanged. Do not rename the data folder to match the new brand. Models in the user cache or a custom location are reused.

Some older private builds keep their model inside the app bundle. When replacing one with a weight-free DMG, keep the old bundle and import its `Contents/Resources/Support/models/Qwen3-ASR-1.7B-bf16` folder through the setup guide. This verifies and copies the existing model instead of downloading it again. A locally prepared upgrade can also retain the bundled weights directly.

For a manual upgrade, quit the old app, install LocalVerbatim, and keep the old app as a backup outside Applications until you verify the new app opens your meetings. Do not run both versions simultaneously. The app's language setting controls the in-app name; Finder and system dialogs use macOS's chosen localization.

Stop recording and quit before replacing the app in Applications. The standalone app stores user data separately, so replacing its bundle preserves recordings/settings. Back up the active recordings directory, `settings.json` and `preferences.json` before an important upgrade; include custom storage locations. Model weights can be downloaded again.

The default data root is `~/Library/Application Support/LocalScribe/`. It contains Recordings, Models, settings, terminology preferences and diagnostic/log files. Storage settings can redirect recordings and models. The developer build uses its source directory instead; see [Development](DEVELOPMENT.md).

Deleting a meeting in the app moves its complete folder, including both audio tracks, to the macOS Trash. To restore it before the Trash is emptied, quit the app and return the entire meeting folder (including hidden files) to the active Recordings directory. Separately exported copies are unaffected.

To uninstall, disable Launch at login if enabled, quit the app, and move the application to Trash. Your meetings and model cache remain. If you also want to remove user data, back it up and remove the data folders you actually selected; do not assume all files are in the default location.

## Folder layout from 0.4.5

On first launch, legacy UUID folders are organized as `2026-11-16 10-00 · Weekly sync [12345678]/`. Full `microphone.wav` and `system.wav` tracks remain at the top level. `Transcripts/` contains `original` and `refined` TXT/Markdown/SRT files. Hidden `.localverbatim/` retains metadata, notes, audio chunks, raw recognition attempts and second-pass state. This is organization, not encryption; Finder's Command–Shift–period shows hidden files.

Changing a meeting title updates its folder when recording/transcription is idle. IDs and audio bytes remain stable. Back up the complete recording library before upgrading, including hidden files. Do not merge conflicting folders manually: organization stops rather than overwriting a destination. Earlier app versions do not read this new layout; to downgrade, restore a pre-upgrade library backup while the app is closed.

Second-pass history was added in 0.4.6. Earlier versions do not preserve this history field; restore a pre-upgrade backup before downgrading.

## Reduce repetitions in second-pass text

For current and previous second passes, **Reduce fillers & repetitions** also merges obvious Chinese speech restarts. Existing meetings update immediately without rerunning the model. Uncheck it to view the original wording. Copy and manual exports follow the displayed text; stored raw transcripts, recordings and timestamps are retained. This is conservative Chinese reading cleanup, not summarization or grammatical rewriting; it does not catch every disfluency.
