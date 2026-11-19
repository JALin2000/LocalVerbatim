import Foundation

/// Localizes app-owned status/error text from older persisted jobs. Transcript
/// content, user titles, notes and terminology are never passed to this function.
func userFacingError(_ value: String) -> String {
    if value.localizedCaseInsensitiveContains("TCC") || value.localizedCaseInsensitiveContains("user declined") {
        return tr("系统音频权限尚未生效。请打开“设置 → 录音”，检查屏幕与系统音频录制权限。更新应用后可能需要在系统设置中重新添加当前应用。", "System audio permission is not active. Open Settings → Recording and check Screen & System Audio Recording. After an app update, you may need to re-add the current app in System Settings.")
    }
    guard !AppSettings.shared.isChinese else { return value }
    var result = value
    let translations: [(String, String)] = [
        ("麦克风没有传入音频数据。请检查系统输入设备和麦克风权限后重新录音；电脑音频已保留。", "No microphone audio arrived. Check the input device and microphone permission, then retry; system audio is retained."),
        ("麦克风持续没有声音。使用 MacBook 内置麦克风时请打开屏幕上盖，并检查静音和输入设备。录音仍在继续。", "The microphone has been silent. Open the MacBook lid when using its built-in microphone and check mute and input selection. Recording continues."),
        ("本次录音没有收到麦克风数据，电脑音频已保留。请检查输入设备与麦克风权限。", "This recording received no microphone data. System audio is retained. Check the input device and microphone permission."),
        ("音频设备没有提供有效的 PCM 格式。", "The audio device did not provide a valid PCM format."),
        ("无法将麦克风格式转换为 16 kHz 音频。", "Could not convert microphone audio to 16kHz."),
        ("无法分配音频转换缓冲区。", "Could not allocate an audio conversion buffer."),
        ("音频采样转换失败。", "Audio sample conversion failed."),
        ("录音文件已经关闭。", "The recording file is already closed."),
        ("单次录音超过 WAV 文件大小上限，请开始新的会议。", "This recording reached the WAV size limit. Start a new meeting."),
        ("无法读取音频缓冲区（", "Could not read the audio buffer ("),
        ("读取音频采样失败（", "Could not read audio samples ("),
        ("无法恢复录音：", "Could not recover recording: "),
        ("不是普通音频文件。", "is not a regular audio file."),
        ("的 WAV 文件头不完整。", "has an incomplete WAV header."),
        ("超过标准 WAV 大小上限。", "exceeds the standard WAV size limit."),
        ("不是本地逐字稿（LocalVerbatim）的 16 kHz 单声道 PCM16 WAV。", "is not a LocalVerbatim 16kHz mono PCM16 WAV."),
        ("恢复窗口超出音频边界。", "The recovery window exceeds the audio bounds."),
        ("音频文件在恢复过程中被截断。", "The audio file was truncated during recovery."),
        ("系统音频权限尚未生效。请在“系统设置 → 隐私与安全性 → 屏幕与系统音频录制”中允许本地逐字稿（LocalVerbatim）。重新编译后，可能需要移除旧条目，用“+”重新选择当前应用并重新打开。", "System audio permission is not active. Open System Settings → Privacy & Security → Screen & System Audio Recording. After an app update, remove the old entry, add the current app, and reopen it."),
        ("请在系统设置 → 隐私与安全性 → 麦克风中允许本地逐字稿（LocalVerbatim），然后重新开始录音。", "Allow LocalVerbatim in System Settings → Privacy & Security → Microphone, then retry."),
        ("没有找到可用的麦克风。请在系统设置 → 声音 → 输入中选择输入设备。", "The selected microphone is unavailable. Choose a connected input in Settings → Recording."),
        ("没有可用的显示器，无法建立电脑音频采集。", "No display is available to initialize system audio capture."),
        ("录音已经开始，请先结束当前会议。", "Recording has already started. Stop the current meeting first."),
        ("本地模型或运行环境缺失，请重新安装完整的本地逐字稿（LocalVerbatim）应用。", "The speech model or runtime is missing. Open Settings → Transcription to install the model."),
        ("模型已达到 8.5GB 安全阈值，转写已停止。录音继续保存，稍后可以重试。", "Transcription stopped at the 8.5GB memory guard. Recording is still saved; you can retry later."),
        ("录音和待处理片段已保存，可重试。详情见 engine.log。", "Audio and pending segments are saved. Retry transcription; see engine.log for details."),
        ("原始音频仍在，稍后可继续转写。", "Original audio is retained. You can resume transcription later."),
        ("尚无可播放的录音。", "No playable audio is available yet."),
        ("会议目录不正确，未删除任何文件。", "Invalid meeting folder. No files were deleted."),
        ("模板设置读取失败，已保留原文件副本。", "Template settings could not be read. A copy of the original file was preserved."),
        ("无法将会议和录音移到废纸篓，会议仍保留：", "Could not move the meeting and audio to Trash. The meeting is retained: "),
        ("二次识别已停止，原稿和录音已保留：", "Second pass stopped. Original transcript and audio are retained: "),
        ("无法保存转写原文：", "Could not save transcript output: "),
        ("恢复会议录音时出错：", "Could not recover meeting audio: "),
        ("无法恢复待转写音频：", "Could not recover pending audio: "),
        ("无法保存术语模板：", "Could not save term templates: "),
        ("会议保存失败：", "Could not save meeting: "),
        ("导出失败：", "Export failed: "),
        ("录音已停止：", "Recording stopped: "),
        ("无法提交音频片段：", "Could not submit audio segment: "),
        ("某个片段转写失败：", "A segment could not be transcribed: "),
        ("识别进程退出（", "Transcription process exited ("), ("）。", "). "),
        ("保存二次识别进度失败", "Could not save second-pass progress"),
        ("录音文件头不完整", "Incomplete audio header"),
        ("二次识别需要完整的 16 kHz 单声道 PCM16 录音", "Second pass needs complete 16kHz mono PCM16 audio"),
        ("录音尚未完整保存，请先恢复录音", "Audio is incomplete. Recover the recording first"),
        ("读取录音失败", "Could not read the audio"),
        ("二次识别等待录音结束", "Second pass is waiting for recording to stop"),
        ("正在载入本地中英文模型…", "Loading local speech model…"),
        ("正在载入模型…", "Loading model…"),
        ("正在二次识别", "Running second pass"), ("正在转写", "Transcribing"),
        ("模型已就绪", "Model ready"), ("模型待命", "Model idle"),
        ("模型未安装", "Model not installed"), ("无法启动模型", "Could not start model"),
        ("转写已停止", "Transcription stopped"), ("未知转写错误", "Unknown transcription error")
    ]
    for (chinese, english) in translations { result = result.replacingOccurrences(of: chinese, with: english) }
    return result
}
