import Foundation
import AppKit
import Combine

@MainActor
final class ModelManager: ObservableObject {
    @Published private(set) var installed: Set<ModelVariant> = []
    @Published private(set) var activeVariant = AppPaths.modelVariant
    @Published private(set) var downloadingVariant: ModelVariant?
    var available: Bool { installed.contains(activeVariant) }
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
        installed = Set(ModelVariant.allCases.filter { AppPaths.installedModel($0) != nil })
        activeVariant = AppPaths.modelVariant
    }
    var status: String {

        switch phase {
        case "downloading": return tr("正在下载模型", "Downloading model")
        case "copying": return tr("正在导入模型", "Importing model")
        case "verifying": return tr("正在校验模型", "Verifying model")
        case "paused": return tr("下载已暂停，可继续", "Download paused; ready to resume")
        case "failed": return tr("模型安装未完成", "Model installation incomplete")
        default: return available ? tr("本地模型已安装", "Local model installed") : tr("选择本地识别模型", "Choose a local model")
        }
    }
    func importFolder(_ variant: ModelVariant) {
        let panel = NSOpenPanel(); panel.canChooseDirectories = true; panel.canChooseFiles = false
        panel.message = tr("选择模型文件夹，导入前会校验文件。", "Choose the model folder. The files will be verified before import.") + " · " + variant.title
        if panel.runModal() == .OK, let url = panel.url { start(variant, importing: url) }
    }
    func start(_ variant: ModelVariant, importing source: URL? = nil) {
        guard process == nil, !busy, !installed.contains(variant) else { return }
        let hadActiveModel = available
        // Installing an alternative must not change the model used by a
        // running worker, including legacy users without a saved choice.
        if hadActiveModel && AppSettings.shared.options.modelVariant == nil,
           !AppSettings.shared.update({ $0.modelVariant = activeVariant }) {
            error = AppSettings.shared.error
            return
        }
        do {
            try FileManager.default.createDirectory(at: AppPaths.dataRoot, withIntermediateDirectories: true)
            let destination = AppSettings.shared.modelCacheDirectory
            let staging = destination.appendingPathComponent(".download-" + variant.directory)
            let resumed = FileManager.default.fileExists(atPath: staging.path)
            try StorageMigration.checkWritable(destination, minimumFreeBytes: resumed ? 50_000_000 : variant.downloadBytes + 150_000_000)
            let worker = AppPaths.root.appendingPathComponent("engine/manage_model.py")
            let child = Process(), output = Pipe()
            child.executableURL = AppPaths.python
            child.arguments = ["-B", "-u", worker.path, "--destination", destination.path, "--variant", variant.rawValue]
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
                    self.process = nil
                    self.busy = false
                    self.downloadingVariant = nil
                    self.refresh()
                    if proc.terminationStatus == 0 && self.installed.contains(variant) {
                        self.phase = "idle"
                        if !hadActiveModel && self.available { self.onReady?() }
                    } else if self.paused {
                        self.phase = "paused"
                    } else {
                        self.phase = "failed"
                        if self.error == nil { self.error = tr("模型安装未完成。可以重试。", "Model installation did not finish. You can retry.") }
                    }
                    try? self.log?.close(); self.log = nil
                }
            }
            downloadingVariant = variant
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
                            guard let self, self.process === child, let event = try? JSONSerialization.jsonObject(with: line) as? [String: Any] else { return }
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
