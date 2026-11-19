import AppKit
import AVFoundation
import Combine
import UniformTypeIdentifiers

@MainActor
final class MeetingStore: ObservableObject {
    @Published var meetings: [Meeting] = []
    @Published var selectedID: String?
    @Published var recordingID: String?
    @Published var elapsed: Double = 0
    @Published var starting = false
    @Published var stopping = false
    @Published var errorMessage: String?
    @Published var query = ""
    @Published var playing = false
    @Published var tab = "transcript"
    @Published var transcriptVersion = "original"
    @Published var preferences = MeetingPreferences()
    @Published var vocabularyDraft = ""
    @Published var vocabularyFeedback = ""
    @Published var showSettings = false
    @Published var showSetup = false
    @Published var migrating = false
    @Published var migrationMessage = ""
    @Published var libraryUnavailable = false
    var onRecordingStarted: (() -> Void)?
    var onRecordingStopped: (() -> Void)?
    var onTranscriptReady: (() -> Void)?
    let diagnostics = AudioDiagnostics()
    let modelManager = ModelManager()
    let capture = AudioCapture()
    let engine = TranscriptionEngine()
    private var timer: Timer?
    private var startTime: Date?
    private var activity: NSObjectProtocol?
    private var subscriptions: Set<AnyCancellable> = []
    private var players: [AVAudioPlayer] = []
    private var playbackTimer: Timer?
    private var startTask: Task<Void, Never>?
    private var stopTask: Task<Void, Never>?
    private var shuttingDown = false
    private var migrationTask: Task<Void, Never>?
    private var planningTasks: [String: Task<Void, Never>] = [:]
    private var planningAttempts: [String: UUID] = [:]
    private var pendingFolderRenames: Set<String> = []
    private var folderRenameTask: Task<Void, Never>?
    private var preferencesURL: URL { AppPaths.dataRoot.appendingPathComponent("preferences.json") }
    private let trashMeetingFolder: (URL) throws -> Void

    init(trashMeetingFolder: @escaping (URL) throws -> Void = { folder in
        try FileManager.default.trashItem(at: folder, resultingItemURL: nil)
    }) {
        self.trashMeetingFolder = trashMeetingFolder
        showSetup = !AppSettings.shared.options.onboardingComplete
        do { meetings = try readLibrary() }
        catch { libraryUnavailable = true; errorMessage = tr("无法读取会议目录：", "Cannot read the recording library: ") + error.localizedDescription }
        loadPreferences()
        selectedID = meetings.first?.id
        transcriptVersion = selected?.preferredTranscriptVersion ?? "original"
        if meetings.isEmpty && !libraryUnavailable { newMeeting() }
        engine.onResult = { [weak self] job, text, language in self?.accept(job, text: text, language: language) }
        engine.onError = { [weak self] message in self?.errorMessage = message }
        engine.onJobStarted = { [weak self] job in
            guard let self, let runID = job.refinementID,
                  let index = self.meetings.firstIndex(where: { $0.id == job.meetingID }), self.meetings[index].refinement?.id == runID,
                  self.meetings[index].refinement?.isActive == true else { return }
            self.meetings[index].refinement?.state = "running"
            self.persist(self.meetings[index])
        }
        engine.onJobFailure = { [weak self] job, message in
            guard let self, job.isRefinement,
                  self.meetings.first(where: { $0.id == job.meetingID })?.refinement?.id == job.refinementID else { return }
            self.failRefinement(job.meetingID, message: message)
        }
        engine.onFatalError = { [weak self] message in
            guard let self, !self.shuttingDown else { return }
            for meeting in self.meetings where ["queued", "running"].contains(meeting.refinement?.state ?? "") {
                self.failRefinement(meeting.id, message: message)
            }
        }
        capture.$error.compactMap { $0 }.sink { [weak self] message in self?.errorMessage = Self.captureMessage(message) }.store(in: &subscriptions)
        capture.$isRecording.dropFirst().sink { [weak self] running in
            guard let self, !running, self.recordingID != nil, !self.stopping, !self.starting else { return }
            Task { await self.stopRecording() }
        }.store(in: &subscriptions)
        modelManager.onReady = { [weak self] in guard let self, !self.shuttingDown else { return }; self.resumePendingWork(); self.engine.start() }
        diagnostics.objectWillChange.sink { [weak self] in self?.objectWillChange.send() }.store(in: &subscriptions)
        modelManager.objectWillChange.sink { [weak self] in self?.objectWillChange.send() }.store(in: &subscriptions)
        Task { @MainActor [weak self] in self?.resumePendingWork() }
        engine.$pendingCount.sink { [weak self] count in
            guard let self, count == 0 else { return }
            for index in self.meetings.indices where self.meetings[index].status == "processing" && self.meetings[index].outstanding.isEmpty {
                self.meetings[index].status = "complete"
                self.persist(self.meetings[index])
            }
            // @Published sends before its stored value changes. Defer until
            // the engine has actually become idle before moving queued paths.
            Task { @MainActor [weak self] in self?.organizePendingFolders() }
        }.store(in: &subscriptions)
    }

