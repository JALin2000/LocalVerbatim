// Compile the production MeetingStore, Models and Recovery with controlled
// capture/ASR doubles. These tests never open an audio device or load a model.
import Foundation
import Combine
import Darwin

struct AudioChunk: Codable, Sendable, Identifiable {
    let id: String
    let source: String
    let start: Double
    let end: Double
    let path: String
}

struct TranscriptionJob {
    let meetingID: String
    let chunk: AudioChunk
    let language: String
    var vocabulary: String = ""
    var context: String = ""
    var refinementID: String?
    var isRefinement: Bool { refinementID != nil }
    var identity: String { "\(meetingID)/\(refinementID ?? "live")/\(chunk.id)" }
}

@MainActor
final class TestGate {
    var open = true
    private var waiters: [CheckedContinuation<Void, Never>] = []
    func wait() async {
        guard !open else { return }
        await withCheckedContinuation { waiters.append($0) }
    }
    func release() {
        open = true
        let pending = waiters
        waiters.removeAll()
        pending.forEach { $0.resume() }
    }
}

private enum MockFailure: Error { case captureStart }

@MainActor
final class AudioCapture: ObservableObject {
    @Published var error: String?
    @Published var isRecording = false
    let startGate = TestGate()
    let stopGate = TestGate()
    var failStartAfterCreatingArchive = false
    var startCalls = 0
    var stopCalls = 0
    var drained = false
    var directories: [URL] = []
    private var stopping = false
    private var callback: ((AudioChunk) -> Void)?
    private var directory: URL?

    func start(directory: URL, microphoneID: String = "", onChunk: @escaping (AudioChunk) -> Void) async throws {
        startCalls += 1
        directories.append(directory)
        self.directory = directory
        callback = onChunk
        drained = false
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        // Deliberately overwrite if the Store supplies an old directory: the
        // failure-retry test must catch that unsafe lifecycle decision.
        try fixtureWave(marker: UInt8(startCalls)).write(to: directory.appendingPathComponent("microphone.wav"))
        try fixtureWave(marker: UInt8(startCalls)).write(to: directory.appendingPathComponent("system.wav"))
        await startGate.wait()
        if failStartAfterCreatingArchive { throw MockFailure.captureStart }
        isRecording = true
    }

    func cancelPendingStart() {}

    func stop() async {
        stopCalls += 1
        // Match the real capture layer: a concurrent second stop returns early.
        guard !stopping else { return }
        stopping = true
        await stopGate.wait()
        if let directory {
            let chunks = MeetingFiles.chunks(in: directory)
            try! FileManager.default.createDirectory(at: chunks, withIntermediateDirectories: true)
            let file = chunks.appendingPathComponent("microphone-0.wav")
            try! fixtureWave(marker: 7).write(to: file)
            callback?(AudioChunk(id: "microphone-0", source: "microphone", start: 0, end: 1, path: file.path))
        }
        drained = true
        isRecording = false
        stopping = false
    }
}

@MainActor
final class TranscriptionEngine: ObservableObject {
    @Published var pendingCount = 0
    var peakGB: Double = 0
    var onResult: ((TranscriptionJob, String, String) -> Void)?
    var onError: ((String) -> Void)?
    var onJobStarted: ((TranscriptionJob) -> Void)?
    var onJobFailure: ((TranscriptionJob, String) -> Void)?
    var onFatalError: ((String) -> Void)?
    var starts = 0
    var terminations = 0
    var jobs: [TranscriptionJob] = []
    var refinementsPaused = false
    var hasRunningProcess = false
    var interruptedRuns: [String] = []
    func unload() {}
    func start() { starts += 1 }
    func enqueue(_ values: [TranscriptionJob]) {
        for job in values where !jobs.contains(where: { $0.identity == job.identity }) { jobs.append(job) }
        pendingCount = jobs.count
    }
    func terminate() { terminations += 1 }
    func setRefinementsPaused(_ value: Bool) { refinementsPaused = value }
    func cancelRefinement(meetingID: String, runID: String, interruptActive: Bool = false) {
        if interruptActive { interruptedRuns.append("\(meetingID)/\(runID)") }
        jobs.removeAll { $0.meetingID == meetingID && $0.refinementID == runID }; pendingCount = jobs.count
    }
    func cancelMeeting(_ meetingID: String) {
        jobs.removeAll { $0.meetingID == meetingID }; pendingCount = jobs.count
    }
    func complete(_ job: TranscriptionJob, text: String) {
        jobs.removeAll { $0.identity == job.identity }
        onJobStarted?(job); onResult?(job, text, ""); pendingCount = jobs.count
    }
}

@MainActor
final class AudioDiagnostics: ObservableObject {
    @Published var running = false
    func cancel() async { running = false }
}
@MainActor
final class ModelManager: ObservableObject {
    @Published var available = true
    @Published var busy = false
    var onReady: (() -> Void)?
    func refresh() {}
    func pause() {}
}

private func fixtureWave(marker: UInt8) -> Data {
    var data = Data()
    func tag(_ string: String) { data.append(contentsOf: string.utf8) }
    func u16(_ value: UInt16) { var v = value.littleEndian; withUnsafeBytes(of: &v) { data.append(contentsOf: $0) } }
    func u32(_ value: UInt32) { var v = value.littleEndian; withUnsafeBytes(of: &v) { data.append(contentsOf: $0) } }
    tag("RIFF"); u32(32_036); tag("WAVE"); tag("fmt "); u32(16)
    u16(1); u16(1); u32(16_000); u32(32_000); u16(2); u16(16)
    tag("data"); u32(32_000)
    data.append(Data(repeating: marker, count: 32_000))
    return data
}

private struct CheckFailure: Error, CustomStringConvertible {
    let description: String
}

