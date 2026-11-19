import Foundation
import AppKit
import AVFoundation
import Combine
import CoreGraphics

struct MicrophoneChoice: Identifiable { let id: String; let name: String }

@MainActor
final class AudioDiagnostics: ObservableObject {
    @Published private(set) var running = false
    @Published private(set) var secondsLeft = 0
    @Published private(set) var microphonePassed: Bool?
    @Published private(set) var systemPassed: Bool?
    @Published private(set) var message = ""
    @Published var microphonePermission = AVCaptureDevice.authorizationStatus(for: .audio)
    @Published var screenPermission = CGPreflightScreenCaptureAccess()
    @Published private(set) var devices: [MicrophoneChoice] = []
    @Published private(set) var reportFolder: URL?
    let capture = AudioCapture()
    private var task: Task<Void, Never>?
    private var player: AVAudioPlayer?
    private var subscriptions: Set<AnyCancellable> = []

    init() {
        refresh()
        capture.objectWillChange.sink { [weak self] in self?.objectWillChange.send() }.store(in: &subscriptions)
        for name in [AVCaptureDevice.wasConnectedNotification, AVCaptureDevice.wasDisconnectedNotification] {
            NotificationCenter.default.publisher(for: name).sink { [weak self] _ in Task { @MainActor in self?.refresh() } }.store(in: &subscriptions)
        }
    }
    func refresh() {
        microphonePermission = AVCaptureDevice.authorizationStatus(for: .audio)
        screenPermission = CGPreflightScreenCaptureAccess()
        devices = AVCaptureDevice.DiscoverySession(deviceTypes: [.microphone, .external], mediaType: .audio, position: .unspecified).devices.map { MicrophoneChoice(id: $0.uniqueID, name: $0.localizedName) }
    }
    func openPermissionSettings(microphone: Bool) {
        let suffix = microphone ? "Privacy_Microphone" : "Privacy_ScreenCapture"
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?" + suffix) { NSWorkspace.shared.open(url) }
    }
    func start() {
        guard !running else { return }
        running = true; microphonePassed = nil; systemPassed = nil; secondsLeft = 10
        message = tr("正在准备设备…", "Preparing audio devices…")
        task = Task { @MainActor [weak self] in
            guard let self else { return }
            let folder = AppPaths.dataRoot.appendingPathComponent("Diagnostics/\(UUID().uuidString)")
            do {
                try await capture.start(directory: folder, microphoneID: AppSettings.shared.options.microphoneID, includeOwnAudio: true) { _ in }
                message = tr("请说一句话。测试提示音会验证电脑声音。", "Say a short sentence. A test tone will check computer audio.")
                NSSound(named: "Glass")?.play()
                for second in (1...10).reversed() {
                    secondsLeft = second
                    try await Task.sleep(nanoseconds: 1_000_000_000)
                }
                await capture.stop()
                microphonePassed = Self.hasSignal(folder.appendingPathComponent("microphone.wav"))
                systemPassed = Self.hasSignal(folder.appendingPathComponent("system.wav"))
                reportFolder = folder
                message = microphonePassed == true && systemPassed == true
                    ? tr("两路都收到声音。可分别回放确认。", "Both sources received audio. Play each track to confirm.")
                    : tr("测试已保存。未收到声音的音轨请检查设备、音量或权限后重试。合盖时请使用外接麦克风。", "Test saved. For a silent track, check the device, volume or permissions and retry. Use an external microphone when the lid is closed.")
            } catch {
                await capture.stop()
                message = error is CancellationError ? tr("测试已取消", "Test cancelled") : userFacingError(error.localizedDescription)
            }
            running = false; secondsLeft = 0; refresh()
        }
    }
    func cancel() async {
        task?.cancel(); capture.cancelPendingStart()
        await task?.value
        task = nil
        player?.stop()
    }
    func play(_ source: String) {
        guard let folder = reportFolder else { return }
        player?.stop(); player = try? AVAudioPlayer(contentsOf: folder.appendingPathComponent(source + ".wav")); player?.play()
    }
    static func hasSignal(_ url: URL) -> Bool {
        guard let data = try? Data(contentsOf: url), data.count > 44 else { return false }
        var loud = 0
        data.withUnsafeBytes { (bytes: UnsafeRawBufferPointer) in
            for i in stride(from: 44, to: data.count - 1, by: 2) {
                let sample = Int(Int16(bitPattern: UInt16(bytes[i]) | UInt16(bytes[i+1]) << 8))
                if abs(sample) > 120 { loud += 1 }
            }
        }
        return loud >= 160 // Actual signal, not timestamp padding or mere permission.
    }
}