    private func readLibrary() throws -> [Meeting] {
        var loaded: [Meeting] = []
            if AppSettings.shared.options.recordingsPath != nil && !FileManager.default.fileExists(atPath: AppPaths.recordings.path) {
                throw NSError(domain: "LocalVerbatim.Storage", code: 1, userInfo: [NSLocalizedDescriptionKey: tr("录音库不可用，请连接存储设备或在设置中检查路径。", "The recording library is unavailable. Reconnect the drive or check Storage settings.")])
            }
            try FileManager.default.createDirectory(at: AppPaths.recordings, withIntermediateDirectories: true)
            let folders = try FileManager.default.contentsOfDirectory(at: AppPaths.recordings, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])
            for folder in folders {
                let file = MeetingFiles.readableMetadata(in: folder)
                guard let data = try? Data(contentsOf: file), var meeting = try? JSONDecoder().decode(Meeting.self, from: data) else { continue }
                meeting.directoryName = folder.lastPathComponent
                guard !loaded.contains(where: { $0.id == meeting.id }) else {
                    errorMessage = tr("发现重复会议 ID，未合并或覆盖文件。", "Duplicate meeting ID found; files were not merged or overwritten.")
                    continue
                }
                do { try MeetingFiles.organize(&meeting) }
                catch { errorMessage = tr("会议文件整理未完成，已有文件保留：", "Meeting file organization is incomplete; existing files are retained: ") + error.localizedDescription }
                if ["starting", "recording", "processing", "recovered"].contains(meeting.status) {
                    meeting.status = "recovered"
                    do { meeting = try RecordingRecovery.recover(meeting) }
                    catch { errorMessage = "恢复会议录音时出错：\(error.localizedDescription)" }
                }
                MeetingFiles.rebase(&meeting)
                if var run = meeting.refinement {
                    run.chunks = run.chunks.map { chunk in
                        AudioChunk(id: chunk.id, source: chunk.source, start: chunk.start, end: chunk.end,
                                   path: meeting.folder.appendingPathComponent("\(chunk.source).wav").path)
                    }
                    if ["planning", "queued", "running"].contains(run.state) { run.state = run.chunks.isEmpty ? "waiting" : "queued" }
                    meeting.refinement = run
                }
                try MeetingFiles.save(meeting)
                loaded.append(meeting)
            }
            return loaded.sorted { $0.created > $1.created }
    }

    func reloadLibrary() {
        guard !recording, !starting, !stopping, !migrating, engine.pendingCount == 0, planningTasks.isEmpty else { return }
        do {
            let loaded = try readLibrary()
            stopPlayback(); meetings = loaded; libraryUnavailable = false; errorMessage = nil
            if !meetings.contains(where: { $0.id == selectedID }) { selectedID = meetings.first?.id }
            if meetings.isEmpty { newMeeting() }
            resumePendingWork()
        } catch { libraryUnavailable = true; errorMessage = tr("无法读取会议目录：", "Cannot read the recording library: ") + error.localizedDescription }
    }

    var selected: Meeting? { meetings.first { $0.id == selectedID } }
    var visibleMeetings: [Meeting] { query.isEmpty ? meetings : meetings.filter { $0.title.localizedCaseInsensitiveContains(query) } }
    var recording: Bool { recordingID != nil }
    var canStart: Bool { !recording && !starting && !stopping && !shuttingDown && !migrating && !libraryUnavailable && !diagnostics.running }
    var visibleSegments: [TranscriptSegment] { selected?.ordered(version: transcriptVersion) ?? [] }

    func newMeeting() {
        guard !recording, !starting, !stopping, !migrating, !libraryUnavailable else { return }
        commitVocabularyDraft()
        stopPlayback()
        if let draft = meetings.first(where: { $0.status == "draft" }) { selectedID = draft.id; return }
        var meeting = Meeting()
        meeting.title = tr("会议 · ", "Meeting · ") + formattedDate(Date())
        meeting.language = AppSettings.shared.options.defaultLanguage
        if let hints = preferences.lastUsedHints {
            meeting.templateID = hints.templateID
            meeting.vocabulary = hints.vocabulary
            meeting.recognitionContext = hints.context
        }
        meeting.autoRefineRequested = AppSettings.shared.options.autoRefine
        MeetingFiles.assignNewFolder(&meeting)
        meetings.insert(meeting, at: 0)
        selectedID = meeting.id
        tab = "transcript"
        transcriptVersion = "original"
        persist(meeting)
    }

    func updateTitle(_ value: String) {
        updateSelected { $0.title = value }
        if let selected {
            if selected.status != "draft" { autoExport(selected) }
            pendingFolderRenames.insert(selected.id)
        }
        folderRenameTask?.cancel()
        folderRenameTask = Task { @MainActor [weak self] in
            do { try await Task.sleep(nanoseconds: 700_000_000) } catch { return }
            self?.organizePendingFolders()
        }
    }
    private func organizePendingFolders() {
        guard !recording, !starting, !stopping, !migrating, !libraryUnavailable,
              engine.pendingCount == 0, planningTasks.isEmpty, !diagnostics.running else { return }
        for id in Array(pendingFolderRenames) {
            guard let index = meetings.firstIndex(where: { $0.id == id }) else { pendingFolderRenames.remove(id); continue }
            do {
                stopPlayback()
                try MeetingFiles.organize(&meetings[index])
                guard persist(meetings[index]) else { continue }
                pendingFolderRenames.remove(id)
            } catch { errorMessage = tr("会议文件夹暂未更名，文件仍保留：", "Meeting folder rename is pending; files are retained: ") + error.localizedDescription }
        }
    }
    func updateNotes(_ value: String) { updateSelected { $0.notes = value }; if let selected, selected.status != "draft" { autoExport(selected) } }
    func updateLanguage(_ value: String) { updateSelected { $0.language = value } }
    func updateVocabulary(_ value: String) { updateSelected { $0.vocabulary = String(value.prefix(2000)) }; rememberEditedHints() }
    func updateRecognitionContext(_ value: String) { updateSelected { $0.recognitionContext = String(value.prefix(1000)) }; rememberEditedHints() }
    func updateAutoRefine(_ value: Bool) { updateSelected { $0.autoRefineRequested = value } }

    private func updateSelected(_ body: (inout Meeting) -> Void) {
        guard let index = meetings.firstIndex(where: { $0.id == selectedID }) else { return }
        body(&meetings[index])
        persist(meetings[index])
    }

    func select(_ id: String) {
        commitVocabularyDraft()
        vocabularyFeedback = ""
        stopPlayback()
        selectedID = id
        tab = "transcript"
        transcriptVersion = selected?.preferredTranscriptVersion ?? "original"
    }

    func canDeleteMeeting(_ id: String) -> Bool {
        !starting && !stopping && !shuttingDown && !migrating && recordingID != id && meetings.contains { $0.id == id }
    }

    func deleteMeeting(_ id: String) {
        guard canDeleteMeeting(id), let index = meetings.firstIndex(where: { $0.id == id }) else { return }
        let meeting = meetings[index]
        // Move the entire folder, including both archives, live chunks, both
        // transcripts, notes and refinement results. Never delete only the row.
        guard meeting.folder.standardizedFileURL.deletingLastPathComponent() == AppPaths.recordings.standardizedFileURL else {
            errorMessage = "会议目录不正确，未删除任何文件。"
            return
        }
        stopPlayback()
        do { try trashMeetingFolder(meeting.folder) }
        catch {
            errorMessage = "无法将会议和录音移到废纸篓，会议仍保留：\(error.localizedDescription)"
            return
        }
        // No suspension points: remove the manifest from memory before queue
        // notifications or late inference/planning callbacks can persist it.
        meetings.remove(at: index)
        planningAttempts.removeValue(forKey: id)
        planningTasks.removeValue(forKey: id)?.cancel()
        engine.cancelMeeting(id)
        if preferences.lastMeetingID == id {
            preferences.lastMeetingID = nil
            persistPreferences() // Keep reusable templates and last-used hints.
        }
        if selectedID == id {
            if meetings.isEmpty {
                selectedID = nil
                query = ""
                newMeeting()
            } else {
                if visibleMeetings.isEmpty { query = "" }
                select(visibleMeetings.first?.id ?? meetings[0].id)
            }
        }
    }

    func startRecording() async {
        if let startTask { await startTask.value; return }
        guard canStart else { return }
        let task = Task<Void, Never> { [weak self] in
            guard let self else { return }
            await self.performStartRecording()
        }
        startTask = task
        await task.value
        startTask = nil
    }

    private func performStartRecording() async {
        guard canStart else { return }
        commitVocabularyDraft()
        if selected?.status != "draft" { newMeeting() }
        guard let meeting = selected, let index = meetings.firstIndex(where: { $0.id == meeting.id }) else { return }
        starting = true
        engine.setRefinementsPaused(true)
        errorMessage = nil
        elapsed = 0
        stopPlayback()
        do {
            if AppSettings.shared.options.recordingsPath != nil && !FileManager.default.fileExists(atPath: AppPaths.recordings.path) {
                throw NSError(domain: "LocalVerbatim.Storage", code: 1, userInfo: [NSLocalizedDescriptionKey: tr("录音库不可用，请检查存储设备。", "The recording library is unavailable. Check the storage device.")])
            }
            try StorageMigration.checkWritable(AppPaths.recordings)
            try FileManager.default.createDirectory(at: meeting.folder, withIntermediateDirectories: true)
            meetings[index].status = "starting"
            persist(meetings[index])
            try await capture.start(directory: meeting.folder, microphoneID: AppSettings.shared.options.microphoneID) { [weak self] chunk in
                self?.receivedChunk(chunk, meetingID: meeting.id)
            }
            recordingID = meeting.id
            startTime = Date()
            meetings[index].status = "recording"
            rememberHints(meetings[index])
            persist(meetings[index])
            activity = ProcessInfo.processInfo.beginActivity(options: [.userInitiated, .idleSystemSleepDisabled], reason: "保存会议录音")
            timer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
                Task { @MainActor in
                    guard let self, let startTime = self.startTime else { return }
                    self.elapsed = Date().timeIntervalSince(startTime)
                }
            }
            onRecordingStarted?()
            if !shuttingDown && modelManager.available { engine.start() }
        } catch {
            errorMessage = error is CancellationError ? nil : Self.captureMessage(error.localizedDescription)
            let containsAudio = ["microphone", "system"].contains {
                FileManager.default.fileExists(atPath: meeting.folder.appendingPathComponent("\($0).wav").path)
            }
            meetings[index].status = containsAudio ? "recovered" : "draft"
            persist(meetings[index])
            engine.setRefinementsPaused(false)
        }
        starting = false
    }

    func stopRecording() async {
        if let stopTask { await stopTask.value; return }
        if let startTask { await startTask.value }
        if let stopTask { await stopTask.value; return }
        guard recordingID != nil else { return }
        let task = Task<Void, Never> { [weak self] in
            guard let self else { return }
            await self.performStopRecording()
        }
        stopTask = task
        await task.value
        stopTask = nil
    }

    private func performStopRecording() async {
        guard let id = recordingID else { return }
        stopping = true
        await capture.stop()
        timer?.invalidate()
        timer = nil
        if let index = meetings.firstIndex(where: { $0.id == id }) {
            meetings[index].duration = max(elapsed, meetings[index].chunks.map(\.end).max() ?? 0)
            for source in ["microphone", "system"] {
                let file = meetings[index].folder.appendingPathComponent("\(source).wav")
                if let attributes = try? FileManager.default.attributesOfItem(atPath: file.path),
                   let bytes = attributes[.size] as? NSNumber {
                    meetings[index].duration = max(meetings[index].duration, Double(max(0, bytes.int64Value - 44)) / 32_000)
                }
            }
            meetings[index].status = meetings[index].outstanding.isEmpty ? "complete" : "processing"
            meetings[index].peakMemoryGB = engine.peakGB
            rememberHints(meetings[index])
            if meetings[index].autoRefineRequested == true && meetings[index].refinement == nil {
                meetings[index].refinement = makeRun(meetings[index])
            }
            persist(meetings[index])
            autoExport(meetings[index])
        }
        if let activity { ProcessInfo.processInfo.endActivity(activity) }
        activity = nil
        recordingID = nil
        startTime = nil
        stopping = false
        organizePendingFolders()
        onRecordingStopped?()
        if !shuttingDown {
            engine.setRefinementsPaused(false)
            kickRefinements()
        }
    }

    private func receivedChunk(_ chunk: AudioChunk, meetingID: String) {
        guard let index = meetings.firstIndex(where: { $0.id == meetingID }) else { return }
        meetings[index].chunks.append(chunk)
        meetings[index].duration = max(meetings[index].duration, chunk.end)
        persist(meetings[index]) // Commit job to disk BEFORE sending it to ASR.
        engine.enqueue([TranscriptionJob(meetingID: meetingID, chunk: chunk, language: meetings[index].language,
                                         vocabulary: meetings[index].vocabulary ?? "", context: meetings[index].recognitionContext ?? "")])
    }

    private func accept(_ job: TranscriptionJob, text: String, language: String) {
        if job.isRefinement { acceptRefinement(job, text: text, language: language); return }
        guard let index = meetings.firstIndex(where: { $0.id == job.meetingID }), !meetings[index].completedIDs.contains(job.chunk.id) else { return }
        let meeting = meetings[index]
        let raw: [String: Any] = ["id": job.chunk.id, "text": text, "language": language,
                                  "start": job.chunk.start, "end": job.chunk.end, "source": job.chunk.source]
        if let data = try? JSONSerialization.data(withJSONObject: raw, options: [.prettyPrinted, .sortedKeys]) {
            do {
                try FileManager.default.createDirectory(at: MeetingFiles.results(in: meeting.folder), withIntermediateDirectories: true)
                try data.write(to: MeetingFiles.results(in: meeting.folder).appendingPathComponent("\(job.chunk.id).result.json"), options: .atomic)
            }
            catch { errorMessage = "无法保存转写原文：\(error.localizedDescription)"; return }
        }
        let previous = meeting.ordered.last { $0.source == job.chunk.source && $0.start <= job.chunk.start }
        let clean = trimOverlap(previous: previous, chunk: job.chunk, text: text).trimmingCharacters(in: .whitespacesAndNewlines)
        if !clean.isEmpty {
            meetings[index].segments.append(TranscriptSegment(id: job.chunk.id, source: job.chunk.source,
                                                              start: job.chunk.start, end: job.chunk.end,
                                                              text: clean, language: language))
        }
        meetings[index].completedIDs.append(job.chunk.id)
        meetings[index].peakMemoryGB = max(meetings[index].peakMemoryGB ?? 0, engine.peakGB)
        if meetings[index].status != "recording" && meetings[index].outstanding.isEmpty { meetings[index].status = "complete" }
        persist(meetings[index])
        autoExport(meetings[index])
        if meetings[index].status == "complete" && meetings[index].refinement == nil && meetings[index].autoRefineRequested != true { onTranscriptReady?() }
        kickRefinements()
    }

    func retrySelected() {
        guard var meeting = selected else { return }
        errorMessage = nil
        if meeting.id != recordingID {
            do {
                meeting = try RecordingRecovery.recover(meeting)
                if let index = meetings.firstIndex(where: { $0.id == meeting.id }) { meetings[index] = meeting }
                persist(meeting)
            } catch { errorMessage = "无法恢复待转写音频：\(error.localizedDescription)"; return }
        }
        engine.start()
        engine.enqueue(meeting.outstanding.map { TranscriptionJob(meetingID: meeting.id, chunk: $0, language: meeting.language,
                                                                  vocabulary: meeting.vocabulary ?? "", context: meeting.recognitionContext ?? "") })
    }

    @discardableResult
    func persist(_ meeting: Meeting) -> Bool {
        guard !libraryUnavailable else { return false }
        do {
            try MeetingFiles.save(meeting)
            return true
        } catch { errorMessage = "会议保存失败：\(error.localizedDescription)"; return false }
    }

    private func autoExport(_ meeting: Meeting) {
        do {
            try FileManager.default.createDirectory(at: MeetingFiles.transcripts(in: meeting.folder), withIntermediateDirectories: true)
            for ext in ["txt", "md", "srt"] {
                try meeting.exportText(format: ext).write(to: MeetingFiles.transcript(in: meeting.folder, format: ext), atomically: true, encoding: .utf8)
                if let run = meeting.refinement, !run.segments.isEmpty || run.state == "complete" {
                    try meeting.exportText(format: ext, version: "refined").write(to: MeetingFiles.transcript(in: meeting.folder, format: ext, refined: true), atomically: true, encoding: .utf8)
                }
            }
        } catch { errorMessage = "导出失败：\(error.localizedDescription)" }
    }

    func export(_ format: String) {
        guard let meeting = selected else { return }
        let panel = NSSavePanel()
        let historyNumber = meeting.refinementHistory?.firstIndex { Meeting.historyVersion($0) == transcriptVersion }.map { "-\($0 + 1)" } ?? ""
        let suffix = (meeting.refinementRun(version: transcriptVersion) != nil ? tr("-二次识别", "-second-pass") + historyNumber : tr("-原稿", "-original")) + (AppSettings.shared.options.reduceFillers ? tr("-减少语气词", "-fewer-fillers") : "")
        panel.nameFieldStringValue = "\(meeting.title.replacingOccurrences(of: "/", with: "-"))\(suffix).\(format)"
        panel.allowedContentTypes = [UTType(filenameExtension: format) ?? .plainText]
        if panel.runModal() == .OK, let url = panel.url {
            do { try meeting.exportText(format: format, version: transcriptVersion, reduceFillers: AppSettings.shared.options.reduceFillers).write(to: url, atomically: true, encoding: .utf8) }
            catch { errorMessage = error.localizedDescription }
        }
    }

    func copyTranscript() {
        guard let selected else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(selected.exportText(format: "txt", version: transcriptVersion, reduceFillers: AppSettings.shared.options.reduceFillers), forType: .string)
    }

    func revealFolder() {
        organizePendingFolders()
        NSWorkspace.shared.open(selected?.folder ?? AppPaths.recordings)
    }

    func play(at seconds: Double = 0) {
        guard let meeting = selected, meeting.id != recordingID else { return }
        stopPlayback()
        for source in ["microphone", "system"] {
            let url = meeting.folder.appendingPathComponent("\(source).wav")
            if let player = try? AVAudioPlayer(contentsOf: url), player.duration > seconds {
                player.currentTime = seconds
                player.prepareToPlay()
                players.append(player)
            }
        }
        guard let first = players.first else { errorMessage = "尚无可播放的录音。"; return }
        let start = first.deviceCurrentTime + 0.08
        players.forEach { $0.play(atTime: start) }
        playing = true
        playbackTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                if !self.players.contains(where: \.isPlaying) { self.stopPlayback() }
            }
        }
    }

    func stopPlayback() {
        players.forEach { $0.stop() }
        players.removeAll()
        playbackTimer?.invalidate()
        playbackTimer = nil
        playing = false
    }

    private func loadPreferences() {
        if let data = try? Data(contentsOf: preferencesURL) {
            do { preferences = try JSONDecoder().decode(MeetingPreferences.self, from: data) }
            catch {
                try? data.write(to: preferencesURL.deletingLastPathComponent().appendingPathComponent("preferences-backup-\(UUID().uuidString).json"), options: .withoutOverwriting)
                errorMessage = "模板设置读取失败，已保留原文件副本。"
            }
        }
        if preferences.lastUsedHints == nil,
           let recent = meetings.first(where: { $0.status != "draft" && !$0.chunks.isEmpty }) {
            var hints = recent.hints
            if !hints.vocabulary.isEmpty || !hints.context.isEmpty {
                let template = TermTemplate(name: tr("上次会议", "Last meeting"), vocabulary: hints.vocabulary, context: hints.context)
                preferences.templates.append(template)
                hints.templateID = template.id
            }
            preferences.lastMeetingID = recent.id
            preferences.lastUsedHints = hints
            persistPreferences()
        }
    }

    private func persistPreferences() {
        do {
            let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(preferences).write(to: preferencesURL, options: .atomic)
        } catch { errorMessage = "无法保存术语模板：\(error.localizedDescription)" }
    }

    private func rememberHints(_ meeting: Meeting) {
        preferences.lastMeetingID = meeting.id
        preferences.lastUsedHints = meeting.hints
        persistPreferences()
    }

    private func rememberEditedHints() {
        if let selected, preferences.lastMeetingID == selected.id { rememberHints(selected) }
    }

    func applyTemplate(_ id: String) {
        vocabularyDraft = ""; vocabularyFeedback = ""
        if id.isEmpty { updateSelected { $0.templateID = nil }; return }
        guard let template = preferences.templates.first(where: { $0.id == id }) else { return }
        updateSelected {
            $0.templateID = template.id; $0.vocabulary = template.vocabulary; $0.recognitionContext = template.context
        }
        rememberEditedHints()
    }

    func saveCurrentAsTemplate(name: String) {
        commitVocabularyDraft()
        guard let meeting = selected else { return }
        let base = String(name.trimmingCharacters(in: .whitespacesAndNewlines).prefix(60))
        guard !base.isEmpty else { return }
        var name = base, number = 2
        while preferences.templates.contains(where: { $0.name == name }) { name = "\(base)（\(number)）"; number += 1 }
        let template = TermTemplate(name: name, vocabulary: meeting.vocabulary ?? "", context: meeting.recognitionContext ?? "")
        preferences.templates.append(template)
        updateSelected { $0.templateID = template.id }
        persistPreferences(); rememberEditedHints()
    }

    func updateCurrentTemplate() {
        commitVocabularyDraft()
        guard let meeting = selected, let id = meeting.templateID,
              let index = preferences.templates.firstIndex(where: { $0.id == id }) else { return }
        preferences.templates[index].vocabulary = meeting.vocabulary ?? ""
        preferences.templates[index].context = meeting.recognitionContext ?? ""
        persistPreferences(); rememberEditedHints()
    }

    private func makeRun(_ meeting: Meeting) -> RefinementRun {
        var run = RefinementRun()
        run.language = meeting.language
        run.vocabulary = meeting.vocabulary ?? ""
        run.context = meeting.recognitionContext ?? ""
        return run
    }

    var canRequestRefinement: Bool {
        guard !starting, !stopping, !shuttingDown, !migrating, !libraryUnavailable, !diagnostics.running,
              let meeting = selected, meeting.id != recordingID else { return false }
        return meeting.status != "draft" && meeting.duration > 0
    }

    var canRestartRefinement: Bool {
        canRequestRefinement && selected?.refinement?.isActive == false
    }

    func requestRefinement() {
        guard canRequestRefinement else { return }
        if selected?.refinement?.state == "complete" { restartRefinement(); return }
        guard selected?.refinement?.isActive != true else { return }
        commitVocabularyDraft()
        guard let index = meetings.firstIndex(where: { $0.id == selectedID }) else { return }
        var candidate = meetings[index]
        if candidate.refinement == nil { candidate.refinement = makeRun(candidate) }
        else if ["failed", "paused"].contains(candidate.refinement?.state ?? "") {
            // Resume keeps the original hint snapshot, so completed and
            // remaining ranges belong to the same recognition run.
            let resumeState = candidate.refinement?.chunks.isEmpty == true ? "waiting" : "queued"
            candidate.refinement?.state = resumeState
            candidate.refinement?.error = nil
        } else { return }
        guard persist(candidate) else { return }
        meetings[index] = candidate
        errorMessage = nil
        if !candidate.outstanding.isEmpty { retrySelected() }
        kickRefinements()
    }

    func restartRefinement() {
        guard canRestartRefinement else { return }
        commitVocabularyDraft()
        guard let index = meetings.firstIndex(where: { $0.id == selectedID }), let previous = meetings[index].refinement else { return }
        var candidate = meetings[index]
        var history = candidate.refinementHistory ?? []
        if !history.contains(where: { $0.id == previous.id }) { history.append(previous) }
        candidate.refinementHistory = history
        candidate.refinement = makeRun(candidate) // Current language, terms and background; new run identity.
        // One atomic manifest replacement preserves the previous run before
        // any new job is queued. A failed save leaves the old run selected.
        guard persist(candidate) else { return }
        meetings[index] = candidate
        errorMessage = nil
        transcriptVersion = candidate.preferredTranscriptVersion
        if !candidate.outstanding.isEmpty { retrySelected() }
        kickRefinements()
    }

    func stopRefinement() {
        guard let id = selectedID, let index = meetings.firstIndex(where: { $0.id == id }),
              let run = meetings[index].refinement, run.isActive else { return }
        // Persist an explicit user stop, distinct from an interrupted app exit.
        // Do not cancel live transcription or work belonging to other meetings.
        meetings[index].refinement?.state = "paused"
        meetings[index].refinement?.error = nil
        planningAttempts.removeValue(forKey: id)
        planningTasks.removeValue(forKey: id)?.cancel()
        engine.cancelRefinement(meetingID: id, runID: run.id, interruptActive: true)
        persist(meetings[index])
    }

    private func resumePendingWork() {
        guard !shuttingDown, !libraryUnavailable, modelManager.available else { return }
        var originalJobs: [TranscriptionJob] = []
        for index in meetings.indices {
            let meeting = meetings[index]
            guard !["draft", "starting", "recording"].contains(meeting.status), meeting.autoRefineRequested == true || meeting.refinement != nil else { continue }
            if meeting.refinement == nil { meetings[index].refinement = makeRun(meeting) }
            if !meeting.outstanding.isEmpty && meetings[index].refinement?.state != "failed" {
                originalJobs += meeting.outstanding.map { TranscriptionJob(meetingID: meeting.id, chunk: $0, language: meeting.language,
                    vocabulary: meeting.vocabulary ?? "", context: meeting.recognitionContext ?? "") }
            }
            persist(meetings[index])
        }
        if !originalJobs.isEmpty { engine.enqueue(originalJobs); engine.start() }
        kickRefinements()
    }

    private func kickRefinements() {
        guard !shuttingDown, !recording, !starting, !stopping else { return }
        for meeting in meetings {
            guard meeting.outstanding.isEmpty, let run = meeting.refinement else { continue }
            if run.state == "waiting", planningTasks[meeting.id] == nil { planRefinement(meetingID: meeting.id, runID: run.id) }
            else if ["queued", "running"].contains(run.state) { enqueueRefinement(meeting.id) }
        }
    }

    private func planRefinement(meetingID: String, runID: String) {
        guard let index = meetings.firstIndex(where: { $0.id == meetingID }), meetings[index].refinement?.id == runID else { return }
        let folder = meetings[index].folder
        do {
            let snapshot = MeetingFiles.snapshot(in: folder)
            if !FileManager.default.fileExists(atPath: snapshot.path) {
                try JSONEncoder().encode(meetings[index].segments).write(to: snapshot, options: .withoutOverwriting)
            }
            let runFolder = MeetingFiles.refinement(in: folder, runID: runID)
            try FileManager.default.createDirectory(at: runFolder, withIntermediateDirectories: true)
        } catch { failRefinement(meetingID, message: error.localizedDescription); return }
        meetings[index].refinement?.state = "planning"
        guard persist(meetings[index]) else { return }
        let attempt = UUID()
        planningAttempts[meetingID] = attempt
        planningTasks[meetingID] = Task { @MainActor [weak self] in
            do {
                let planning = Task.detached(priority: .utility) { try RefinementPlanner.plan(folder: folder) }
                let chunks = try await withTaskCancellationHandler(operation: { try await planning.value }, onCancel: { planning.cancel() })
                try Task.checkCancellation()
                guard let self, let index = self.meetings.firstIndex(where: { $0.id == meetingID }),
                      self.meetings[index].refinement?.id == runID,
                      self.planningAttempts[meetingID] == attempt,
                      self.meetings[index].refinement?.state == "planning" else { return }
                self.planningTasks[meetingID] = nil
                self.planningAttempts[meetingID] = nil
                self.meetings[index].refinement?.chunks = chunks
                self.meetings[index].refinement?.state = chunks.isEmpty ? "complete" : "queued"
                if chunks.isEmpty { self.meetings[index].refinement?.finished = Date() }
                guard self.persist(self.meetings[index]) else { return }
                self.autoExport(self.meetings[index])
                if !self.shuttingDown && !self.recording && !self.starting { self.enqueueRefinement(meetingID) }
            } catch {
                guard let self, self.planningAttempts[meetingID] == attempt else { return }
                self.planningTasks[meetingID] = nil
                self.planningAttempts[meetingID] = nil
                if !(error is CancellationError) { self.failRefinement(meetingID, message: error.localizedDescription) }
            }
        }
    }

    private func enqueueRefinement(_ meetingID: String) {
        guard !shuttingDown, !recording, !starting, let meeting = meetings.first(where: { $0.id == meetingID }),
              let run = meeting.refinement, ["queued", "running"].contains(run.state), !run.outstanding.isEmpty else { return }
        let jobs = run.outstanding.map { TranscriptionJob(meetingID: meetingID, chunk: $0, language: run.language,
            vocabulary: run.vocabulary, context: run.context, refinementID: run.id) }
        engine.enqueue(jobs)
        engine.start()
    }

    private func acceptRefinement(_ job: TranscriptionJob, text: String, language: String) {
        guard let index = meetings.firstIndex(where: { $0.id == job.meetingID }),
              var run = meetings[index].refinement, run.id == job.refinementID,
              ["queued", "running"].contains(run.state), !run.completedIDs.contains(job.chunk.id) else { return }
        let raw: [String: Any] = ["id": job.chunk.id, "source": job.chunk.source, "start": job.chunk.start,
                                  "end": job.chunk.end, "text": text, "language": language]
        do {
            let folder = MeetingFiles.refinement(in: meetings[index].folder, runID: run.id)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try JSONSerialization.data(withJSONObject: raw, options: [.prettyPrinted, .sortedKeys])
                .write(to: folder.appendingPathComponent("\(job.chunk.id).result.json"), options: .atomic)
        } catch { failRefinement(job.meetingID, message: error.localizedDescription); return }
        let previous = run.segments.filter { $0.source == job.chunk.source && $0.start <= job.chunk.start }.max { $0.start < $1.start }
        let clean = trimOverlap(previous: previous, chunk: job.chunk, text: text).trimmingCharacters(in: .whitespacesAndNewlines)
        if !clean.isEmpty { run.segments.append(TranscriptSegment(id: job.chunk.id, source: job.chunk.source,
            start: job.chunk.start, end: job.chunk.end, text: clean, language: language)) }
        run.completedIDs.append(job.chunk.id)
        if run.outstanding.isEmpty { run.state = "complete"; run.finished = Date() }
        meetings[index].refinement = run
        meetings[index].peakMemoryGB = max(meetings[index].peakMemoryGB ?? 0, engine.peakGB)
        guard persist(meetings[index]) else { failRefinement(job.meetingID, message: "保存二次识别进度失败"); return }
        autoExport(meetings[index])
        if run.state == "complete" {
            onTranscriptReady?()
            if selectedID == job.meetingID { transcriptVersion = "refined" }
        }
    }

    private func failRefinement(_ id: String, message: String) {
        guard let index = meetings.firstIndex(where: { $0.id == id }), let run = meetings[index].refinement, run.isActive else { return }
        meetings[index].refinement?.state = "failed"
        meetings[index].refinement?.error = message
        if selectedID == id { transcriptVersion = meetings[index].preferredTranscriptVersion }
        engine.cancelRefinement(meetingID: id, runID: run.id)
        persist(meetings[index])
        errorMessage = "二次识别已停止，原稿和录音已保留：\(message)"
    }

    func cancelStarting() {
        guard starting else { return }
        startTask?.cancel()
        capture.cancelPendingStart()
    }

    func setVocabularyDraft(_ value: String) {
        vocabularyDraft = value
        guard let last = value.rangeOfCharacter(from: Vocabulary.separators, options: .backwards) else { return }
        appendVocabulary(String(value[..<last.upperBound]))
        vocabularyDraft = String(value[last.upperBound...])
    }

    func commitVocabularyDraft() {
        guard !vocabularyDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { vocabularyDraft = ""; return }
        let value = vocabularyDraft; vocabularyDraft = ""
        appendVocabulary(value)
    }

    private func appendVocabulary(_ input: String) {
        guard selected != nil else { return }
        let result = Vocabulary.adding(input, to: Vocabulary.terms(selected?.vocabulary ?? ""))
        updateVocabulary(result.terms.joined(separator: ", "))
        var messages: [String] = []
        if result.added > 0 { messages.append(tr("已添加 ", "Added ") + String(result.added) + tr(" 个术语", " term(s)")) }
        if result.duplicates > 0 { messages.append(tr("重复术语已跳过", "Duplicate terms skipped")) }
        if result.rejected > 0 { messages.append(tr("超出限制：最多40个术语，每个80字，总计2000字", "Limit reached: 40 terms, 80 characters per term, 2,000 total")) }
        vocabularyFeedback = messages.joined(separator: " · ")
    }

    func removeVocabularyTerm(_ term: String) {
        updateVocabulary(Vocabulary.terms(selected?.vocabulary ?? "").filter { $0 != term }.joined(separator: ", "))
        vocabularyFeedback = tr("已删除术语：", "Removed term: ") + term
    }

    var canMigrate: Bool {
        !recording && !starting && !stopping && !shuttingDown && !migrating && !diagnostics.running && !modelManager.busy && engine.pendingCount == 0 && planningTasks.isEmpty
    }

    func chooseStorageLocation(models: Bool) {
        guard canMigrate else { return }
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true; panel.canChooseFiles = false; panel.canCreateDirectories = true
        panel.prompt = tr("选择位置", "Choose location")
        panel.message = models ? tr("将在所选位置创建 LocalVerbatim Models 文件夹。", "A LocalVerbatim Models folder will be created here.") : tr("将在所选位置创建 LocalVerbatim Recordings 文件夹，并复制和校验现有会议。原目录保留。", "Your meetings will be copied and verified in a LocalVerbatim Recordings folder. The original folder is retained.")
        if panel.runModal() == .OK, let parent = panel.url {
            Task { await self.migrateStorage(to: parent.appendingPathComponent(models ? "LocalVerbatim Models" : "LocalVerbatim Recordings"), models: models) }
        }
    }

    func migrateStorage(to destination: URL, models: Bool) async {
        guard canMigrate else { return }
        migrating = true; migrationMessage = tr("正在复制并校验文件…", "Copying and verifying files…")
        commitVocabularyDraft(); stopPlayback()
        let source = models ? AppPaths.model : AppPaths.recordings
        let target = models ? destination.appendingPathComponent("Qwen3-ASR-1.7B-bf16") : destination
        let operation = Task<Void, Never> { @MainActor [weak self] in
            guard let self else { return }
            do {
                if models {
                    self.engine.unload()
                    for _ in 0..<100 where self.engine.hasRunningProcess { try await Task.sleep(nanoseconds: 100_000_000) }
                    guard !self.engine.hasRunningProcess else { throw NSError(domain: "LocalVerbatim.Storage", code: 2, userInfo: [NSLocalizedDescriptionKey: tr("请等待模型停止后重试。", "Wait for the model to stop, then try again.")]) }
                }
                guard FileManager.default.fileExists(atPath: source.path) else { throw NSError(domain: "LocalVerbatim.Storage", code: 3, userInfo: [NSLocalizedDescriptionKey: tr("原目录不可用，未更改位置。", "The original location is unavailable. No location was changed.")]) }
                try await Task.detached(priority: .utility) { try StorageMigration.copyVerified(from: source, to: target) }.value
                let saved = AppSettings.shared.update { options in
                    if models { options.modelCachePath = destination.path }
                    else { options.recordingsPath = destination.path }
                }
                guard saved else { throw NSError(domain: "LocalVerbatim.Storage", code: 4, userInfo: [NSLocalizedDescriptionKey: AppSettings.shared.error ?? "Cannot save settings"]) }
                if !models {
                    for index in self.meetings.indices {
                        MeetingFiles.rebase(&self.meetings[index])
                        self.persist(self.meetings[index])
                    }
                }
                self.modelManager.refresh()
                self.migrationMessage = tr("已切换到新位置。原文件仍保留，可确认后自行清理。", "Location updated. Original files are retained for you to review and remove if desired.")
            } catch { self.migrationMessage = tr("迁移失败：", "Migration failed: ") + error.localizedDescription }
            self.migrating = false
        }
        migrationTask = operation
        await operation.value
        migrationTask = nil
    }

    func shutdown() async {
        shuttingDown = true
        folderRenameTask?.cancel()
        cancelStarting()
        modelManager.pause()
        commitVocabularyDraft()
        await diagnostics.cancel()
        await migrationTask?.value
        if let startTask { await startTask.value }
        await stopRecording()
        engine.terminate()
        stopPlayback()
    }

    private static func captureMessage(_ message: String) -> String {
        if message.contains("TCC") || message.localizedCaseInsensitiveContains("user declined") {
            return "系统音频权限尚未生效。请在“系统设置 → 隐私与安全性 → 屏幕与系统音频录制”中允许本地逐字稿（LocalVerbatim）。重新编译后，可能需要移除旧条目，用“+”重新选择当前应用并重新打开。"
        }
        return message
    }
}
