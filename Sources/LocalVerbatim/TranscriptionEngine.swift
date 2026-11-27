import Foundation
import Combine
import Darwin

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
final class TranscriptionEngine: ObservableObject {
    @Published var state = "模型待命"
    @Published var ready = false
    @Published var pendingCount = 0
    @Published var memoryGB: Double = 0
    @Published var peakGB: Double = 0
    @Published var lastLatency: Double = 0
    @Published private(set) var memoryTestPeakBytes: Double?
    static let installedRAM = ProcessInfo.processInfo.physicalMemory
    static let memoryLimit = installedRAM * 9 / 10
    static let bytesPerDisplayGB = 1_073_741_824.0
    private static let memoryGuardMessage = "识别进程已达到本机 RAM 的 90%，转写已停止。已保存的录音可以稍后重试。"
    var onResult: ((TranscriptionJob, String, String) -> Void)?
    var onError: ((String) -> Void)?
    var onJobStarted: ((TranscriptionJob) -> Void)?
    var onJobFailure: ((TranscriptionJob, String) -> Void)?
    var onFatalError: ((String) -> Void)?
    var hasRunningProcess: Bool { process != nil }
    private var process: Process?
    private var input: FileHandle?
    private var queue: [TranscriptionJob] = []
    private var active: TranscriptionJob?
    private var watchdog: Timer?
    private var failure = false
    private var logHandle: FileHandle?
    private var refinementsPaused = false
    private var terminating = false
    private var restartWhenExited = false
    private var interruptingCancelledWork = false
    private var cancelledRuns: Set<String> = []
    private var cancelledMeetings: Set<String> = []

