import Foundation
import AppKit
import Combine

@MainActor
final class ModelManager: ObservableObject {
    @Published private(set) var available = false
    @Published private(set) var busy = false
    @Published private(set) var fraction: Double = 0
    @Published private(set) var phase = "idle"
    @Published private(set) var error: String?
    var onReady: (() -> Void)?
    private var process: Process?
    private var paused = false
    private var log: FileHandle?

    init() { refresh() }
    func refresh() {
        let folder = AppPaths.model
        let config = folder.appendingPathComponent("config.json")
        let files = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []
        available = FileManager.default.fileExists(atPath: config.path) && files.contains { $0.pathExtension == "safetensors" }
    }
    var status: String {
        if available && !busy { return tr("本地模型已安装", "Local model installed") }
        switch phase {
        case "downloading": return tr("正在下载模型", "Downloading model")
        case "copying": return tr("正在导入模型", "Importing model")
        case "verifying": return tr("正在校验模型", "Verifying model")
        case "paused": return tr("下载已暂停，可继续", "Download paused; ready to resume")
        case "failed": return tr("模型安装未完成", "Model installation incomplete")
        default: return tr("需要安装本地识别模型", "Install the local speech model")
        }
    }
    func importFolder() {
        let panel = NSOpenPanel(); panel.canChooseDirectories = true; panel.canChooseFiles = false
        panel.message = tr("选择 Qwen3-ASR-1.7B BF16 模型文件夹。将校验文件后导入。", "Choose a Qwen3-ASR-1.7B BF16 model folder. Files will be verified before importing.")
        if panel.runModal() == .OK, let url = panel.url { start(importing: url) }
    }
    func start(importing source: URL? = nil) {
        guard process == nil, !busy, !available else { return }
        do {
            try FileManager.default.createDirectory(at: AppPaths.dataRoot, withIntermediateDirectories: true)
            try StorageMigration.checkWritable(AppSettings.shared.modelCacheDirectory, minimumFreeBytes: 4_500_000_000)
            let worker = AppPaths.root.appendingPathComponent("engine/manage_model.py")
            let child = Process(), output = Pipe()
            child.executableURL = AppPaths.python
            child.arguments = ["-B", "-u", worker.path, "--destination", AppSettings.shared.modelCacheDirectory.path]
            if let source { child.arguments! += ["--import-folder", source.path] }
            var env = ProcessInfo.processInfo.environment
            env["HF_HUB_OFFLINE"] = "0"; env["HF_HUB_DISABLE_TELEMETRY"] = "1"; env["HF_HUB_DISABLE_IMPLICIT_TOKEN"] = "1"
            env["HF_HOME"] = AppPaths.dataRoot.appendingPathComponent("cache/model-download").path
            env["PYTHONDONTWRITEBYTECODE"] = "1"; env.removeValue(forKey: "HF_TOKEN")
            child.environment = env; child.standardOutput = output
            let logURL = AppPaths.dataRoot.appendingPathComponent("model-download.log")
            FileManager.default.createFile(atPath: logURL.path, contents: nil)
            log = try FileHandle(forWritingTo: logURL); child.standardError = log
            child.terminationHandler = { [weak self] proc in
                Task { @MainActor in
                    guard let self, self.process === proc else { return }
                    self.process = nil; self.busy = false; self.refresh()
                    if self.paused { self.phase = "paused" }
                    else if !self.available { self.phase = "failed"; if self.error == nil { self.error = tr("安装未完成。可重试，已下载的内容会保留。", "Installation did not finish. Retry to resume the download.") } }
                    if proc.terminationStatus == 0 && self.available { self.onReady?() }
                    else if proc.terminationStatus != 0 { self.available = false }
                    try? self.log?.close(); self.log = nil
                }
            }
            paused = false; error = nil; phase = source == nil ? "downloading" : "copying"; busy = true
            try child.run(); process = child
            DispatchQueue(label: "local.verbatim.model-download").async { [weak self] in
                var buffer = Data()
                while true {
                    let data = output.fileHandleForReading.availableData
                    if data.isEmpty { break }; buffer.append(data)
                    while let index = buffer.firstIndex(of: 10) {
                        let line = Data(buffer[..<index]); buffer.removeSubrange(...index)
                        Task { @MainActor in
                            guard let self, let event = try? JSONSerialization.jsonObject(with: line) as? [String: Any] else { return }
                            if let phase = event["phase"] as? String { self.phase = phase }
                            if let fraction = event["fraction"] as? Double { self.fraction = fraction }
                            if let message = event["message"] as? String { self.error = message }
                        }
                    }
                }
            }
        } catch { busy = false; phase = "failed"; self.error = error.localizedDescription }
    }
    func pause() { guard let process else { return }; paused = true; process.terminate() }
}
