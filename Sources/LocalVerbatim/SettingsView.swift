import SwiftUI
import AVFoundation
import AppKit

struct SettingsView: View {
    @ObservedObject var store: MeetingStore
    @ObservedObject private var settings = AppSettings.shared
    @ObservedObject private var hotkeys = HotkeyManager.shared
    @ObservedObject private var experience = AppExperience.shared
    @State private var category = "general"
    @Environment(\.dismiss) private var dismiss
    private let categories: [(String, String, String, String)] = [
        ("general", "通用", "General", "slider.horizontal.3"), ("recording", "录音", "Recording", "mic"),
        ("transcription", "转写", "Transcription", "text.alignleft"), ("shortcuts", "快捷键", "Shortcuts", "keyboard"),
        ("storage", "存储", "Storage", "externaldrive"), ("privacy", "隐私与通知", "Privacy & notifications", "lock.shield"),
        ("about", "关于", "About", "info.circle")]
    var body: some View {
        VStack(spacing: 0) {
            HStack { Text(tr("设置", "Settings")).font(.title2.bold()); Spacer(); Button(tr("完成", "Done")) { dismiss() }.keyboardShortcut(.cancelAction) }
                .padding(22)
            Divider()
            HStack(spacing: 0) {
                VStack(alignment: .leading, spacing: 5) {
                    ForEach(categories, id: \.0) { item in
                        Button { category = item.0 } label: {
                            Label(tr(item.1, item.2), systemImage: item.3).font(.system(size: 12))
                                .lineLimit(1)
                                .frame(maxWidth: .infinity, alignment: .leading).padding(10)
                                .background(category == item.0 ? AppPalette.accent.opacity(0.12) : .clear, in: RoundedRectangle(cornerRadius: 7))
                                .contentShape(Rectangle())
                        }.buttonStyle(.plain)
                    }
                    Spacer()
                }.padding(12).frame(width: 220).background(Color(nsColor: .windowBackgroundColor))
                Divider()
                ScrollView {
                    VStack(alignment: .leading, spacing: 22) {
                        switch category {
                        case "recording": recording
                        case "transcription": transcription
                        case "shortcuts": shortcuts
                        case "storage": storage
                        case "privacy": privacy
                        case "about": about
                        default: general
                        }
                        if let error = settings.error ?? experience.error { Text(userFacingError(error)).foregroundStyle(.orange).font(.caption).textSelection(.enabled) }
                    }.padding(25).frame(maxWidth: .infinity, alignment: .leading)
                }.background(Color(nsColor: .textBackgroundColor))
            }
        }.frame(width: 830, height: 650)
            .tint(AppPalette.accent).preferredColorScheme(settings.colorScheme)
            .environment(\.locale, settings.locale)
            .onAppear { store.diagnostics.refresh(); experience.refreshSystemPreferences() }
    }
    private var general: some View {
        VStack(alignment: .leading, spacing: 20) {
            title("语言与外观", "Language & appearance")
            LabeledControl(tr("界面语言", "Interface language")) {
                Picker(tr("界面语言", "Interface language"), selection: settings.binding(\.interfaceLanguage)) {
                    Text(tr("跟随系统", "Follow system")).tag("system")
                    Text("简体中文").tag("zh-Hans"); Text("English").tag("en")
                }.frame(maxWidth: 320, alignment: .leading)
            }
            Text(tr("只改变界面和导出标签，不翻译会议原文。", "Changes interface and export labels. Meeting content stays in its original language.")).font(.caption).foregroundStyle(.secondary)
            LabeledControl(tr("外观", "Appearance")) {
                Picker(tr("外观", "Appearance"), selection: settings.binding(\.appearance)) {
                    Text(tr("跟随系统", "Follow system")).tag("system")
                    Text(tr("浅色", "Light")).tag("light"); Text(tr("深色", "Dark")).tag("dark")
                }.pickerStyle(.segmented).frame(maxWidth: 420, alignment: .leading)
            }
            HStack { Text(tr("逐字稿字号", "Transcript text size")).fixedSize(); Slider(value: settings.binding(\.textSize), in: 12...22, step: 1); Text("\(Int(settings.options.textSize)) pt").monospacedDigit().fixedSize() }
            Divider()
            title("启动与窗口", "Startup & windows")
            Toggle(tr("登录 Mac 时启动", "Launch at login"), isOn: Binding(get: { experience.launchAtLogin }, set: experience.setLaunchAtLogin))
            Text(tr("启动应用不会自动录音。关闭窗口后，录音和转写会继续；可从菜单栏或快捷键重新打开。退出应用会先保存录音。", "Launching the app never starts recording. Closing the window keeps recording and transcription running. Reopen it from the menu bar or a shortcut. Quitting saves the recording first.")).font(.caption).foregroundStyle(.secondary)
            Button(tr("重新查看使用向导", "Show setup guide")) { dismiss(); store.showSetup = true }
        }
    }
    private var recording: some View {
        VStack(alignment: .leading, spacing: 18) {
            title("输入设备", "Input device")
            MicrophonePicker(diagnostics: store.diagnostics, disabled: store.recording || store.starting || store.diagnostics.running)
            Toggle(tr("录音时图标显示红点", "Show a red recording indicator on app icons"), isOn: settings.binding(\.recordingBadge))
            Text(tr("控制 Dock 和菜单栏的应用图标。关闭后图标保持不变，窗口内仍显示录音状态。", "Controls the Dock and menu bar icons. When off, icons stay unchanged; the window still shows recording status.")).font(.caption).foregroundStyle(.secondary)
            Toggle(tr("开始录音时播放提示音", "Play a sound when recording starts"), isOn: settings.binding(\.startSound))
            Toggle(tr("停止录音时播放提示音", "Play a sound when recording stops"), isOn: settings.binding(\.stopSound))
            Divider()
            DiagnosticsPanel(diagnostics: store.diagnostics, allowed: !store.recording && !store.starting && !store.stopping && !store.migrating)
        }
    }
    private var transcription: some View {
        VStack(alignment: .leading, spacing: 18) {
            title("新会议的默认设置", "Defaults for new meetings")
            LabeledControl(tr("识别语言", "Speech language")) {
                Picker(tr("识别语言", "Speech language"), selection: settings.binding(\.defaultLanguage)) {
                    Text(tr("自动 · 中英混合", "Auto · English & Mandarin")).tag("")
                    Text("English").tag("English"); Text(tr("普通话", "Mandarin")).tag("Chinese")
                }.frame(maxWidth: 380, alignment: .leading)
            }
            Toggle(tr("结束后自动二次识别，保留原稿", "Run a second pass after recording; keep the original"), isOn: settings.binding(\.autoRefine))
            LabeledControl(tr("空闲后释放模型内存", "Unload the model when idle")) {
                Picker(tr("空闲后释放模型内存", "Unload the model when idle"), selection: settings.binding(\.idleUnloadMinutes)) {
                    Text(tr("从不", "Never")).tag(0)
                    Text(tr("1分钟", "1 minute")).tag(1); Text(tr("5分钟", "5 minutes")).tag(5)
                    Text(tr("15分钟", "15 minutes")).tag(15)
                }.frame(maxWidth: 280, alignment: .leading)
            }
            Text(tr("术语和背景仍沿用上一场会议。上述默认设置不改动已有会议。", "Terms and background carry over from your last meeting. These defaults do not change existing meetings.")).font(.caption).foregroundStyle(.secondary)
            Divider(); ModelPanel(manager: store.modelManager)
        }
    }
    private var shortcuts: some View {
        VStack(alignment: .leading, spacing: 20) {
            title("全局快捷键", "Global shortcuts")
            Toggle(tr("启用全局快捷键", "Enable global shortcuts"), isOn: Binding(get: { settings.options.shortcutsEnabled }, set: { value in
                var options = settings.options; options.shortcutsEnabled = value; _ = hotkeys.configure(options, persist: true)
            }))
            shortcutRow(tr("开始录音", "Start recording"), keyPath: \.startShortcut)
            shortcutRow(tr("停止录音", "Stop recording"), keyPath: \.stopShortcut)
            shortcutRow(tr("显示主窗口", "Show main window"), keyPath: \.showShortcut)
            Button(tr("恢复默认快捷键", "Restore default shortcuts")) { hotkeys.restoreDefaults() }
            if let error = hotkeys.error { Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(.orange).font(.caption) }
            Divider()
            Toggle(tr("快捷键录音时隐藏 Dock 图标", "Hide the Dock icon for shortcut-started recordings"), isOn: settings.binding(\.hideDockForHotkeys))
            Text(tr("仅当本场录音通过快捷键启动时生效。不弹出窗口，停止时也不抢焦点。菜单栏入口始终保留；“显示主窗口”会恢复 Dock 图标。界面按钮启动的录音不受影响。", "Applies only to recordings started with a shortcut. The window stays hidden and stopping does not take focus. The menu bar remains available. Show Main Window restores the Dock icon. Recordings started with the on-screen button are unaffected.")).font(.caption).foregroundStyle(.secondary)
            Text(tr("macOS 自己的麦克风和系统音频指示由系统管理，仍会显示。", "macOS microphone and system audio privacy indicators remain visible.")).font(.caption).foregroundStyle(.secondary)
        }
    }
    private func shortcutRow(_ label: String, keyPath: WritableKeyPath<UserOptions, Shortcut>) -> some View {
        HStack { Text(label).fixedSize(); Spacer(); ShortcutRecorder(value: settings.options[keyPath: keyPath]) { hotkeys.change(keyPath, to: $0) }.frame(width: 185, height: 28) }
            .disabled(!settings.options.shortcutsEnabled)
    }
    private var storage: some View {
        VStack(alignment: .leading, spacing: 18) {
            title("录音与会议", "Recordings & meetings")
            Text(AppPaths.recordings.path).font(.system(.caption, design: .monospaced)).textSelection(.enabled)
            Text(tr("可用空间：", "Available space: ") + StorageMigration.freeSpace(at: AppPaths.recordings)).font(.caption).foregroundStyle(.secondary)
            HStack {
                Button(tr("更改录音库位置…", "Change library location…")) { store.chooseStorageLocation(models: false) }.disabled(!store.canMigrate)
                Button(tr("在 Finder 中打开", "Show in Finder")) { NSWorkspace.shared.open(AppPaths.recordings) }
            }
            if store.libraryUnavailable { Button(tr("重新读取录音库", "Reconnect recording library")) { store.reloadLibrary() } }
            Divider(); title("模型缓存", "Model cache")
            Text(AppSettings.shared.modelCacheDirectory.path).font(.system(.caption, design: .monospaced)).textSelection(.enabled)
            Text(tr("当前模型：", "Current model: ") + AppPaths.model.path).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
            Button(tr("更改模型位置…", "Change model location…")) { store.chooseStorageLocation(models: true) }.disabled(!store.canMigrate || !store.modelManager.available)
            Text(tr("迁移会复制全部文件并校验，成功后才切换位置。原文件保留，不自动删除。录音、转写或收音测试期间不能迁移。", "Migration copies and verifies every file before changing locations. Original files are retained. Finish recording, transcription or audio tests before migrating.")).font(.caption).foregroundStyle(.secondary)
            if store.migrating { ProgressView() }
            if !store.migrationMessage.isEmpty { Text(userFacingError(store.migrationMessage)).font(.caption).textSelection(.enabled) }
        }
    }
    private var privacy: some View {
        VStack(alignment: .leading, spacing: 20) {
            title("本地处理", "Local processing")
            Label(tr("录音和逐字稿保存在本机", "Audio and transcripts stay on this Mac"), systemImage: "lock.shield")
            Text(tr("仅当你选择下载模型时会连接模型托管服务。录音和识别不调用云端转写服务，也不上传会议内容。", "Only a model download connects to the model host. Recording and transcription do not use a cloud transcription service or upload meeting content.")).font(.caption).foregroundStyle(.secondary)
            Divider(); title("通知", "Notifications")
            Toggle(tr("逐字稿完成时通知", "Notify when a transcript is ready"), isOn: settings.binding(\.completionNotifications))
            Text(tr("通知只显示通用完成提示，不包含会议名称或逐字稿。", "Notifications use a generic completion message, without meeting names or transcript text.")).font(.caption).foregroundStyle(.secondary)
            HStack {
                Text(experience.notificationsAllowed ? tr("系统通知已允许", "System notifications allowed") : tr("尚未允许系统通知", "System notifications not allowed")).font(.caption)
                if !experience.notificationsAllowed { Button(tr("允许系统通知…", "Allow system notifications…")) { experience.requestNotifications() } }
                Button(tr("刷新", "Refresh")) { experience.refreshSystemPreferences() }
            }
        }
    }
    private var about: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack(spacing: 14) {
                Image(nsImage: AppBrand.icon).resizable().interpolation(.high).frame(width: 60, height: 60).accessibilityHidden(true)
                Text(AppIdentity.displayName).font(.largeTitle.bold())
                Text(AppSettings.shared.isChinese ? AppIdentity.englishName : AppIdentity.chineseName).font(.subheadline).foregroundStyle(.secondary)
            }
            Text((Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.4.1") + tr(" · Mac 试用版", " · Mac preview"))
            Text(tr("本地双路会议录音与中英文逐字稿。", "Local microphone and system-audio recording with English and Mandarin transcription."))
            Text("Qwen3-ASR-1.7B BF16 · MLX").font(.caption).foregroundStyle(.secondary)
            Text(tr("模型物理内存达到8.5GB时提前停止转写并保留录音。采样监测不是操作系统级的绝对内存上限。", "Transcription stops at the sampled 8.5GB model-memory guard; recordings are retained. Sampling is not an OS-enforced hard memory limit.")).font(.caption).foregroundStyle(.secondary)
            Button(tr("打开本地数据目录", "Open local data folder")) { NSWorkspace.shared.open(AppPaths.dataRoot) }
            Text(tr("本试用版未发布到 GitHub。", "This preview has not been published to GitHub.")).font(.caption).foregroundStyle(.secondary)
        }
    }
    private func title(_ zh: String, _ en: String) -> some View { Text(tr(zh, en)).font(.headline) }
}

