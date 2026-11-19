# Privacy and local data / 隐私与本地数据

## English

- Microphone audio and computer playback are recorded to separate local WAV files. System capture receives audio; screen pictures/video are not saved. Follow the meeting's recording expectations and obtain any required permission before recording.
- Transcription runs on this Mac. There is no account, cloud ASR, telemetry service, automatic updater or cloud synchronization in the current application.
- A user-requested model download connects to Hugging Face and its file delivery services. Those services receive ordinary download connection information such as an IP address; meeting audio/text is not part of the request. Both the app and command-line model installer disable Hugging Face telemetry and implicit token use. Developer setup also downloads tools and dependencies from their providers.
- A standalone app defaults to `~/Library/Application Support/LocalScribe/`: `Recordings/`, `Models/`, `Diagnostics/`, `settings.json`, `preferences.json`, logs and download caches. Custom recordings/model locations are shown in Settings. Development builds use their source directory instead.
- Meetings include complete audio, working chunks, notes, original model text, refinement results and exports. These are ordinary local files; the application does not add its own encryption layer or access password. OS permissions, FileVault and backups remain under the user's control.
- Deleting a meeting moves the complete folder to macOS Trash. Data remains recoverable until Trash is emptied. External exports, backups, terminology templates and diagnostic test recordings are separate and are not removed with a meeting.
- Logs can contain file paths, error messages and other context. Before sharing diagnostics, remove private titles, names, transcript text, paths and tokens. Do not attach real meeting recordings to public issues.
- Hiding the Dock icon or recording badge does not alter macOS's own privacy indicators or the fact that recording is in progress.

## 简体中文

- 麦克风与电脑声音分别录为本地 WAV。系统采集接收音频，不保存屏幕图片或视频。录音前应遵循会议的录制约定并获得必要许可。
- 识别在本机运行，当前应用没有账号、云端转写、遥测服务、自动更新或云同步。
- 用户主动下载模型时会连接 Hugging Face 及其文件分发服务，对方会获得 IP 地址等普通下载连接信息，会议音频和文字不在下载请求中。应用与命令行模型安装器均禁用 Hugging Face 遥测和隐式令牌。开发初始化还会从相应提供方下载工具和依赖。
- 独立安装版默认使用 `~/Library/Application Support/LocalScribe/`，包括录音、模型、诊断、设置、术语、日志和下载缓存；自定义录音/模型位置见设置。开发版使用源码目录。
- 会议包括完整音轨、工作片段、笔记、模型原稿、二次识别结果和导出，均为普通本地文件。应用不额外加密或设置访问密码，系统权限、FileVault 和备份由用户管理。
- 删除会议会移入 macOS 废纸篓，清空前仍可恢复。独立导出、备份、术语模板及诊断测试录音不会随会议一起删除。
- 日志可能包含路径、错误信息及其他上下文。分享诊断前应删除私人名称、会议文字、个人路径和令牌，不在公开问题中附真实会议录音。
- 隐藏 Dock 或录音图标标记不会改变 macOS 自身的隐私指示，也不改变正在录音这一事实。