@MainActor
private func check(_ condition: @autoclosure () -> Bool, _ message: String) throws {
    if !condition() { throw CheckFailure(description: message) }
}

@MainActor
private func eventually(_ description: String, _ condition: () -> Bool) async throws {
    for _ in 0..<500 {
        if condition() { return }
        try await Task.sleep(nanoseconds: 2_000_000)
    }
    throw CheckFailure(description: "Timed out: \(description)")
}

@MainActor
private func settle() async throws {
    for _ in 0..<10 { try await Task.sleep(nanoseconds: 2_000_000) }
}

@MainActor
private func manifest(_ meeting: Meeting) throws -> Meeting {
    try JSONDecoder().decode(Meeting.self, from: Data(contentsOf: MeetingFiles.readableMetadata(in: meeting.folder)))
}

@main
struct LifecycleChecks {
    @MainActor
    static func main() async {
        do {
            guard ProcessInfo.processInfo.environment["LOCALVERBATIM_ROOT"] != nil else {
                throw CheckFailure(description: "Use run_lifecycle_tests.sh; an isolated LOCALVERBATIM_ROOT is required")
            }
            switch CommandLine.arguments.dropFirst().first {
            case "quit-during-start": try await quitDuringStart()
            case "quit-during-stop": try await quitDuringStop()
            case "failed-start-preserves-audio": try await failedStartPreservesAudio()
            case "multiple-stops-during-start": try await multipleStopsDuringStart()
            case "template-inheritance": try await templateInheritance()
            case "automatic-refinement": try await automaticRefinement()
            case "refinement-resume": try await refinementResume()
            case "recording-priority": try await recordingPriority()
            case "refinement-failure-retry": try await refinementFailureRetry()
            case "refinement-stop-resume": try await refinementStopResume()
            case "refinement-stop-waiting-planning": try await refinementStopWaitingPlanning()
            case "delete-meeting-and-audio": try await deleteMeetingAndAudio()
            case "delete-failure-preserves-meeting": try await deleteFailurePreservesMeeting()
            case "delete-recording-guards": try await deleteRecordingGuards()
            case "tagged-terminology": try await taggedTerminology()
            case "storage-migration": try await storageMigration()
            case "legacy-file-organization": try await legacyFileOrganization()
            case "rename-when-idle": try await renameWhenIdle()
            case "organization-conflicts": try await organizationConflicts()
            case "refinement-rerun-current-hints": try await refinementRerunCurrentHints()
            case "refinement-rerun-paused": try await refinementRerunPaused()
            case "refinement-rerun-save-failure": try await refinementRerunSaveFailure()
            default: throw CheckFailure(description: "Unknown lifecycle scenario")
            }
            print("PASS: \(CommandLine.arguments[1])")
        } catch {
            FileHandle.standardError.write(Data("FAIL: \(error)\n".utf8))
            exit(1)
        }
    }

    @MainActor
    private static func finishInitialPass(_ store: MeetingStore) async throws -> [TranscriptionJob] {
        await store.startRecording(); await store.stopRecording()
        store.engine.complete(store.engine.jobs[0], text: "Original words")
        try await eventually("initial second-pass jobs") { store.engine.jobs.filter(\.isRefinement).count == 2 }
        let jobs = store.engine.jobs
        for job in jobs { store.engine.complete(job, text: "Previous \(job.chunk.source)") }
        return jobs
    }

    @MainActor
    private static func refinementRerunCurrentHints() async throws {
        let store = MeetingStore()
        store.updateVocabulary("First terms"); store.updateRecognitionContext("First context")
        let previousJobs = try await finishInitialPass(store)
        let before = store.selected!, oldRun = before.refinement!
        let originalExport = try Data(contentsOf: MeetingFiles.transcript(in: before.folder, format: "txt"))
        let snapshot = try Data(contentsOf: MeetingFiles.snapshot(in: before.folder))
        let audio = try Data(contentsOf: before.folder.appendingPathComponent("system.wav"))
        store.updateVocabulary("Updated terms"); store.setVocabularyDraft("arxiv")
        store.updateRecognitionContext("Updated context"); store.updateLanguage("Chinese")
        store.requestRefinement() // A completed run must start again, not silently do nothing.
        let newID = store.selected!.refinement!.id
        try check(newID != oldRun.id && store.selected?.refinementHistory?.count == 1, "Rerun did not archive the old run with a new identity")
        try check(store.transcriptVersion == Meeting.historyVersion(oldRun) && store.visibleSegments.map(\.text) == before.ordered(version: "refined").map(\.text), "Previous completed text disappeared during rerun")
        try await eventually("new full pass") { store.engine.jobs.count == 2 }
        try check(store.engine.jobs.allSatisfy { $0.refinementID == newID && $0.vocabulary == "Updated terms, arxiv" && $0.context == "Updated context" && $0.language == "Chinese" }, "Rerun did not capture current settings and pending terminology")
        store.restartRefinement(); store.requestRefinement()
        try check(store.selected?.refinement?.id == newID && store.selected?.refinementHistory?.count == 1, "Repeated clicks duplicated an active pass")
        store.engine.onResult?(previousJobs[0], "stale words", "")
        store.engine.onJobFailure?(previousJobs[0], "stale failure")
        try check(store.selected?.refinement?.isActive == true && store.selected?.refinement?.segments.isEmpty == true, "Old callbacks contaminated the replacement run")
        for job in store.engine.jobs { store.engine.complete(job, text: "Current \(job.chunk.source)") }
        try check(store.selected?.refinement?.state == "complete" && store.transcriptVersion == "refined", "Rerun failed to finish/select its new result")
        let after = store.selected!
        try check(after.refinementHistory?[0].segments.map(\.text) == oldRun.segments.map(\.text), "Previous text was overwritten")
        try check(after.refinementHistory?[0].vocabulary == "First terms", "History lost its hint snapshot")
        try check(after.exportText(format: "txt", version: Meeting.historyVersion(oldRun)).contains("Previous system") && !after.exportText(format: "txt", version: Meeting.historyVersion(oldRun)).contains("Current system"), "Historical export used current output")
        let savedOriginal = try Data(contentsOf: MeetingFiles.transcript(in: before.folder, format: "txt"))
        let savedSnapshot = try Data(contentsOf: MeetingFiles.snapshot(in: before.folder))
        let savedAudio = try Data(contentsOf: before.folder.appendingPathComponent("system.wav"))
        try check(savedOriginal == originalExport && savedSnapshot == snapshot && savedAudio == audio, "Rerun modified original text or audio")
        store.updateTitle("Renamed with history")
        try await eventually("history folder rename") { store.selected!.folder != before.folder }
        let renamed = store.selected!
        try check(renamed.refinementHistory![0].chunks.allSatisfy { $0.path.hasPrefix(renamed.folder.path) }, "History paths did not follow a rename")
        await store.migrateStorage(to: AppPaths.dataRoot.appendingPathComponent("migrated"), models: false)
        try check(store.selected!.refinementHistory![0].chunks.allSatisfy { $0.path.hasPrefix(AppPaths.recordings.path) }, "History paths did not follow a storage move")
        await store.shutdown()
        let reopened = MeetingStore(); try await settle()
        try check(reopened.selected?.refinementHistory?.count == 1 && reopened.engine.jobs.isEmpty && reopened.selected?.refinement?.id == newID, "History/relaunch resumed a completed pass or lost versions")
        await reopened.shutdown()
    }