struct MicrophonePicker: View {
    @ObservedObject var diagnostics: AudioDiagnostics
    @ObservedObject private var settings = AppSettings.shared
    var disabled = false
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            LabeledControl(tr("麦克风", "Microphone")) {
                HStack {
                    Picker(tr("麦克风", "Microphone"), selection: settings.binding(\.microphoneID)) {
                        Text(tr("跟随系统默认输入", "Follow system input")).tag("")
                        ForEach(diagnostics.devices) { device in Text(device.name).tag(device.id) }
                        if !settings.options.microphoneID.isEmpty && !diagnostics.devices.contains(where: { $0.id == settings.options.microphoneID }) {
                            Text(tr("已选择的设备未连接", "Selected device disconnected")).tag(settings.options.microphoneID)
                        }
                    }.disabled(disabled)
                    Button { diagnostics.refresh() } label: { Image(systemName: "arrow.clockwise") }.help(tr("刷新设备", "Refresh devices"))
                }
            }
            Text(tr("设备选择在下一次录音生效。合盖时请使用外接麦克风。", "Device changes apply to the next recording. Use an external microphone with the lid closed.")).font(.caption).foregroundStyle(.secondary)
        }
    }
}

struct DiagnosticsPanel: View {
    @ObservedObject private var settings = AppSettings.shared
    @ObservedObject var diagnostics: AudioDiagnostics
    var allowed: Bool
    var body: some View {
        VStack(alignment: .leading, spacing: 13) {
            Text(tr("权限与双路收音自检", "Permissions & two-source audio check")).font(.headline)
            HStack {
                permission(tr("麦克风权限", "Microphone permission"), allowed: diagnostics.microphonePermission == .authorized)
                Spacer(); Button(tr("系统设置…", "System Settings…")) { diagnostics.openPermissionSettings(microphone: true) }
            }
            HStack {
                permission(tr("系统音频权限", "System audio permission"), allowed: diagnostics.screenPermission)
                Spacer(); Button(tr("系统设置…", "System Settings…")) { diagnostics.openPermissionSettings(microphone: false) }
            }
            Text(tr("权限开关不等于已收到声音。运行10秒测试，并说一句话；提示音会检查电脑声音。更新应用后若权限失效，请在系统设置中重新添加当前应用。", "A permission switch does not prove audio is arriving. Run a 10-second test and say a sentence; a tone checks computer audio. If an update invalidates permission, re-add the current app in System Settings.")).font(.caption).foregroundStyle(.secondary)
            HStack {
                if diagnostics.running {
                    ProgressView().controlSize(.small)
                    Text(diagnostics.secondsLeft > 0 ? "\(diagnostics.secondsLeft)s" : tr("正在准备…", "Preparing…"))
                    Button(tr("取消测试", "Cancel test")) { Task { await diagnostics.cancel() } }
                } else { Button(tr("开始10秒收音测试", "Run 10-second audio test")) { diagnostics.start() }.buttonStyle(.borderedProminent).disabled(!allowed) }
                Button(tr("刷新权限", "Refresh permissions")) { diagnostics.refresh() }
            }
            if !diagnostics.message.isEmpty { Text(diagnostics.message).font(.caption).textSelection(.enabled) }
            if let mic = diagnostics.microphonePassed, let system = diagnostics.systemPassed {
                HStack {
                    signal(tr("麦克风", "Microphone"), passed: mic)
                    Button(tr("回放", "Play")) { diagnostics.play("microphone") }
                    Spacer()
                    signal(tr("电脑声音", "System audio"), passed: system)
                    Button(tr("回放", "Play")) { diagnostics.play("system") }
                }.font(.caption)
            }
        }
    }
    private func permission(_ text: String, allowed: Bool) -> some View {
        Label(text + " · " + (allowed ? tr("已允许", "Allowed") : tr("待授权", "Needs permission")), systemImage: allowed ? "checkmark.circle.fill" : "exclamationmark.circle")
            .font(.system(size: 12)).foregroundStyle(allowed ? AppPalette.accent : .orange)
    }
    private func signal(_ text: String, passed: Bool) -> some View {
        Label(text + " · " + (passed ? tr("收到声音", "Audio received") : tr("未检测到声音", "No audio detected")), systemImage: passed ? "checkmark.waveform" : "waveform.slash")
            .foregroundStyle(passed ? AppPalette.accent : .orange)
    }
}

