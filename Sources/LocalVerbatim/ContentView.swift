import SwiftUI

private let ink = Color.primary
private let teal = AppPalette.accent
private let paper = AppPalette.paper

struct ContentView: View {
    @ObservedObject var store: MeetingStore
    @ObservedObject var engine: TranscriptionEngine
    @ObservedObject var capture: AudioCapture
    @ObservedObject private var settings = AppSettings.shared
    @State private var showRecognitionHints = false
    @State private var showTemplateSheet = false
    @State private var templateName = ""
    @State private var meetingToDelete: Meeting?
    @State private var notesVisitedForMeeting: String?
    @State private var showTranscriptVersions = false

    var body: some View {
        HStack(spacing: 0) {
            sidebar.frame(width: 228)
            Divider()
            VStack(spacing: 0) {
                header
                Divider().padding(.horizontal, 32)
                if let message = store.errorMessage {
                    HStack(alignment: .top, spacing: 10) {
                        Image(systemName: "exclamationmark.circle.fill").foregroundStyle(.orange)
                        Text(userFacingError(message)).font(.system(size: 12)).textSelection(.enabled)
                        Spacer()
                        Button(tr("检查设置", "Check settings")) { AppExperience.shared.openSettings() }.buttonStyle(.link)
                        Button { store.errorMessage = nil } label: {
                            Image(systemName: "xmark").frame(width: 22, height: 22).contentShape(Rectangle())
                        }.buttonStyle(.plain).accessibilityLabel(tr("关闭提示", "Dismiss message"))
                    }
                    .padding(14).background(Color.orange.opacity(0.09)).clipShape(RoundedRectangle(cornerRadius: 10))
                    .padding(.horizontal, 32).padding(.top, 16)
                }
                GeometryReader { geometry in
                    // Both panes remain mounted. Switching tabs changes visibility,
                    // preserving each scroll view's exact offset and note selection.
                    ZStack(alignment: .topLeading) {
                        readingPane(notes: false, viewportHeight: geometry.size.height)
                            .opacity(store.tab == "transcript" ? 1 : 0)
                            .allowsHitTesting(store.tab == "transcript")
                            .accessibilityHidden(store.tab != "transcript")
                        readingPane(notes: true, viewportHeight: geometry.size.height)
                            .opacity(store.tab == "notes" ? 1 : 0)
                            .allowsHitTesting(store.tab == "notes")
                            .accessibilityHidden(store.tab != "notes")
                    }
                }
                footer
            }
            .background(Color(nsColor: .textBackgroundColor))
        }
        .foregroundStyle(ink)
        .frame(minWidth: 980, minHeight: 710)
        .preferredColorScheme(settings.colorScheme)
        .environment(\.locale, settings.locale)
        .tint(teal)
        .onAppear { if store.selected?.status == "draft" { showRecognitionHints = true } }
        .onChange(of: store.selectedID) { _, _ in
            showRecognitionHints = store.selected?.status == "draft"
            showTranscriptVersions = false
        }
        .onChange(of: store.tab) { _, _ in showTranscriptVersions = false }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didResignActiveNotification)) { _ in
            showTranscriptVersions = false
        }
        .alert(tr("删除这场会议？", "Delete this meeting?"), isPresented: Binding(
            get: { meetingToDelete != nil }, set: { if !$0 { meetingToDelete = nil } }
        ), presenting: meetingToDelete) { meeting in
            Button(tr("删除会议及录音", "Delete meeting and audio"), role: .destructive) { store.deleteMeeting(meeting.id) }
            Button(tr("取消", "Cancel"), role: .cancel) {}
        } message: { meeting in
            Text(tr("“", "“") + meeting.title + tr("”的两条录音、全部逐字稿和笔记将一起移到系统废纸篓，可从废纸篓恢复。", "”: both audio tracks, all transcripts and notes will move to Trash, where they can be recovered."))
        }
        .sheet(isPresented: $store.showSettings) { SettingsView(store: store) }
        .sheet(isPresented: $store.showSetup) { SetupView(store: store) }
        .sheet(isPresented: $showTemplateSheet) {
            VStack(alignment: .leading, spacing: 18) {
                Text(tr("保存常用术语模板", "Save term template")).font(.headline)
                Text(tr("保存当前会议的术语和背景，之后可直接选用。", "Save the current terms and background for reuse."))
                    .font(.system(size: 12)).foregroundStyle(.secondary)
                TextField(tr("模板名称", "Template name"), text: $templateName).textFieldStyle(.roundedBorder)
                HStack {
                    Spacer()
                    Button(tr("取消", "Cancel")) { showTemplateSheet = false }
                    Button(tr("保存", "Save")) { store.saveCurrentAsTemplate(name: templateName); showTemplateSheet = false }
                        .buttonStyle(.borderedProminent)
                        .disabled(templateName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }.padding(24).frame(width: 380)
        }
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                Image(nsImage: AppBrand.icon).resizable().interpolation(.high)
                    .frame(width: 40, height: 40).accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 3) {
                    Text(AppIdentity.displayName).font(.system(size: 17, weight: .semibold))
                    Text(tr("本地会议笔记", "Local meeting notes")).font(.system(size: 11)).foregroundStyle(.secondary)
                }
            }.padding(.top, 36).padding(.horizontal, 20)
            Button { store.newMeeting() } label: {
                Label(tr("新建会议", "New meeting"), systemImage: "plus").font(.system(size: 13, weight: .medium)).frame(maxWidth: .infinity).padding(.vertical, 9)
            }
            .buttonStyle(.borderedProminent).disabled(!store.canStart)
            .padding(.horizontal, 20).padding(.top, 26)
            HStack {
                Image(systemName: "magnifyingglass").font(.system(size: 11))
                TextField(tr("搜索会议", "Search meetings"), text: $store.query).textFieldStyle(.plain).font(.system(size: 12))
            }.foregroundStyle(.secondary).padding(9).background(Color(nsColor: .textBackgroundColor)).clipShape(RoundedRectangle(cornerRadius: 7))
                .padding(.horizontal, 20).padding(.top, 18)
            Text(tr("会议记录", "Meetings")).font(.system(size: 10, weight: .semibold)).foregroundStyle(.secondary).padding(.horizontal, 23).padding(.top, 26).padding(.bottom, 10)
            ScrollView {
                LazyVStack(spacing: 5) {
                    ForEach(store.visibleMeetings) { meeting in
                        Button { store.select(meeting.id) } label: {
                            HStack(alignment: .top, spacing: 10) {
                                Image(systemName: meeting.id == store.recordingID ? "record.circle" : "doc.text")
                                    .foregroundStyle(meeting.id == store.recordingID ? .red : teal).padding(.top, 3)
                                VStack(alignment: .leading, spacing: 6) {
                                    Text(meeting.title).font(.system(size: 12, weight: .medium)).lineLimit(2).multilineTextAlignment(.leading)
                                    Text("\(formattedDate(meeting.created)) · \(clockText(meeting.duration))")
                                        .font(.system(size: 10)).foregroundStyle(.secondary)
                                }
                                Spacer(minLength: 0)
                            }
                            .padding(12).frame(maxWidth: .infinity, alignment: .leading)
                            .background(store.selectedID == meeting.id ? Color(nsColor: .textBackgroundColor) : Color.clear)
                            .clipShape(RoundedRectangle(cornerRadius: 8))
                            .contentShape(Rectangle())
                        }.buttonStyle(.plain)
                        .contextMenu {
                            Button(role: .destructive) { meetingToDelete = meeting } label: {
                                Label(tr("删除会议及录音…", "Delete meeting and audio…"), systemImage: "trash")
                            }.disabled(!store.canDeleteMeeting(meeting.id))
                        }
                    }
                }.padding(.horizontal, 12)
            }
            Spacer(minLength: 16)
            Button { AppExperience.shared.openSettings() } label: {
                Label(tr("设置", "Settings"), systemImage: "gearshape").frame(maxWidth: .infinity, alignment: .leading).padding(12)
                    .contentShape(Rectangle())
            }.buttonStyle(.plain).padding(.horizontal, 16).accessibilityLabel(tr("打开设置", "Open settings"))
            VStack(alignment: .leading, spacing: 8) {
                Label(tr("只在你的 Mac 上", "Only on your Mac"), systemImage: "lock.shield").font(.system(size: 12, weight: .medium)).foregroundStyle(teal)
                Text(tr("录音、逐字稿和笔记\n始终保存在本机。", "Audio, transcripts and notes\nstay on this Mac.")).font(.system(size: 11)).foregroundStyle(.secondary).lineSpacing(4)
                Button(tr("打开录音文件夹", "Open recordings folder")) { store.revealFolder() }.buttonStyle(.link).font(.system(size: 11))
            }.padding(17).frame(maxWidth: .infinity, alignment: .leading).background(teal.opacity(0.045)).clipShape(RoundedRectangle(cornerRadius: 10)).padding(16)
        }.background(paper)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Label(tr("我的会议", "My meetings"), systemImage: "square.stack").font(.system(size: 11)).foregroundStyle(.secondary)
                Spacer()
                Button { AppExperience.shared.openSettings() } label: {
                    Image(systemName: "gearshape").frame(width: 24, height: 24).contentShape(Rectangle())
                }.buttonStyle(.plain).help(tr("设置", "Settings"))
                Label(tr("本地处理 · 音频不上传", "Local processing · No audio uploads"), systemImage: "checkmark.shield.fill")
                    .font(.system(size: 11, weight: .medium)).foregroundStyle(teal)
                Menu {
                    Button(tr("导出为文本 (.txt)", "Export text (.txt)")) { store.export("txt") }
                    Button(tr("导出为 Markdown (.md)", "Export Markdown (.md)")) { store.export("md") }
                    Button(tr("导出为字幕 (.srt)", "Export subtitles (.srt)")) { store.export("srt") }
                    Divider()
                    Button(tr("复制逐字稿", "Copy transcript")) { store.copyTranscript() }
                    Button(tr("打开会议文件夹", "Open meeting folder")) { store.revealFolder() }
                } label: { Label(tr("导出", "Export"), systemImage: "square.and.arrow.up").font(.system(size: 12)) }
                .menuStyle(.borderlessButton).fixedSize().padding(.leading, 14)
                Button { meetingToDelete = store.selected } label: {
                    Label(tr("删除", "Delete"), systemImage: "trash").font(.system(size: 12))
                        .padding(.horizontal, 4).padding(.vertical, 5).contentShape(Rectangle())
                }.buttonStyle(.plain).foregroundStyle(.secondary).padding(.leading, 10)
                    .disabled(store.selectedID.map { !store.canDeleteMeeting($0) } ?? true)
                    .help(tr("删除当前会议及全部录音；录音结束后可用", "Delete the meeting and all audio; available after recording stops"))
            }
            TextField(tr("会议名称", "Meeting title"), text: Binding(get: { store.selected?.title ?? "" }, set: store.updateTitle))
                .textFieldStyle(.plain).font(.system(size: 29, weight: .semibold))
            HStack(spacing: 14) {
                Label(store.selected.map { formattedDate($0.created, time: true) } ?? "", systemImage: "calendar")
                Text("·")
                Label(tr("英语 / 普通话", "English / Mandarin"), systemImage: "globe")
            }.font(.system(size: 11)).foregroundStyle(.secondary)
        }.padding(.horizontal, 32).padding(.top, 36).padding(.bottom, 24)
    }

    private var recordingCard: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack(alignment: .center) {
                ZStack {
                    RoundedRectangle(cornerRadius: 14).fill(store.recording ? Color.red.opacity(0.07) : teal.opacity(0.07)).frame(width: 52, height: 52)
                    Image(systemName: store.recording ? "waveform" : "mic.and.signal.meter.fill")
                        .font(.system(size: 23)).foregroundStyle(store.recording ? .red : teal)
                }
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 8) {
                        Text(store.starting ? tr("正在准备录音", "Preparing recording") : store.stopping ? tr("正在保存录音", "Saving recording") : store.recording ? tr("正在录制会议", "Recording meeting") : store.selected?.status == "draft" ? tr("准备好，开始记录", "Ready when you are") : tr("会议录音已保存", "Meeting audio saved"))
                            .font(.system(size: 15, weight: .semibold))
                        if store.recording { Circle().fill(.red).frame(width: 6, height: 6) }
                    }
                    Text(store.recording ? tr("麦克风与电脑声音同步录制，文字稿持续更新", "Recording both sources; the transcript updates as you speak") : tr("同时收录你的发言与电脑中的与会者声音", "Capture your microphone and the participants playing on your computer"))
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                }
                Spacer()
                Text(clockText(store.recording ? store.elapsed : store.selected?.duration ?? 0))
                    .font(.system(size: 24, weight: .light, design: .monospaced)).foregroundStyle(store.recording ? ink : .secondary)
            }
            HStack(spacing: 18) {
                MeterView(title: tr("我的麦克风", "My microphone"), icon: "mic.fill", level: capture.micLevel, active: store.recording, color: teal)
                MeterView(title: tr("电脑声音", "System audio"), icon: "speaker.wave.2.fill", level: capture.systemLevel, active: store.recording, color: Color(red: 0.36, green: 0.43, blue: 0.70))
            }
            if let warning = capture.warning, store.recording {
                Label(userFacingError(warning), systemImage: "mic.badge.xmark")
                    .font(.system(size: 11)).foregroundStyle(.orange)
            }
            Divider().opacity(0.55)
            HStack(spacing: 10) {
                if store.recording {
                    Button { Task { await store.stopRecording() } } label: {
                        Label(store.stopping ? tr("正在保存…", "Saving…") : tr("结束录音", "Stop recording"), systemImage: "stop.fill")
                            .font(.system(size: 12, weight: .semibold)).padding(.horizontal, 12).padding(.vertical, 6)
                    }.buttonStyle(.borderedProminent).tint(.red).disabled(store.stopping)
                } else {
                    Button { Task { await store.startRecording() } } label: {
                        Label(store.starting ? tr("正在准备…", "Preparing…") : tr("开始录音", "Start recording"), systemImage: "record.circle")
                            .font(.system(size: 12, weight: .semibold)).padding(.horizontal, 12).padding(.vertical, 6)
                    }.buttonStyle(.borderedProminent).disabled(!store.canStart)
                }
                Picker(tr("语言", "Language"), selection: Binding(get: { store.selected?.language ?? "" }, set: store.updateLanguage)) {
                    Text(tr("自动 · 中英混合", "Auto · English & Mandarin")).tag("")
                    Text("English").tag("English")
                    Text(tr("普通话", "Mandarin")).tag("Chinese")
                }.labelsHidden().fixedSize(horizontal: true, vertical: false)
                    .frame(minWidth: 150, alignment: .leading).disabled(store.recording || store.starting)
                Spacer()
                if !store.recording && (store.selected?.duration ?? 0) > 0 {
                    Button { store.playing ? store.stopPlayback() : store.play() } label: {
                        Label(store.playing ? tr("停止回放", "Stop playback") : tr("回放录音", "Play recording"), systemImage: store.playing ? "stop.circle" : "play.circle")
                            .padding(4).contentShape(Rectangle())
                    }.buttonStyle(.plain).font(.system(size: 12)).foregroundStyle(teal)
                }
            }
            if store.starting {
                HStack { ProgressView().controlSize(.small); Text(tr("正在检查权限和设备…", "Checking permissions and devices…")).font(.caption); Spacer(); Button(tr("取消启动", "Cancel start")) { store.cancelStarting() } }
            }
            if !store.recording && store.selected?.status == "processing" {
                Label(tr("录音已保存，原稿仍在转写，可以离开此页面。", "Audio is saved. The original transcript is still processing; you can leave this page."), systemImage: "checkmark.shield").font(.caption).foregroundStyle(.secondary)
            }
            if store.diagnostics.running || store.migrating {
                Label(store.migrating ? tr("正在迁移文件，完成后可录音", "Migrating files; recording is available afterwards") : tr("正在收音自检，完成后可录音", "Audio check in progress; recording is available afterwards"), systemImage: "hourglass").font(.caption).foregroundStyle(.secondary)
            }
            LabeledControl(tr("常用术语模板", "Term template")) {
                HStack(spacing: 12) {
                    Picker(tr("常用术语模板", "Term template"), selection: Binding(get: { store.selected?.templateID ?? "" }, set: store.applyTemplate)) {
                        Text(tr("当前会议设置", "Current meeting settings")).tag("")
                        ForEach(store.preferences.templates) { template in Text(template.name).tag(template.id) }
                    }.frame(minWidth: 180, idealWidth: 260, maxWidth: 330, alignment: .leading)
                    Spacer(minLength: 8)
                    Button(tr("另存为模板", "Save as template")) { templateName = ""; showTemplateSheet = true }.buttonStyle(.link).fixedSize()
                    if let id = store.selected?.templateID, store.preferences.templates.contains(where: { $0.id == id }) {
                        Button(tr("更新此模板", "Update template")) { store.updateCurrentTemplate() }.buttonStyle(.link).fixedSize()
                    }
                }
            }.font(.system(size: 11))
            DisclosureGroup(isExpanded: $showRecognitionHints) {
                VStack(alignment: .leading, spacing: 10) {
                    TermTokenEditor(store: store)
                    TextField(tr("会议背景（选填），例如：讨论项目进度、预算和下一步安排", "Meeting background (optional), e.g. project progress, budget, and next steps"), text: Binding(
                        get: { store.selected?.recognitionContext ?? "" }, set: store.updateRecognitionContext), axis: .vertical)
                        .textFieldStyle(.roundedBorder).lineLimit(1...3)
                        .accessibilityLabel(tr("会议背景", "Meeting background"))
                    Text(store.selected?.status == "draft" && store.preferences.lastUsedHints != nil
                         ? tr("已沿用上一场会议的术语和背景，可在开始前修改。修改本场内容不会自动覆盖已保存的模板。", "Terms and background carry over from your last meeting. Edit them before recording; saved templates are only changed with Update Template.")
                         : tr("用于接下来提交的转写片段。修改本场内容不会自动覆盖已保存的模板；原稿保留。", "Used for upcoming transcription jobs. Editing this meeting does not overwrite saved templates or the original transcript."))
                        .font(.system(size: 10)).foregroundStyle(.secondary)
                }.padding(.top, 8)
            } label: {
                Label((store.selected?.vocabulary?.isEmpty ?? true) ? tr("会议术语与背景（选填）", "Terms & background (optional)") : tr("会议术语与背景 · 已设置", "Terms & background · Added"), systemImage: "text.book.closed")
                    .font(.system(size: 11)).foregroundStyle(teal)
            }.disclosureGroupStyle(FullRowDisclosureStyle())
            if store.selected?.status == "draft" || store.recordingID == store.selectedID {
                Toggle(tr("结束录音后自动二次识别，并保留原稿", "Automatically run a second pass after recording; keep the original"), isOn: Binding(
                    get: { store.selected?.autoRefineRequested == true }, set: store.updateAutoRefine))
                    .font(.system(size: 11)).disabled(store.starting)
            }
            if let run = store.selected?.refinement {
                VStack(alignment: .leading, spacing: 9) {
                    Label(refinementLabel(run), systemImage: run.state == "complete" ? "checkmark.circle" : "text.magnifyingglass")
                        .font(.system(size: 11)).foregroundStyle(run.state == "failed" ? .orange : teal)
                        .fixedSize(horizontal: false, vertical: true)
                    HStack(spacing: 18) {
                        if run.isActive {
                            Button(tr("停止二次识别", "Stop second pass")) { store.stopRefinement() }
                                .buttonStyle(.link)
                                .help(tr("保留原稿和已完成部分，之后可以继续。", "Keep the original and completed work. You can resume later."))
                        } else if run.state == "paused" {
                            Button(tr("继续二次识别", "Resume second pass")) { store.requestRefinement() }.buttonStyle(.link)
                                .disabled(!store.canRequestRefinement)
                        }
                        if run.state == "failed" {
                            Button(tr("重试二次识别", "Retry second pass")) { store.requestRefinement() }.buttonStyle(.link)
                                .disabled(!store.canRequestRefinement)
                        }
                        if !run.isActive {
                            Button(tr("重新二次识别", "Run second pass again")) { store.restartRefinement() }
                                .buttonStyle(.link).disabled(!store.canRestartRefinement)
                                .help(tr("从头使用当前语言、术语和背景识别，保留原稿和此前版本。", "Start over with the current language, terms and background; keep the original and previous versions."))
                        }
                    }.font(.system(size: 11)).fixedSize(horizontal: true, vertical: false)
                    if !run.isActive {
                        Text(["paused", "failed"].contains(run.state)
                             ? tr("继续或重试沿用上次设置；重新识别使用当前设置，并保留此前版本。", "Resume or retry keeps the previous settings. Run again uses current settings and keeps previous versions.")
                             : tr("重新识别使用当前语言、术语和背景，原稿和此前版本保留。", "Run again uses the current language, terms and background. The original and previous versions are kept."))
                            .font(.system(size: 10)).foregroundStyle(.secondary)
                    }
                    if ["queued", "running", "planning", "waiting"].contains(run.state) { ProgressView(value: run.fraction) }
                    if let error = run.error { Text(userFacingError(error)).font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(3) }
                }
            } else if !store.recording && (store.selected?.duration ?? 0) > 0 {
                Button(tr("用完整录音进行二次识别（保留原稿）", "Run a second pass from the full recording (keep original)")) { store.requestRefinement() }
                    .buttonStyle(.link).font(.system(size: 11)).disabled(!store.canRequestRefinement)
            }
        }.padding(22).background(paper.opacity(0.75)).clipShape(RoundedRectangle(cornerRadius: 16))
            .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(teal.opacity(0.10), lineWidth: 1))
    }

    private func readingPane(notes: Bool, viewportHeight: CGFloat) -> some View {
        ScrollViewReader { proxy in
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 24, pinnedViews: [.sectionHeaders]) {
                recordingCard.padding(.horizontal, 32).padding(.top, 24)
                Section {
                    if notes {
                        GrowingNotesEditor(text: Binding(get: { store.selected?.notes ?? "" }, set: store.updateNotes), textSize: settings.options.textSize, minimumHeight: max(240, viewportHeight - 100))
                            .background(paper.opacity(0.65), in: RoundedRectangle(cornerRadius: 10))
                            .padding(.horizontal, 32).padding(.bottom, 32)
                    } else {
                        transcriptBody.padding(.horizontal, 32).padding(.bottom, 32)
                    }
                } header: { readingHeader(notes: notes).id(notes ? "tabs-notes" : "tabs-transcript") }
            }
        }.id((store.selectedID ?? "") + (notes ? "-notes" : "-transcript"))
        .onChange(of: store.tab) { _, tab in
            if notes && tab == "notes" && notesVisitedForMeeting != store.selectedID {
                notesVisitedForMeeting = store.selectedID
                proxy.scrollTo("tabs-notes", anchor: .top)
            }
        }
        }
    }

    private func readingHeader(notes: Bool) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 22) {
                tabButton(tr("逐字稿", "Transcript"), id: "transcript", icon: "text.alignleft")
                tabButton(tr("我的笔记", "My notes"), id: "notes", icon: "square.and.pencil")
                Spacer()
                if engine.pendingCount > 0 {
                    ProgressView().controlSize(.small)
                    Text(String(engine.pendingCount) + tr(" 个片段待转写", " segments pending")).font(.system(size: 11)).foregroundStyle(.secondary)
                }
                if !(store.selected?.outstanding.isEmpty ?? true) {
                    Button(tr("继续转写", "Resume transcription")) { store.retrySelected() }.buttonStyle(.link).font(.system(size: 11))
                }
            }
            if !notes {
                HStack {
                    Toggle(readingRefinement ? tr("减少语气词与重复", "Reduce fillers & repetitions") : tr("减少语气词", "Reduce filler words"), isOn: settings.binding(\.reduceFillers))
                        .font(.system(size: 12))
                        .help(tr("二次稿还会合并明显的口头重复。取消勾选即可查看原文。", "Second-pass text also reduces obvious speech repetitions. Uncheck to show the original wording."))
                    Spacer()
                    Text(tr("即时切换，原文保留", "Instant switch · Original retained")).font(.system(size: 10)).foregroundStyle(.secondary)
                }
                if store.selected?.refinement != nil {
                    LabeledControl(tr("逐字稿版本", "Transcript version")) {
                        transcriptVersionPicker
                    }
                }
                Text(tr("复制和导出使用当前显示内容；录音和模型原文不变。", "Copy and export use the displayed text. Recordings and original model output are preserved."))
                    .font(.system(size: 10)).foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 32).padding(.top, 12).padding(.bottom, 12)
        .background(Color(nsColor: .textBackgroundColor))
        .overlay(alignment: .bottom) { Divider().padding(.horizontal, 32) }
    }

    @ViewBuilder
    private var transcriptVersionPicker: some View {
        let history = store.selected?.refinementHistory ?? []
        if history.isEmpty {
            Picker(tr("逐字稿版本", "Transcript version"), selection: $store.transcriptVersion) {
                Text(tr("原始逐字稿", "Original transcript")).tag("original")
                Text(tr("二次识别", "Second pass")).tag("refined")
            }.pickerStyle(.segmented).fixedSize(horizontal: true, vertical: false)
        } else {
            // Keep choices inside the window instead of creating an AppKit
            // tracking menu that can float above another application.
            VStack(alignment: .leading, spacing: 0) {
                Button { showTranscriptVersions.toggle() } label: {
                    HStack(spacing: 10) {
                        Text(transcriptVersionTitle(store.transcriptVersion)).frame(maxWidth: .infinity, alignment: .leading)
                        Image(systemName: showTranscriptVersions ? "chevron.up" : "chevron.down").accessibilityHidden(true)
                    }.padding(.horizontal, 11).frame(minHeight: 32).contentShape(Rectangle())
                }.buttonStyle(.plain)
                    .accessibilityLabel(tr("逐字稿版本：", "Transcript version: ") + transcriptVersionTitle(store.transcriptVersion))
                    .accessibilityValue(showTranscriptVersions ? tr("已展开", "Expanded") : tr("已收起", "Collapsed"))
                if showTranscriptVersions {
                    Divider().padding(.horizontal, 8)
                    ScrollView {
                        VStack(alignment: .leading, spacing: 0) {
                            transcriptVersionOption("original")
                            transcriptVersionOption("refined")
                            ForEach(history.reversed()) { run in transcriptVersionOption(Meeting.historyVersion(run)) }
                        }.padding(.vertical, 4)
                    }.frame(height: min(CGFloat(history.count + 2) * 36 + 8, 200))
                }
            }
            .font(.system(size: 12))
            .background(teal.opacity(0.045), in: RoundedRectangle(cornerRadius: 7))
            .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(teal.opacity(0.18), lineWidth: 1))
            .frame(minWidth: 280, idealWidth: 380, maxWidth: 540)
        }
    }

    private func transcriptVersionTitle(_ version: String) -> String {
        if version == "original" { return tr("原始逐字稿", "Original transcript") }
        if version == "refined" { return tr("二次识别", "Second pass") }
        let history = store.selected?.refinementHistory ?? []
        guard let index = history.firstIndex(where: { Meeting.historyVersion($0) == version }) else { return tr("原始逐字稿", "Original transcript") }
        let run = history[index]
        return tr("历史二次识别 ", "Previous pass ") + String(index + 1) + " · " + formattedDate(run.created, time: true)
            + (run.state == "complete" ? "" : tr(" · 未完成", " · Partial"))
    }

    private func transcriptVersionOption(_ version: String) -> some View {
        Button {
            store.transcriptVersion = version
            showTranscriptVersions = false
        } label: {
            HStack(spacing: 9) {
                Image(systemName: "checkmark").frame(width: 13)
                    .opacity(store.transcriptVersion == version ? 1 : 0).foregroundStyle(teal).accessibilityHidden(true)
                Text(transcriptVersionTitle(version)).frame(maxWidth: .infinity, alignment: .leading)
            }.padding(.horizontal, 11).frame(minHeight: 32).contentShape(Rectangle())
        }.buttonStyle(.plain)
            .accessibilityValue(store.transcriptVersion == version ? tr("已选择", "Selected") : "")
    }

    private var readingRefinement: Bool { store.selected?.refinementRun(version: store.transcriptVersion) != nil }

    private func displayText(_ text: String) -> String {
        store.selected?.displayText(text, version: store.transcriptVersion, reduceFillers: settings.options.reduceFillers) ?? text
    }

    private var transcriptBody: some View {
        VStack(alignment: .leading, spacing: 22) {
            if store.visibleSegments.isEmpty {
                VStack(spacing: 15) {
                    Image(systemName: "text.bubble").font(.system(size: 31, weight: .light)).foregroundStyle(teal.opacity(0.55))
                    Text(store.transcriptVersion != "original" ? tr("二次识别结果会显示在这里", "Second-pass results will appear here") : store.recording ? tr("正在聆听你的会议", "Listening to your meeting") : tr("让对话留下来", "Keep the conversation")).font(.system(size: 16, weight: .medium))
                    Text(store.recording ? tr("每约 18 秒转写一段语音。\n你可以一边开会，一边在这里记下想法。", "New text arrives about every 18 seconds.\nYou can take notes while the meeting continues.") : tr("开始录音后，中英文逐字稿会出现在这里。\n带时间戳，支持回放与导出。", "Start recording to see English and Mandarin transcripts.\nWith timestamps, playback and export."))
                        .font(.system(size: 12)).foregroundStyle(.secondary).multilineTextAlignment(.center).lineSpacing(6)
                    if !store.recording {
                        HStack(spacing: 16) {
                            Label(tr("麦克风 + 系统声音", "Microphone + System audio"), systemImage: "waveform")
                            Label(tr("无需会议机器人", "No meeting bot needed"), systemImage: "person.crop.circle.badge.checkmark")
                        }.font(.system(size: 10)).foregroundStyle(.secondary).padding(.top, 12)
                    }
                }.frame(maxWidth: .infinity).padding(.vertical, 34)
            } else {
                LazyVStack(alignment: .leading, spacing: 24) {
                    ForEach(store.visibleSegments) { segment in
                        HStack(alignment: .top, spacing: 13) {
                            Text(segment.source == "microphone" ? tr("我", "Me") : tr("会", "P")).font(.system(size: 11, weight: .semibold))
                                .frame(width: 30, height: 30).background(segment.source == "microphone" ? teal.opacity(0.09) : Color.indigo.opacity(0.07))
                                .foregroundStyle(segment.source == "microphone" ? teal : .indigo).clipShape(Circle())
                            VStack(alignment: .leading, spacing: 8) {
                                HStack {
                                    Text(segment.speaker).font(.system(size: 11, weight: .semibold))
                                    Button { store.play(at: segment.start) } label: {
                                        Text(clockText(segment.start)).padding(.horizontal, 3).padding(.vertical, 4).contentShape(Rectangle())
                                    }
                                        .buttonStyle(.plain).font(.system(size: 10, design: .monospaced)).foregroundStyle(.secondary)
                                        .disabled(store.recording)
                                }
                                Text(displayText(segment.text)).font(.system(size: settings.options.textSize)).lineSpacing(6).textSelection(.enabled)
                            }
                            Spacer(minLength: 0)
                        }.id(segment.id)
                    }
                }
            }
        }
    }

    private func refinementLabel(_ run: RefinementRun) -> String {
        switch run.state {
        case "waiting": return tr("等待原稿转写完成，再自动二次识别", "Waiting for the original transcript, then running a second pass")
        case "planning": return tr("正在准备二次识别 · 原稿已保留", "Preparing second pass · Original retained")
        case "queued", "running":
            if store.recording { return tr("录音优先，二次识别将在录音后继续", "Recording has priority; second pass resumes afterwards") }
            return tr("二次识别 ", "Second pass ") + "\(run.completedIDs.count) / \(run.chunks.count)" + tr(" · 原稿已保留", " · Original retained")
        case "complete": return tr("二次识别完成 · 原稿已保留", "Second pass complete · Original retained")
        case "paused":
            let progress = run.chunks.isEmpty ? "" : "\(run.completedIDs.count) / \(run.chunks.count) · "
            return tr("二次识别已停止 · ", "Second pass stopped · ") + progress + tr("原稿和进度已保留", "Original and progress retained")
        default: return tr("二次识别已停止 · 原稿与进度已保留", "Second pass stopped · Original and progress retained")
        }
    }

    private func tabButton(_ title: String, id: String, icon: String) -> some View {
        Button { NSApp.keyWindow?.makeFirstResponder(nil); store.tab = id } label: {
            VStack(spacing: 10) {
                Label(title, systemImage: icon).font(.system(size: 12, weight: store.tab == id ? .semibold : .regular))
                Rectangle().fill(store.tab == id ? teal : .clear).frame(height: 2)
            }.contentShape(Rectangle())
        }.buttonStyle(.plain).foregroundStyle(store.tab == id ? teal : .secondary).fixedSize()
    }

    private var footer: some View {
        HStack(spacing: 8) {
            Circle().fill(engine.ready ? teal : Color.secondary.opacity(0.5)).frame(width: 5, height: 5)
            Text(userFacingError(engine.state))
            Text("·").padding(.horizontal, 2)
            Text("Qwen3-ASR 1.7B")
            if engine.ready && engine.pendingCount == 0 && !store.recording {
                Button(tr("释放内存", "Unload model")) { engine.unload() }.buttonStyle(.link)
            } else if engine.state == "模型待命" && !store.recording && !store.starting {
                Button(store.modelManager.available ? tr("准备识别", "Load model") : tr("设置模型", "Set up model")) { if store.modelManager.available { engine.start() } else { store.showSetup = true } }.buttonStyle(.link)
            }
            Spacer()
            Text(engine.memoryGB > 0 ? String(format: tr("识别内存 %.2f / 10 GB", "Model memory %.2f / 10 GB"), engine.memoryGB) : tr("模型尚未占用内存", "Model is not loaded"))
                .monospacedDigit().help(tr("监测 macOS 物理内存占用，达到 8.5GB 提前停止转写并保留录音。", "Monitors model physical memory. At 8.5GB, transcription stops and recordings are retained."))
        }.font(.system(size: 10)).foregroundStyle(.secondary).padding(.horizontal, 32).padding(.vertical, 13).background(paper.opacity(0.5))
    }
}