    @MainActor
    private static func refinementRerunPaused() async throws {
        let store = MeetingStore(); store.updateVocabulary("Old hints")
        await store.startRecording(); await store.stopRecording()
        store.engine.complete(store.engine.jobs[0], text: "Original")
        try await eventually("pass ready to pause") { store.engine.jobs.count == 2 }
        store.engine.complete(store.engine.jobs[0], text: "Partial old pass")
        store.stopRefinement()
        let old = store.selected!.refinement!
        store.updateVocabulary("New hints"); store.restartRefinement()
        try await eventually("paused pass restarted from beginning") { store.engine.jobs.count == 2 }
        let newID = store.selected!.refinement!.id
        try check(newID != old.id && store.selected?.refinementHistory?[0].state == "paused", "Restart lost the paused version")
        let failed = store.engine.jobs[0]
        store.engine.onJobFailure?(failed, "quality failure")
        try check(store.selected?.refinement?.state == "failed" && store.transcriptVersion == "original", "Failed pass hid original content")
        store.updateVocabulary("Later draft"); store.requestRefinement()
        try check(store.selected?.refinement?.id == newID && store.engine.jobs.allSatisfy { $0.vocabulary == "New hints" }, "Retry mixed a new hint snapshot into old progress")
        for job in store.engine.jobs { store.engine.complete(job, text: "Finished new pass") }
        store.restartRefinement()
        try await eventually("third pass") { store.engine.jobs.count == 2 }
        let third = store.selected!.refinement!.id
        try check(store.selected?.refinementHistory?.count == 2 && store.visibleSegments.allSatisfy { $0.text == "Finished new pass" }, "Repeated reruns lost earlier versions")
        store.stopRefinement(); await store.shutdown()
        let reopened = MeetingStore(); try await settle()
        try check(reopened.engine.jobs.isEmpty && reopened.selected?.refinement?.id == third && reopened.selected?.refinement?.state == "paused", "Stopped replacement resumed unexpectedly")
        try check(reopened.selected?.refinementHistory?[0].segments.first?.text == "Partial old pass" && reopened.visibleSegments.allSatisfy { $0.text == "Finished new pass" }, "Restart lost partial history or previous readable text")
        await reopened.shutdown()
    }

    @MainActor
    private static func refinementRerunSaveFailure() async throws {
        let store = MeetingStore(); _ = try await finishInitialPass(store)
        let before = store.selected!, file = MeetingFiles.metadata(in: before.folder)
        let backup = file.appendingPathExtension("backup")
        try FileManager.default.moveItem(at: file, to: backup)
        try FileManager.default.createDirectory(at: file, withIntermediateDirectories: false)
        store.restartRefinement()
        try check(store.selected?.refinement?.id == before.refinement?.id && store.selected?.refinementHistory == nil && store.engine.jobs.isEmpty, "Failed manifest save replaced the old run or queued work")
        try check(store.errorMessage != nil, "Failed rerun save was silent")
        try FileManager.default.removeItem(at: file)
        try FileManager.default.moveItem(at: backup, to: file)
        await store.shutdown()
    }