struct ModelPanel: View {
    @ObservedObject private var settings = AppSettings.shared
    @ObservedObject var manager: ModelManager
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label(manager.status, systemImage: manager.available ? "checkmark.circle.fill" : "arrow.down.circle").font(.headline)
            Text("Qwen3-ASR-1.7B · English / 普通话").font(.caption).foregroundStyle(.secondary)
            if manager.busy {
                ProgressView(value: manager.fraction)
                HStack { Text("\(Int(manager.fraction * 100))%").monospacedDigit(); Spacer(); Button(tr("暂停", "Pause")) { manager.pause() } }
            } else if !manager.available {
                Text(tr("首次需要下载约4GB模型。支持继续下载，也可导入已下载的模型。完成后录音和转写可离线使用。", "Download the model once (about 4GB), or import a local copy. Downloads can resume. Recording and transcription work offline afterwards.")).font(.caption).foregroundStyle(.secondary)
                HStack {
                    Button(tr("下载／继续下载", "Download / resume")) { manager.start() }.buttonStyle(.borderedProminent)
                    Button(tr("导入模型…", "Import model…")) { manager.importFolder() }
                }
            }
            if let error = manager.error { Text(error).font(.caption).foregroundStyle(.orange).textSelection(.enabled) }
        }
    }
}