/// Only the header owns the disclosure action; editing its contents never
/// toggles it. Include the label's spacer and padding in the button hit area.
private struct FullRowDisclosureStyle: DisclosureGroupStyle {
    func makeBody(configuration: Configuration) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Button { configuration.isExpanded.toggle() } label: {
                HStack(spacing: 6) {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 9, weight: .semibold))
                        .rotationEffect(.degrees(configuration.isExpanded ? 90 : 0))
                        .frame(width: 10, height: 12).foregroundStyle(.secondary)
                    configuration.label
                    Spacer(minLength: 0)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.vertical, 4).contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityValue(configuration.isExpanded ? tr("已展开", "Expanded") : tr("已收起", "Collapsed"))
            if configuration.isExpanded { configuration.content }
        }
    }
}

private struct MeterView: View {
    let title: String
    let icon: String
    let level: Double
    let active: Bool
    let color: Color
    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: icon).font(.system(size: 12)).foregroundStyle(color).frame(width: 16)
            Text(title).font(.system(size: 11)).foregroundStyle(.secondary)
            Spacer()
            HStack(spacing: 3) {
                ForEach(0..<15) { index in
                    RoundedRectangle(cornerRadius: 2).fill(active && Double(index) / 15 < level ? color : color.opacity(0.12))
                        .frame(width: 3, height: CGFloat(8 + (index % 4) * 3))
                }
            }
        }.padding(12).background(Color(nsColor: .textBackgroundColor)).clipShape(RoundedRectangle(cornerRadius: 8))
    }
}