    @MainActor
    private static func legacyFileOrganization() async throws {
        let fm = FileManager.default
        var meeting = Meeting()
        meeting.title = "项目 / API: weekly"; meeting.status = "complete"; meeting.notes = "Keep my notes"
        let oldFolder = meeting.folder
        let chunk = AudioChunk(id: "microphone-0", source: "microphone", start: 0, end: 1, path: oldFolder.appendingPathComponent("chunks/microphone-0.wav").path)
        meeting.chunks = [chunk]; meeting.completedIDs = [chunk.id]
        var run = RefinementRun(); run.state = "paused"; run.chunks = [chunk]; run.completedIDs = []
        meeting.refinement = run
        let files: [String: Data] = [
            "microphone.wav": fixtureWave(marker: 1), "system.wav": fixtureWave(marker: 2),
            "chunks/microphone-0.wav": fixtureWave(marker: 3), "microphone-0.result.json": Data("{\"text\":\"raw\"}".utf8),
            "refinement/\(run.id)/part.result.json": Data("second pass raw".utf8),
            "transcript-original.json": Data("original snapshot".utf8), "transcript.txt": Data("original export".utf8),
            "transcript-refined.md": Data("refined export".utf8)]
        for (name, data) in files {
            let url = oldFolder.appendingPathComponent(name)
            try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: url)
        }
        try JSONEncoder().encode(meeting).write(to: oldFolder.appendingPathComponent("meeting.json"))
        let store = MeetingStore()
        let moved = store.selected!
        try check(moved.id == meeting.id && moved.folder != oldFolder, "Legacy folder was not organized")
        try check(moved.folder.lastPathComponent.contains("项目 API weekly"), "Unsafe title was not sanitized")
        try check(moved.notes == meeting.notes && moved.refinement?.state == "paused" && store.engine.jobs.isEmpty, "Migration changed notes or resumed a paused pass")
        let destinations = ["microphone.wav", "system.wav", ".localverbatim/chunks/microphone-0.wav", ".localverbatim/results/microphone-0.result.json", ".localverbatim/refinement/\(run.id)/part.result.json", ".localverbatim/transcript-original.json", "Transcripts/original.txt", "Transcripts/refined.md"]
        let sources = ["microphone.wav", "system.wav", "chunks/microphone-0.wav", "microphone-0.result.json", "refinement/\(run.id)/part.result.json", "transcript-original.json", "transcript.txt", "transcript-refined.md"]
        for (source, destination) in zip(sources, destinations) {
            let actual = try Data(contentsOf: moved.folder.appendingPathComponent(destination))
            try check(actual == files[source], "Organization changed bytes in \(source)")
        }
        try check(moved.chunks[0].path == MeetingFiles.chunk("microphone-0.wav", in: moved.folder).path, "Live chunk path not rebased")
        try check(moved.refinement?.chunks[0].path == moved.folder.appendingPathComponent("microphone.wav").path, "Refinement path not rebased")
        await store.shutdown()
        let reopened = MeetingStore()
        try check(reopened.selected?.folder == moved.folder && reopened.meetings.count == 1, "Organization was not idempotent")
        await reopened.shutdown()
    }

    @MainActor
    private static func renameWhenIdle() async throws {
        let store = MeetingStore(); store.updateAutoRefine(false)
        await store.startRecording()
        let before = store.selected!.folder
        let audio = try Data(contentsOf: before.appendingPathComponent("microphone.wav"))
        store.updateTitle("New meeting name")
        try await Task.sleep(nanoseconds: 800_000_000)
        try check(store.selected!.folder == before, "Renamed during recording")
        await store.stopRecording()
        try check(store.selected!.folder == before && store.engine.pendingCount == 1, "Renamed with pending ASR paths")
        store.engine.complete(store.engine.jobs[0], text: "Actual speech")
        try await eventually("idle rename") { store.selected!.folder != before }
        let moved = store.selected!
        let actual = try Data(contentsOf: moved.folder.appendingPathComponent("microphone.wav"))
        try check(actual == audio && moved.folder.lastPathComponent.contains("New meeting name"), "Rename lost audio or title")
        try check(!FileManager.default.fileExists(atPath: before.path), "Rename left an obsolete folder")
        try check(moved.chunks.allSatisfy { FileManager.default.fileExists(atPath: $0.path) }, "Rename left stale chunk paths")
        await store.shutdown()
    }

    @MainActor
    private static func organizationConflicts() async throws {
        let fm = FileManager.default
        try check(MeetingFiles.safeTitle(" / \\ : .. ") == "Meeting", "Empty sanitized name is invalid")
        try check(MeetingFiles.safeTitle(String(repeating: "会议", count: 100)).utf8.count <= 140, "Long Unicode title exceeds byte limit")
        var meeting = Meeting(); meeting.title = "Same name"
        try fm.createDirectory(at: meeting.folder, withIntermediateDirectories: true)
        let source = meeting.folder
        let sentinel = Data("do not overwrite".utf8)
        for full in [false, true] {
            let occupied = AppPaths.recordings.appendingPathComponent(MeetingFiles.directoryName(for: meeting, fullID: full))
            try fm.createDirectory(at: occupied, withIntermediateDirectories: true)
            try sentinel.write(to: occupied.appendingPathComponent("keep"))
        }
        var refused = false
        do { try MeetingFiles.organize(&meeting) } catch { refused = true }
        try check(refused && fm.fileExists(atPath: source.path), "Conflict overwrote an existing meeting")
        // An interruption after the directory rename and one file move can resume.
        var partial = Meeting(); partial.title = "Interrupted layout"
        MeetingFiles.assignNewFolder(&partial)
        try fm.createDirectory(at: MeetingFiles.chunks(in: partial.folder), withIntermediateDirectories: true)
        try sentinel.write(to: MeetingFiles.chunks(in: partial.folder).appendingPathComponent("part.wav"))
        try JSONEncoder().encode(partial).write(to: partial.folder.appendingPathComponent("meeting.json"))
        try sentinel.write(to: partial.folder.appendingPathComponent("part.result.json"))
        try MeetingFiles.organize(&partial); try MeetingFiles.save(partial); try MeetingFiles.organize(&partial)
        let restored = try Data(contentsOf: MeetingFiles.results(in: partial.folder).appendingPathComponent("part.result.json"))
        try check(restored == sentinel, "Partial migration lost data")
        var other = Meeting(); other.title = partial.title; other.created = partial.created
        MeetingFiles.assignNewFolder(&other)
        try check(other.folder != partial.folder, "Identical meeting names collide")
    }

    @MainActor
    private static func taggedTerminology() async throws {
        let store = MeetingStore()
        store.updateAutoRefine(false)
        store.setVocabularyDraft("Acme, API，项目计划,unfinished")
        try check(Vocabulary.terms(store.selected?.vocabulary ?? "") == ["Acme", "API", "项目计划"], "Commas did not commit complete terms")
        try check(store.vocabularyDraft == "unfinished", "Unconfirmed term was lost")
        store.setVocabularyDraft("api,")
        try check(Vocabulary.terms(store.selected?.vocabulary ?? "").count == 3, "Duplicate added")
        store.setVocabularyDraft("Final term")
        await store.startRecording()
        try check(Vocabulary.terms(store.selected?.vocabulary ?? "").last == "Final term", "Starting recording lost the pending final term")
        await store.stopRecording()
        store.removeVocabularyTerm("API")
        try check(!Vocabulary.terms(store.selected?.vocabulary ?? "").contains("API"), "Remove chip failed")
        store.newMeeting()
        try check(store.selected?.vocabulary?.contains("Final term") == true, "Next meeting lost last recorded terminology")
        await store.shutdown()
    }

    @MainActor
    private static func storageMigration() async throws {
        let store = MeetingStore()
        store.updateAutoRefine(false)
        await store.startRecording(); await store.stopRecording()
        let meeting = store.selected!, originalFolder = store.selected!.folder
        let destination = AppPaths.dataRoot.appendingPathComponent("migrated-library")
        await store.migrateStorage(to: destination, models: false)
        try check(AppSettings.shared.options.recordingsPath == nil, "Migration started with pending transcription")
        store.engine.complete(store.engine.jobs.first!, text: "Preserved transcript")
        try await settle()
        let audio = try Data(contentsOf: originalFolder.appendingPathComponent("microphone.wav"))
        await store.migrateStorage(to: destination, models: false)
        try check(AppPaths.recordings.path == destination.path, "Location was not switched after verified copy")
        let copied = try Data(contentsOf: meeting.folder.appendingPathComponent("microphone.wav"))
        let retained = try Data(contentsOf: originalFolder.appendingPathComponent("microphone.wav"))
        try check(audio == copied && audio == retained, "Migration damaged source or destination audio")
        let moved = try manifest(meeting)
        try check(moved.chunks.allSatisfy { $0.path.hasPrefix(destination.path) }, "Chunk paths were not rebased")
        await store.shutdown()
        let reopened = MeetingStore()
        try check(reopened.meetings.contains { $0.id == meeting.id && $0.segments.first?.text == "Preserved transcript" }, "Migrated meeting did not reopen")
        await reopened.shutdown()
    }

    @MainActor
    private static func deleteMeetingAndAudio() async throws {
        let trash = AppPaths.dataRoot.appendingPathComponent("TestTrash")
        try FileManager.default.createDirectory(at: trash, withIntermediateDirectories: true)
        let store = MeetingStore(trashMeetingFolder: { folder in
            try FileManager.default.moveItem(at: folder, to: trash.appendingPathComponent(folder.lastPathComponent))
        })
        store.updateVocabulary("API, JSON")
        store.saveCurrentAsTemplate(name: "规划")
        await store.startRecording(); await store.stopRecording()
        let live = store.engine.jobs.first!
        store.engine.complete(live, text: "原稿")
        try await eventually("refinement ready before deletion") { store.engine.jobs.filter(\.isRefinement).count == 2 }
        let late = store.engine.jobs.first!
        store.engine.complete(late, text: "二次稿")
        let meeting = store.selected!
        var contents: [String: Data] = [:]
        for relative in try FileManager.default.subpathsOfDirectory(atPath: meeting.folder.path) {
            let file = meeting.folder.appendingPathComponent(relative)
            if (try file.resourceValues(forKeys: [.isRegularFileKey])).isRegularFile == true {
                contents[relative] = try Data(contentsOf: file)
            }
        }
        store.deleteMeeting(meeting.id)
        try check(!FileManager.default.fileExists(atPath: meeting.folder.path), "Deletion left recording files in the active library")
        try check(!store.meetings.contains(where: { $0.id == meeting.id }) && store.selected?.status == "draft", "Deleted row/selection was retained")
        try check(store.engine.jobs.isEmpty, "Deleted meeting left queued transcription jobs")
        try check(store.preferences.templates.count == 1 && store.preferences.lastUsedHints?.vocabulary == "API, JSON", "Deleting a meeting deleted reusable terminology")
        for (relative, expected) in contents {
            let actual = try Data(contentsOf: trash.appendingPathComponent(meeting.folder.lastPathComponent).appendingPathComponent(relative))
            try check(actual == expected, "Trash lost or changed a meeting file: \(relative)")
        }
        // Simulate callbacks already queued on the main actor, bypassing the
        // engine's additional cancellation filter. None may recreate a folder.
        store.engine.onResult?(live, "late original", "")
        store.engine.onResult?(late, "late refinement", "")
        store.engine.onJobStarted?(late)
        store.engine.onJobFailure?(late, "late error")
        try await settle()
        try check(!FileManager.default.fileExists(atPath: meeting.folder.path), "Late callback resurrected a deleted meeting")
        await store.shutdown()
        let reopened = MeetingStore()
        try check(!reopened.meetings.contains(where: { $0.id == meeting.id }), "Deleted meeting returned after relaunch")
        await reopened.shutdown()
        // A complete folder restored to its original location remains readable.
        try FileManager.default.moveItem(at: trash.appendingPathComponent(meeting.folder.lastPathComponent), to: meeting.folder)
        let restored = try manifest(meeting)
        try check(restored.segments.count == 1 && restored.refinement?.segments.count == 1, "Recoverable folder lost either transcript")
    }

    @MainActor
    private static func deleteFailurePreservesMeeting() async throws {
        let store = MeetingStore(trashMeetingFolder: { _ in throw MockFailure.captureStart })
        store.updateAutoRefine(false)
        await store.startRecording(); await store.stopRecording()
        let meeting = store.selected!, count = store.engine.jobs.count
        let original = try Data(contentsOf: meeting.folder.appendingPathComponent("microphone.wav"))
        store.deleteMeeting(meeting.id)
        try check(store.selectedID == meeting.id && store.meetings.contains(where: { $0.id == meeting.id }), "Failed deletion removed the row")
        let after = try Data(contentsOf: meeting.folder.appendingPathComponent("microphone.wav"))
        try check(original == after && store.engine.jobs.count == count, "Failed deletion damaged audio or cancelled valid jobs")
        try check(store.errorMessage != nil, "Failed deletion was silent")
        await store.shutdown()
    }

    @MainActor
    private static func deleteRecordingGuards() async throws {
        var deletions = 0
        let store = MeetingStore(trashMeetingFolder: { _ in deletions += 1 })
        store.updateAutoRefine(false)
        let id = store.selectedID!
        store.capture.startGate.open = false
        let start = Task { await store.startRecording() }
        try await eventually("start pending") { store.starting }
        store.deleteMeeting(id)
        try check(deletions == 0 && !store.canDeleteMeeting(id), "Deletion allowed during capture start")
        store.capture.startGate.release(); await start.value
        store.deleteMeeting(id)
        try check(deletions == 0 && !store.canDeleteMeeting(id), "Deletion allowed during recording")
        store.capture.stopGate.open = false
        let stop = Task { await store.stopRecording() }
        try await eventually("stop pending") { store.stopping }
        store.deleteMeeting(id)
        try check(deletions == 0 && !store.canDeleteMeeting(id), "Deletion allowed while final audio is being saved")
        store.capture.stopGate.release(); await stop.value
        try check(store.canDeleteMeeting(id), "Completed meeting could not be deleted")
        await store.shutdown()
    }

    @MainActor
    private static func templateInheritance() async throws {
        let store = MeetingStore()
        store.updateVocabulary("API, CSV")
        store.updateRecognitionContext("库存计划例会")
        store.saveCurrentAsTemplate(name: "库存规划")
        let template = store.preferences.templates[0]
        store.updateAutoRefine(false)
        await store.startRecording()
        store.updateVocabulary("API, CSV, JSON")
        await store.stopRecording()
        let original = store.selected!
        store.newMeeting()
        try check(store.selected?.vocabulary == "API, CSV, JSON", "New meeting did not inherit last used edits")
        try check(store.selected?.recognitionContext == "库存计划例会" && store.selected?.templateID == template.id, "Template/background identity lost")
        try check(store.preferences.templates[0].vocabulary == "API, CSV", "Editing a meeting overwrote its reusable template")
        store.updateVocabulary("")
        store.updateAutoRefine(false)
        await store.startRecording(); await store.stopRecording()
        await store.shutdown()
        let reopened = MeetingStore()
        reopened.newMeeting()
        try check(reopened.selected?.vocabulary == "", "An intentionally cleared last-used vocabulary was not retained")
        try check(reopened.preferences.templates[0].id == template.id, "Named template was not persisted")
        let saved = try manifest(original)
        try check(saved.vocabulary == "API, CSV, JSON", "Creating or editing another meeting mutated the previous meeting")
        await reopened.shutdown()
    }

    @MainActor
    private static func automaticRefinement() async throws {
        let store = MeetingStore()
        store.updateVocabulary("API")
        await store.startRecording(); await store.stopRecording()
        try check(store.selected?.refinement?.state == "waiting", "Stop did not schedule automatic refinement")
        try check(!store.engine.jobs.contains(where: \.isRefinement), "Refinement ran before original transcription finished")
        store.engine.complete(store.engine.jobs.first!, text: "这是原始逐字稿。")
        try await eventually("refinement planned") { store.engine.jobs.filter(\.isRefinement).count == 2 }
        let meeting = store.selected!
        let originalExport = try Data(contentsOf: MeetingFiles.transcript(in: meeting.folder, format: "txt"))
        let snapshot = try Data(contentsOf: MeetingFiles.snapshot(in: meeting.folder))
        let jobs = store.engine.jobs.filter(\.isRefinement)
        for job in jobs { store.engine.complete(job, text: "这是二次识别\(job.chunk.source)。") }
        try check(store.selected?.refinement?.state == "complete", "Refinement did not finish")
        try check(store.selected?.segments.map(\.text) == ["这是原始逐字稿。"], "Refinement overwrote the original transcript")
        let preserved = try Data(contentsOf: MeetingFiles.transcript(in: meeting.folder, format: "txt"))
        let preservedSnapshot = try Data(contentsOf: MeetingFiles.snapshot(in: meeting.folder))
        try check(originalExport == preserved && snapshot == preservedSnapshot, "Original exports/snapshot changed")
        try check(FileManager.default.fileExists(atPath: MeetingFiles.transcript(in: meeting.folder, format: "srt", refined: true).path), "Refined export missing")
        store.engine.complete(jobs[0], text: "重复回调不应追加")
        try check(store.selected?.refinement?.segments.count == 2, "Duplicate refinement result appended twice")
        await store.shutdown()
    }

    @MainActor
    private static func refinementResume() async throws {
        let store = MeetingStore()
        store.updateVocabulary("CSV, TXT")
        await store.startRecording(); await store.stopRecording()
        store.engine.complete(store.engine.jobs.first!, text: "原稿")
        try await eventually("first refinement queue") { store.engine.jobs.filter(\.isRefinement).count == 2 }
        let first = store.engine.jobs.first(where: \.isRefinement)!
        store.engine.complete(first, text: "已完成的二次片段")
        let unfinished = store.engine.jobs.first(where: \.isRefinement)!.chunk.id
        store.updateVocabulary("不影响正在处理的快照")
        await store.shutdown()
        let reopened = MeetingStore()
        try await eventually("resume only unfinished chunk") { !reopened.engine.jobs.isEmpty }
        try check(reopened.engine.jobs.count == 1 && reopened.engine.jobs[0].chunk.id == unfinished, "Restart repeated completed jobs")
        try check(reopened.engine.jobs[0].vocabulary == "CSV, TXT", "Restart changed the captured refinement hints")
        reopened.engine.complete(reopened.engine.jobs[0], text: "恢复后的片段")
        try check(reopened.selected?.refinement?.state == "complete" && reopened.selected?.refinement?.segments.count == 2, "Restart did not preserve partial output")
        await reopened.shutdown()
        let complete = MeetingStore()
        try await settle()
        try check(complete.engine.jobs.isEmpty && complete.engine.starts == 0, "Completed refinement reran after restart")
        await complete.shutdown()
    }

    @MainActor
    private static func recordingPriority() async throws {
        let store = MeetingStore()
        await store.startRecording(); await store.stopRecording()
        store.engine.complete(store.engine.jobs.first!, text: "第一场原稿")
        try await eventually("background refinement") { store.engine.jobs.contains(where: \.isRefinement) }
        let firstID = store.selectedID!
        store.newMeeting()
        await store.startRecording()
        try check(store.engine.refinementsPaused && store.recordingID != firstID, "New recording did not pause background refinement")
        try check(store.engine.jobs.contains(where: \.isRefinement), "Starting a new meeting lost the refinement queue")
        await store.stopRecording()
        try check(!store.engine.refinementsPaused, "Refinement did not resume after recording")
        await store.shutdown()
    }

    @MainActor
    private static func refinementFailureRetry() async throws {
        let store = MeetingStore()
        await store.startRecording(); await store.stopRecording()
        store.engine.complete(store.engine.jobs.first!, text: "保留的原稿")
        try await eventually("two refinement jobs") { store.engine.jobs.filter(\.isRefinement).count == 2 }
        let first = store.engine.jobs[0]
        store.engine.complete(first, text: "已完成部分")
        let failed = store.engine.jobs[0]
        store.engine.onJobFailure?(failed, "模拟识别失败")
        try check(store.selected?.refinement?.state == "failed" && store.engine.jobs.isEmpty, "Failed run continued scheduling")
        try check(store.selected?.segments.first?.text == "保留的原稿", "Failure damaged original")
        store.requestRefinement()
        try check(store.engine.jobs.count == 1 && store.engine.jobs[0].identity == failed.identity, "Retry did not resume only the failed range")
        store.engine.complete(store.engine.jobs[0], text: "重试完成")
        try check(store.selected?.refinement?.segments.count == 2 && store.selected?.refinement?.state == "complete", "Retry lost completed progress")
        await store.shutdown()
    }

    @MainActor
    private static func refinementStopResume() async throws {
        let store = MeetingStore()
        await store.startRecording(); await store.stopRecording()
        store.engine.complete(store.engine.jobs[0], text: "保留的原稿")
        try await eventually("refinement queue before stop") { store.engine.jobs.filter(\.isRefinement).count == 2 }
        store.engine.complete(store.engine.jobs[0], text: "已完成部分")
        let stoppedJob = store.engine.jobs[0]
        let meeting = store.selected!
        let snapshot = try Data(contentsOf: MeetingFiles.snapshot(in: meeting.folder))
        let audio = try Data(contentsOf: meeting.folder.appendingPathComponent("microphone.wav"))
        let otherJob = TranscriptionJob(meetingID: "other-meeting", chunk: stoppedJob.chunk, language: "")
        store.engine.enqueue([otherJob])
        store.stopRefinement()
        try check(store.selected?.refinement?.state == "paused", "Stop did not set a durable user-paused state")
        try check(store.engine.jobs.map(\.identity) == [otherJob.identity], "Stop cancelled unrelated work")
        try check(store.engine.interruptedRuns.count == 1, "Stop did not request active inference interruption")
        store.engine.onJobStarted?(stoppedJob)
        store.engine.onResult?(stoppedJob, "迟到的结果", "")
        store.engine.onJobFailure?(stoppedJob, "迟到的错误")
        try check(store.selected?.refinement?.state == "paused" && store.selected?.refinement?.segments.count == 1 && store.errorMessage == nil, "Late callbacks revived or failed a stopped run")
        await store.shutdown()
        let reopened = MeetingStore()
        try await settle()
        try check(reopened.selected?.refinement?.state == "paused" && reopened.engine.jobs.isEmpty && reopened.engine.starts == 0, "User-stopped run automatically resumed on launch")
        reopened.requestRefinement()
        try check(reopened.engine.jobs.count == 1 && reopened.engine.jobs[0].identity == stoppedJob.identity, "Resume repeated completed chunks or changed the run identity")
        reopened.engine.complete(reopened.engine.jobs[0], text: "继续完成部分")
        try check(reopened.selected?.refinement?.state == "complete" && reopened.selected?.refinement?.segments.count == 2, "Resume lost partial results")
        try check(reopened.selected?.segments.map(\.text) == ["保留的原稿"], "Stop/resume changed the original transcript")
        let preservedSnapshot = try Data(contentsOf: MeetingFiles.snapshot(in: meeting.folder))
        let preservedAudio = try Data(contentsOf: meeting.folder.appendingPathComponent("microphone.wav"))
        try check(preservedSnapshot == snapshot, "Stop/resume changed the original snapshot")
        try check(preservedAudio == audio, "Stop/resume changed audio")
        await reopened.shutdown()
    }

    @MainActor
    private static func refinementStopWaitingPlanning() async throws {
        let store = MeetingStore()
        await store.startRecording(); await store.stopRecording()
        let original = store.engine.jobs[0]
        store.stopRefinement()
        try check(store.engine.jobs.count == 1 && !store.engine.jobs[0].isRefinement, "Stopping a waiting second pass interrupted original transcription")
        store.engine.complete(original, text: "继续完成的原稿")
        try await settle()
        try check(store.selected?.refinement?.state == "paused" && store.engine.jobs.isEmpty, "Original completion restarted a paused second pass")
        store.requestRefinement()
        try check(store.selected?.refinement?.state == "planning", "Resume did not start planning")
        store.stopRefinement()
        store.requestRefinement() // The old cancelled planner must not clear this new attempt.
        try await eventually("rapid planning stop/resume") { store.engine.jobs.filter(\.isRefinement).count == 2 }
        try check(store.errorMessage == nil && store.selected?.refinement?.state == "queued", "Cancelled planner overwrote the new plan")
        store.stopRefinement()
        try await settle()
        try check(store.selected?.refinement?.state == "paused" && store.engine.jobs.isEmpty, "Repeated stop failed")
        await store.shutdown()
    }

    @MainActor
    private static func quitDuringStart() async throws {
        let store = MeetingStore()
        store.capture.startGate.open = false
        store.capture.stopGate.open = false
        let start = Task { await store.startRecording() }
        try await eventually("capture entered start") { store.capture.startCalls == 1 }
        let before = try manifest(store.selected!)
        try check(before.status == "starting", "Capture was opened before a recoverable starting manifest was saved")
        var shutdownReturned = false
        let shutdown = Task { await store.shutdown(); shutdownReturned = true }
        try await settle()
        try check(!shutdownReturned && store.engine.terminations == 0, "Quit did not wait for the pending start")
        store.capture.startGate.release()
        try await eventually("capture entered stop") { store.capture.stopCalls == 1 }
        try check(!shutdownReturned && !store.capture.drained, "Quit returned before final audio drained")
        try check(store.engine.starts == 0, "Quit started an unnecessary ASR process")
        store.capture.stopGate.release()
        await start.value
        await shutdown.value
        try check(store.capture.drained && !store.recording, "Quit left capture active")
        try check(store.engine.terminations == 1, "Quit did not terminate the model exactly once")
        let saved = try manifest(store.selected!)
        try check(saved.chunks.count == 1 && saved.status == "processing", "Quit lost the final pending chunk")
        await store.startRecording()
        try check(store.capture.startCalls == 1, "A new capture started after shutdown")
    }

    @MainActor
    private static func quitDuringStop() async throws {
        let store = MeetingStore()
        await store.startRecording()
        store.capture.stopGate.open = false
        let stop = Task { await store.stopRecording() }
        try await eventually("initial stop entered") { store.capture.stopCalls == 1 }
        var shutdownReturned = false
        let shutdown = Task { await store.shutdown(); shutdownReturned = true }
        try await settle()
        try check(!shutdownReturned && store.engine.terminations == 0, "Quit raced ahead of the in-flight stop")
        try check(store.capture.stopCalls == 1, "Quit started a second capture.stop instead of awaiting the first")
        store.capture.stopGate.release()
        await stop.value
        await shutdown.value
        let saved = try manifest(store.selected!)
        try check(store.capture.drained && saved.chunks.count == 1, "The pending stop tail was not committed before quit")
    }

    @MainActor
    private static func failedStartPreservesAudio() async throws {
        let store = MeetingStore()
        store.capture.failStartAfterCreatingArchive = true
        let first = store.selected!
        await store.startRecording()
        try check(!store.recording && !store.starting, "Failed start left capture controls stuck")
        let failed = try manifest(first)
        try check(failed.status == "recovered", "A failed start with saved audio became a reusable draft")
        let archive = first.folder.appendingPathComponent("microphone.wav")
        let original = try Data(contentsOf: archive)
        store.capture.failStartAfterCreatingArchive = false
        await store.startRecording()
        try check(store.recordingID != first.id, "Retry reused the failed recording's meeting identity")
        try check(store.capture.directories.count == 2 && store.capture.directories[0] != store.capture.directories[1], "Retry reused the failed recording's directory")
        let preserved = try Data(contentsOf: archive)
        try check(original == preserved, "Retry overwrote audio from the failed start")
        await store.shutdown()
    }

    @MainActor
    private static func multipleStopsDuringStart() async throws {
        let store = MeetingStore()
        store.capture.startGate.open = false
        store.capture.stopGate.open = false
        let start = Task { await store.startRecording() }
        try await eventually("start is pending") { store.capture.startCalls == 1 }
        var firstReturned = false
        var secondReturned = false
        let stop1 = Task { await store.stopRecording(); firstReturned = true }
        let stop2 = Task { await store.stopRecording(); secondReturned = true }
        try await settle()
        store.capture.startGate.release()
        try await eventually("a stop entered") { store.capture.stopCalls >= 1 }
        try await settle()
        try check(store.capture.stopCalls == 1, "Concurrent stops waiting on start created multiple stop operations")
        try check(!firstReturned && !secondReturned && store.recording, "One stop completed before the shared drain")
        store.capture.stopGate.release()
        await start.value
        await stop1.value
        await stop2.value
        let saved = try manifest(store.selected!)
        try check(saved.chunks.count == 1 && !store.recording, "Concurrent stop lost or duplicated the final tail")
        await store.shutdown()
    }
}