struct SetupView: View {
    @ObservedObject var store: MeetingStore
    @ObservedObject private var settings = AppSettings.shared
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        VStack(spacing: 0) {
            HStack { Image(nsImage: AppBrand.icon).resizable().interpolation(.high).frame(width: 32, height: 32).accessibilityHidden(true); Text(tr("准备使用本地逐字稿", "Set up LocalVerbatim")).font(.title2.bold()); Spacer() }.padding(24)
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    LabeledControl(tr("界面语言", "Interface language")) {
                        Picker(tr("界面语言", "Interface language"), selection: settings.binding(\.interfaceLanguage)) {
                            Text(tr("跟随系统", "Follow system")).tag("system"); Text("简体中文").tag("zh-Hans"); Text("English").tag("en")
                        }.frame(maxWidth: 320, alignment: .leading)
                    }
                    ModelPanel(manager: store.modelManager)
                    Divider()
                    MicrophonePicker(diagnostics: store.diagnostics, disabled: store.diagnostics.running)
                    DiagnosticsPanel(diagnostics: store.diagnostics, allowed: store.canStart)
                    Text(tr("录音和逐字稿只保存在本机。术语可用逗号分隔，确认后会显示为独立标签。", "Recordings and transcripts stay on this Mac. Separate terms with commas to turn them into individual chips.")).font(.caption).foregroundStyle(.secondary)
                }.padding(24)
            }
            Divider()
            HStack {
                Text(tr("以后也可在设置中运行自检。", "You can run this check again in Settings.")).font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button(tr("完成，进入会议", "Done, open meetings")) { settings.update { $0.onboardingComplete = true }; dismiss() }.buttonStyle(.borderedProminent).disabled(store.diagnostics.running)
            }.padding(20)
        }.frame(width: 700, height: 710).tint(AppPalette.accent).preferredColorScheme(settings.colorScheme).environment(\.locale, settings.locale)
            .onAppear { store.diagnostics.refresh(); store.modelManager.refresh() }
    }
}