    func start(testMemory: Bool = false) {
        guard process == nil else {
            if !ready && (failure || input == nil) { restartWhenExited = true }
            return
        }
        failure = false
        terminating = false
        peakGB = 0
        memoryTestPeakBytes = nil
        guard FileManager.default.fileExists(atPath: AppPaths.python.path),
              FileManager.default.fileExists(atPath: AppPaths.model.appendingPathComponent("config.json").path) else {
            state = "模型未安装"
            let message = "本地模型或运行环境缺失，请重新安装完整的本地逐字稿（LocalVerbatim）应用。"
            onFatalError?(message)
            onError?(message)
            return
        }
        let child = Process(), stdin = Pipe(), stdout = Pipe()
        child.executableURL = AppPaths.python
        child.arguments = ["-B", "-u", AppPaths.worker.path, "--model", AppPaths.model.path]
        if testMemory { child.arguments?.append("--test-memory") }
        child.currentDirectoryURL = AppPaths.dataRoot
        var env = ProcessInfo.processInfo.environment
        env["LOCALVERBATIM_RAM_BYTES"] = String(Self.installedRAM)
        env["HF_HUB_OFFLINE"] = "1"
        env["TRANSFORMERS_OFFLINE"] = "1"
        env["HF_HUB_DISABLE_TELEMETRY"] = "1"
        env["PYTHONUNBUFFERED"] = "1"
        env["PYTHONDONTWRITEBYTECODE"] = "1"
        env["HF_HOME"] = AppPaths.dataRoot.appendingPathComponent("cache/huggingface", isDirectory: true).path
        child.environment = env
        child.standardInput = stdin
        child.standardOutput = stdout
        let logURL = AppPaths.dataRoot.appendingPathComponent("engine.log")
        FileManager.default.createFile(atPath: logURL.path, contents: nil)
        logHandle = try? FileHandle(forWritingTo: logURL)
        child.standardError = logHandle ?? FileHandle.standardError
        state = "正在载入模型…"
        child.terminationHandler = { [weak self] proc in
            Task { @MainActor in
                guard let self, self.process === proc else { return }
                let interrupted = self.interruptingCancelledWork
                self.interruptingCancelledWork = false
                self.ready = false
                self.process = nil
                self.input = nil
                self.watchdog?.invalidate()
                if let job = self.active, !self.isCancelled(job), !self.queue.contains(where: { $0.identity == job.identity }) { self.queue.insert(job, at: 0) }
                self.active = nil
                self.refreshCount()
                self.memoryGB = 0
                if proc.terminationStatus != 0 && !self.failure && !self.terminating && !interrupted {
                    self.state = "转写已停止"
                    let message = proc.terminationStatus == 75 ? Self.memoryGuardMessage :
                        "识别进程退出（\(proc.terminationStatus)）。录音和待处理片段已保存，可重试。详情见 engine.log。"
                    self.onFatalError?(message)
                    self.onError?(message)
                } else if !self.failure {
                    self.state = "模型待命"
                }
                if !self.terminating && (self.restartWhenExited || ((proc.terminationStatus == 0 || interrupted) && !self.queue.isEmpty)) {
                    self.restartWhenExited = false
                    self.start()
                }
            }
        }
        do {
            try child.run()
            process = child
            input = stdin.fileHandleForWriting
            DispatchQueue(label: "local.verbatim.worker-output").async { [weak self] in
                var buffer = Data()
                while true {
                    let data = stdout.fileHandleForReading.availableData
                    if data.isEmpty { break }
                    buffer.append(data)
                    while let index = buffer.firstIndex(of: 10) {
                        let line = Data(buffer[..<index])
                        buffer.removeSubrange(...index)
                        Task { @MainActor in
                            guard let self, self.process === child else { return }
                            self.receive(line)
                        }
                    }
                }
            }
            // Parent-side check survives a blocked Python inference thread.
            watchdog = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
                Task { @MainActor in self?.checkMemory() }
            }
        } catch {
            state = "无法启动模型"
            onFatalError?(error.localizedDescription)
            onError?(error.localizedDescription)
        }
    }

    func enqueue(_ jobs: [TranscriptionJob]) {
        for job in jobs where !cancelledMeetings.contains(job.meetingID) && !queue.contains(where: { $0.identity == job.identity }) && active?.identity != job.identity {
            if let run = job.refinementID { cancelledRuns.remove("\(job.meetingID)/\(run)") }
            queue.append(job)
        }
        refreshCount()
        pump()
    }

    private func refreshCount() { pendingCount = queue.count + (active == nil ? 0 : 1) }

    private func pump() {
        guard ready, active == nil, !queue.isEmpty, let input else { return }
        let liveJob = queue.firstIndex { !$0.isRefinement && $0.chunk.source != "imported" }
        let backgroundJob = queue.firstIndex { !$0.isRefinement } ?? queue.indices.first
        guard let index = liveJob ?? (refinementsPaused ? nil : backgroundJob) else {
            state = "后台转写等待录音结束"
            return
        }
        let job = queue.remove(at: index)
        active = job
        state = job.isRefinement ? "正在二次识别" : "正在转写"
        refreshCount()
        onJobStarted?(job)
        guard active?.identity == job.identity, ready else { return }
        var payload: [String: Any] = ["id": job.identity, "path": job.chunk.path,
                                      "language": job.language, "vocabulary": job.vocabulary, "context": job.context,
                                      "mode": job.isRefinement ? "refinement" : "live"]
        if job.isRefinement {
            payload["start_frame"] = Int64((job.chunk.start * 16_000).rounded())
            payload["frame_count"] = Int64(((job.chunk.end - job.chunk.start) * 16_000).rounded())
        }
        do {
            var data = try JSONSerialization.data(withJSONObject: payload)
            data.append(10)
            try input.write(contentsOf: data)
        } catch {
            queue.insert(job, at: 0)
            active = nil
            fail("无法提交音频片段：\(error.localizedDescription)")
        }
    }

    private func receive(_ line: Data) {
        guard !interruptingCancelledWork else { return }
        guard let event = try? JSONSerialization.jsonObject(with: line) as? [String: Any], let type = event["type"] as? String else { return }
        if let bytes = event["bytes"] as? Double { memoryGB = bytes / 1e9 }
        if let bytes = event["peak"] as? Double { peakGB = max(peakGB, bytes / 1e9) }
        if let job = active, event["id"] as? String == job.identity, !isCancelled(job),
           let evidence = event["quality"] as? [String: Any] {
            do {
                let folder = MeetingFiles.qualityFolder(audio: URL(fileURLWithPath: job.chunk.path), refined: job.isRefinement)
                try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                let name = MeetingFiles.safeIdentifier(job.chunk.id) + "-" + UUID().uuidString + ".json"
                try JSONSerialization.data(withJSONObject: evidence, options: [.prettyPrinted, .sortedKeys])
                    .write(to: folder.appendingPathComponent(name), options: .withoutOverwriting)
            } catch { onError?("无法保存识别重试记录：\(error.localizedDescription)") }
        }
        switch type {
        case "ready": ready = true; state = "模型已就绪"; pump()
        case "memory_test":
            memoryTestPeakBytes = event["peak"] as? Double
        case "status": state = event["message"] as? String ?? state
        case "result":
            guard let job = active, event["id"] as? String == job.identity else { return }
            lastLatency = event["seconds"] as? Double ?? 0
            if !isCancelled(job) { onResult?(job, event["text"] as? String ?? "", event["language"] as? String ?? "") }
            active = nil
            refreshCount()
            state = "模型已就绪"
            pump()
        case "error":
            let message = event["message"] as? String ?? "未知转写错误"
            if event["fatal"] as? Bool == true { fail(message) }
            else {
                // Leave this chunk incomplete in the manifest for an explicit retry.
                let job = active
                active = nil
                if let job, !isCancelled(job) {
                    onJobFailure?(job, message)
                    onError?("某个片段转写失败：\(message)。原始音频仍在，稍后可继续转写。")
                }
                refreshCount()
                state = "模型已就绪"
                pump()
            }
        default: break
        }
    }

    private func checkMemory() {
        guard !failure, let process, process.isRunning else { return }
        var usage = rusage_info_v2()
        let status = withUnsafeMutablePointer(to: &usage) {
            $0.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { proc_pid_rusage(process.processIdentifier, RUSAGE_INFO_V2, $0) }
        }
        guard status == 0 else { return }
        memoryGB = Double(usage.ri_phys_footprint) / 1e9
        peakGB = max(peakGB, memoryGB)
        if usage.ri_phys_footprint >= Self.memoryLimit { fail(Self.memoryGuardMessage) }
    }

    private func fail(_ message: String) {
        guard !failure else { return }
        failure = true
        ready = false
        state = "转写已停止"
        onFatalError?(message)
        if let process, process.isRunning { kill(process.processIdentifier, SIGKILL) }
        onError?(message)
    }

    func unload() {
        guard active == nil && queue.isEmpty else { return }
        ready = false
        try? input?.write(contentsOf: Data("{\"command\":\"shutdown\"}\n".utf8))
        try? input?.close()
        input = nil
    }

    func terminate() {
        terminating = true
        restartWhenExited = false
        watchdog?.invalidate()
        if let process, process.isRunning { process.terminate() }
    }

    func setRefinementsPaused(_ paused: Bool) { refinementsPaused = paused; pump() }

    func cancelRefinement(meetingID: String, runID: String, interruptActive: Bool = false) {
        cancelledRuns.insert("\(meetingID)/\(runID)")
        queue.removeAll { $0.meetingID == meetingID && $0.refinementID == runID }
        if interruptActive,
           (active?.meetingID == meetingID && active?.refinementID == runID || active == nil && queue.isEmpty),
           let child = process {
            // This worker has at most one active job. Preserve all other jobs
            // in the parent queue and restart them only after this worker exits.
            interruptingCancelledWork = true
            active = nil
            ready = false
            try? input?.close(); input = nil
            if child.isRunning { child.terminate() }
            Task { @MainActor [weak self] in
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                guard let self, self.process === child, self.interruptingCancelledWork, child.isRunning else { return }
                kill(child.processIdentifier, SIGKILL)
            }
        }
        refreshCount()
    }

    func cancelMeeting(_ meetingID: String) {
        cancelledMeetings.insert(meetingID)
        queue.removeAll { $0.meetingID == meetingID }
        // The current bounded inference may finish; its result/error is ignored
        // and it cannot be requeued on process exit. Other meetings keep running.
        refreshCount()
    }

    private func isCancelled(_ job: TranscriptionJob) -> Bool {
        if cancelledMeetings.contains(job.meetingID) { return true }
        guard let run = job.refinementID else { return false }
        return cancelledRuns.contains("\(job.meetingID)/\(run)")
    }
}
