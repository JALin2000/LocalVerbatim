import Foundation
import Combine
import AVFoundation
import ScreenCaptureKit
import CoreMedia
import CoreGraphics

/// A short, on-disk ASR input. Times refer to the shared recording timeline.
struct AudioChunk: Codable, Sendable, Identifiable {
    let id: String
    let source: String
    let start: Double
    let end: Double
    let path: String
}

/// Capture and crash recovery inspect identical quantized samples, ensuring
/// that a pause produces the same chunk IDs before and after an interruption.
enum AudioWindowing {
    static let maximumFrames = 288_000 // 18 seconds at 16 kHz
    static let defaultOverlap = 12_000
    struct Boundary {
        let frames: Int
        let overlap: Int
        var advance: Int { frames - overlap }
    }

    static func pcm16(_ samples: [Float]) -> Data {
        let pcm = samples.map { sample -> Int16 in
            let finite = sample.isFinite ? sample : 0
            return Int16((max(-1, min(1, finite)) * 32767).rounded()).littleEndian
        }
        return pcm.withUnsafeBytes { Data($0) }
    }

    static func boundary(pcm16 data: Data) -> Boundary {
        let count = min(maximumFrames, data.count / 2)
        let fallback = Boundary(frames: count, overlap: min(defaultOverlap, max(0, count - 1)))
        guard count == maximumFrames else { return fallback }
        let analysisFrames = 160 // 10 ms; integer PCM makes recovery deterministic
        let minimumGap = 9_600 // 0.6 seconds
        let minimumEnd = 96_000 // 6 seconds
        var gapStart: Int?
        var chosen: Boundary?
        func considerGap(ending end: Int) {
            guard let start = gapStart, end - start >= minimumGap, end >= minimumEnd else { return }
            let gap = end - start
            let overlap = gap >= defaultOverlap ? defaultOverlap : min(defaultOverlap, gap * 9 / 10)
            chosen = Boundary(frames: end, overlap: overlap)
        }
        data.withUnsafeBytes { (bytes: UnsafeRawBufferPointer) in
            for block in stride(from: 0, to: count, by: analysisFrames) {
                let end = min(count, block + analysisFrames)
                var energy: Int64 = 0
                var peak = 0
                for frame in block..<end {
                    let raw = UInt16(bytes[frame * 2]) | UInt16(bytes[frame * 2 + 1]) << 8
                    let sample = Int(Int16(bitPattern: raw))
                    energy += Int64(sample * sample)
                    peak = max(peak, abs(sample))
                }
                // RMS <= -54 dBFS and peak <= -40 dBFS: a conservative pause,
                // not a speech detector. The original audio is always retained.
                let quiet = energy <= Int64(end - block) * 65 * 65 && peak <= 328
                if quiet {
                    if gapStart == nil { gapStart = block }
                } else {
                    considerGap(ending: block)
                    gapStart = nil
                }
            }
        }
        considerGap(ending: count)
        return chosen ?? fallback
    }
}

private enum CaptureError: LocalizedError {
    case message(String)
    var errorDescription: String? {
        switch self { case .message(let message): return message }
    }
}

/// Captures both sources with a single ScreenCaptureKit clock. No screen frames
/// are requested, received, or saved. All recording buffers are bounded.
@MainActor
final class AudioCapture: ObservableObject {
    @Published private(set) var micLevel: Double = 0
    @Published private(set) var systemLevel: Double = 0
    /// Frames actually delivered by the capture APIs; padding never increments these.
    @Published private(set) var micFrames: Int64 = 0
    @Published private(set) var systemFrames: Int64 = 0
    @Published private(set) var isRecording = false
    @Published private(set) var error: String?
    @Published private(set) var warning: String?

    private var stream: SCStream?
    private var sink: CaptureSink?
    private var isStarting = false
    private var isStopping = false
    private var sessionID: UUID?
    private var deviceTimer: Timer?
    private var selectedMicrophoneID = ""
    private var followsDefault = true
    @Published private(set) var microphoneName = ""

    func cancelPendingStart() { if isStarting { sessionID = nil } }

    func start(directory: URL, microphoneID: String = "", includeOwnAudio: Bool = false, onChunk: @escaping (AudioChunk) -> Void) async throws {
        guard !isRecording, !isStarting, !isStopping else {
            throw CaptureError.message("录音已经开始，请先结束当前会议。")
        }
        isStarting = true
        let attempt = UUID(); sessionID = attempt
        error = nil
        warning = nil
        micFrames = 0
        systemFrames = 0
        defer { isStarting = false }

        do {
            let microphoneAllowed = try await boundedOperation(seconds: 30, message: tr("麦克风授权等待超时。请完成系统授权后重试，或打开设置检查权限。", "Microphone permission timed out. Complete the system prompt, then retry or check permissions in Settings.")) {
                await AVCaptureDevice.requestAccess(for: .audio)
            }
            try Task.checkCancellation()
            guard self.sessionID == attempt else { throw CancellationError() }
            guard microphoneAllowed else {
                throw CaptureError.message("请在系统设置 → 隐私与安全性 → 麦克风中允许本地逐字稿（LocalVerbatim），然后重新开始录音。")
            }
            let selectedDevice = microphoneID.isEmpty ? AVCaptureDevice.default(for: .audio) : AVCaptureDevice(uniqueID: microphoneID)
            guard let microphone = selectedDevice, microphone.isConnected else {
                throw CaptureError.message("没有找到可用的麦克风。请在系统设置 → 声音 → 输入中选择输入设备。")
            }
            // This is ScreenCaptureKit's standard system permission flow. Asking
            // for shareable content does not begin a recording.
            self.microphoneName = microphone.localizedName
            self.selectedMicrophoneID = microphone.uniqueID
            self.followsDefault = microphoneID.isEmpty
            let content = try await boundedOperation(seconds: 25, message: tr("系统音频授权等待超时。请在设置中检查屏幕与系统音频录制权限，然后重试。", "System audio permission timed out. Check Screen & System Audio Recording in Settings, then retry.")) {
                try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
            }
            try Task.checkCancellation()
            guard self.sessionID == attempt else { throw CancellationError() }
            guard let display = content.displays.first(where: { $0.displayID == CGMainDisplayID() }) ?? content.displays.first else {
                throw CaptureError.message("没有可用的显示器，无法建立电脑音频采集。")
            }
            let filter = SCContentFilter(display: display, excludingApplications: [], exceptingWindows: [])
            let configuration = SCStreamConfiguration()
            configuration.width = 2
            configuration.height = 2
            configuration.minimumFrameInterval = CMTime(seconds: 1, preferredTimescale: 60)
            configuration.queueDepth = 3
            configuration.showsCursor = false
            configuration.capturesAudio = true
            configuration.excludesCurrentProcessAudio = !includeOwnAudio
            configuration.sampleRate = 16_000
            configuration.channelCount = 1
            configuration.captureMicrophone = true
            // Match Apple's WWDC24 microphone sample explicitly instead of
            // relying on implicit default-device resolution.
            configuration.microphoneCaptureDeviceID = microphone.uniqueID

            let newSink = try CaptureSink(directory: directory)
            newSink.onChunk = { chunk in
                DispatchQueue.main.async { onChunk(chunk) }
            }
            newSink.onLevel = { [weak self] source, level in
                DispatchQueue.main.async {
                    guard let self else { return }
                    if source == "microphone" { self.micLevel = level }
                    else { self.systemLevel = level }
                }
            }
            newSink.onFrames = { [weak self] source, frames in
                DispatchQueue.main.async {
                    guard let self else { return }
                    if source == "microphone" { self.micFrames = frames }
                    else { self.systemFrames = frames }
                }
            }
            newSink.onWarning = { [weak self] warning in
                DispatchQueue.main.async { self?.warning = warning }
            }
            newSink.onFailure = { [weak self] failure in
                DispatchQueue.main.async {
                    guard let self else { return }
                    self.error = "录音已停止：\(failure.localizedDescription)"
                    if !self.isStopping { Task { await self.stop() } }
                }
            }
            let newStream = SCStream(filter: filter, configuration: configuration, delegate: newSink)
            try newStream.addStreamOutput(newSink, type: .audio, sampleHandlerQueue: newSink.queue)
            try newStream.addStreamOutput(newSink, type: .microphone, sampleHandlerQueue: newSink.queue)
            self.sink = newSink
            self.stream = newStream
            newSink.setOriginToNow()
            try await boundedOperation(seconds: 15, message: tr("音频设备启动超时，请检查设备和权限后重试。", "The audio device did not start in time. Check the device and permissions, then retry.")) {
                try await newStream.startCapture()
                if self.sessionID != attempt || Task.isCancelled {
                    try? await newStream.stopCapture()
                    throw CancellationError()
                }
            }
            try Task.checkCancellation()
            guard self.sessionID == attempt else { throw CancellationError() }
            isRecording = true
            deviceTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
                Task { @MainActor in self?.checkDevice() }
            }
        } catch {
            sessionID = nil
            if !(error is CancellationError) { self.error = error.localizedDescription }
            if let stream { try? await boundedOperation(seconds: 4, message: "Stopping the audio device timed out") { try await stream.stopCapture() } }
            if let sink { await sink.finish(padToNow: false) }
            stream = nil
            sink = nil
            isRecording = false
            throw error
        }
    }

    /// Drains both callback queues and writes the final partial chunks before
    /// returning. Already emitted onChunk callbacks run before this completes.
    func stop() async {
        guard !isStopping, stream != nil || sink != nil else { return }
        isStopping = true
        sessionID = nil
        deviceTimer?.invalidate(); deviceTimer = nil
        let stoppedAt = CMClockGetTime(CMClockGetHostTimeClock()).seconds
        if let stream {
            do { try await boundedOperation(seconds: 8, message: tr("停止音频设备超时，已保存收到的录音。", "Stopping the audio device timed out; received audio is saved.")) { try await stream.stopCapture() } }
            catch { if self.error == nil { self.error = error.localizedDescription } }
        }
        if let sink { await sink.finish(padToNow: true, stoppedAt: stoppedAt) }
        stream = nil
        sink = nil
        isRecording = false
        micLevel = 0
        systemLevel = 0
        isStopping = false
    }
    private func checkDevice() {
        guard isRecording else { return }
        if AVCaptureDevice(uniqueID: selectedMicrophoneID)?.isConnected != true {
            warning = tr("麦克风已断开。请结束录音并重新选择输入设备。", "The microphone was disconnected. Stop recording and select an input device again.")
        } else if followsDefault && AVCaptureDevice.default(for: .audio)?.uniqueID != selectedMicrophoneID {
            warning = tr("系统默认麦克风已改变。本场仍使用：", "The default microphone changed. This recording is still using: ") + microphoneName
        }
    }

}

private final class CaptureSink: NSObject, SCStreamOutput, SCStreamDelegate, @unchecked Sendable {
    let queue = DispatchQueue(label: "LocalVerbatim.capture.audio", qos: .userInitiated)
    var onChunk: ((AudioChunk) -> Void)?
    var onLevel: ((String, Double) -> Void)?
    var onFrames: ((String, Int64) -> Void)?
    var onFailure: ((Error) -> Void)?
    var onWarning: ((String?) -> Void)?
    private var tracks: [String: CaptureTrack]
    private var origin = 0.0
    private var finished = false
    private var failed = false
    private var microphoneWatchdog: DispatchSourceTimer?
    private var lastMicSignal = 0.0
    private var quietMicWarning = false

    init(directory: URL) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let chunkDirectory = MeetingFiles.chunks(in: directory)
        try FileManager.default.createDirectory(at: chunkDirectory, withIntermediateDirectories: true)
        tracks = [
            "microphone": try CaptureTrack(source: "microphone", directory: directory, chunks: chunkDirectory),
            "system": try CaptureTrack(source: "system", directory: directory, chunks: chunkDirectory)
        ]
        super.init()
    }

    func setOriginToNow() {
        // Called before startCapture, before callbacks can enter the queue.
        origin = CMClockGetTime(CMClockGetHostTimeClock()).seconds
        let watchdog = DispatchSource.makeTimerSource(queue: queue)
        watchdog.schedule(deadline: .now() + 5, repeating: 1)
        watchdog.setEventHandler { [weak self] in
            guard let self, !self.finished, !self.failed, let mic = self.tracks["microphone"] else { return }
            let now = CMClockGetTime(CMClockGetHostTimeClock()).seconds
            if mic.receivedFrames == 0 || now - mic.lastReceivedTime > 5 {
                self.failed = true
                self.onFailure?(CaptureError.message("麦克风没有传入音频数据。请检查系统输入设备和麦克风权限后重新录音；电脑音频已保留。"))
            } else if now - max(self.origin, self.lastMicSignal) >= 8 && !self.quietMicWarning {
                self.quietMicWarning = true
                self.onWarning?("麦克风持续没有声音。使用 MacBook 内置麦克风时请打开屏幕上盖，并检查静音和输入设备。录音仍在继续。")
            }
        }
        microphoneWatchdog = watchdog
        watchdog.resume()
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard !finished, !failed, sampleBuffer.isValid, CMSampleBufferDataIsReady(sampleBuffer) else { return }
        let source: String
        switch type {
        case .audio: source = "system"
        case .microphone: source = "microphone"
        default: return
        }
        guard let track = tracks[source] else { return }
        do {
            let samples = try track.convert(sampleBuffer)
            guard !samples.isEmpty else { return }
            let presentationTime = CMSampleBufferGetPresentationTimeStamp(sampleBuffer).seconds
            let now = CMClockGetTime(CMClockGetHostTimeClock()).seconds
            track.receivedFrames += Int64(samples.count)
            track.lastReceivedTime = now
            if source == "microphone" && samples.contains(where: { abs($0) > 0.0001 }) {
                lastMicSignal = now
                if quietMicWarning { quietMicWarning = false; onWarning?(nil) }
            }
            // ScreenCaptureKit uses the host clock. The fallback protects file
            // sizes if a driver supplies invalid/discontinuous timestamps.
            let timestamp = presentationTime.isFinite && abs(presentationTime - now) < 5
                ? presentationTime : now - Double(samples.count) / CaptureTrack.rate
            try track.append(samples, at: max(0, timestamp - origin), onChunk: { self.onChunk?($0) })
            if now - track.lastMeterUpdate >= 0.08 {
                track.lastMeterUpdate = now
                let rms = sqrt(samples.reduce(0.0) { $0 + Double($1) * Double($1) } / Double(samples.count))
                let decibels = 20 * log10(max(rms, 0.000_001))
                onLevel?(source, min(1, max(0, (decibels + 60) / 60)))
                onFrames?(source, track.receivedFrames)
            }
        } catch {
            failed = true
            onFailure?(error)
        }
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        queue.async {
            guard !self.finished, !self.failed else { return }
            self.failed = true
            self.onFailure?(error)
        }
    }

    func finish(padToNow: Bool, stoppedAt: Double? = nil) async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            queue.async {
                if !self.finished {
                    self.finished = true
                    self.microphoneWatchdog?.cancel()
                    self.microphoneWatchdog = nil
                    let ending = max(0, (stoppedAt ?? CMClockGetTime(CMClockGetHostTimeClock()).seconds) - self.origin)
                    if padToNow && !self.failed && ending > 2 && self.tracks["microphone"]?.receivedFrames == 0 {
                        self.failed = true
                        self.onFailure?(CaptureError.message("本次录音没有收到麦克风数据，电脑音频已保留。请检查输入设备与麦克风权限。"))
                    }
                    for track in self.tracks.values {
                        do {
                            self.onFrames?(track.source, track.receivedFrames)
                            let finalFrame = padToNow && !self.failed ? Int64((ending * CaptureTrack.rate).rounded()) : nil
                            try track.finish(padTo: finalFrame, onChunk: { self.onChunk?($0) })
                        } catch { self.onFailure?(error) }
                    }
                    self.tracks.removeAll()
                }
                // Main-queue FIFO guarantees final chunk delivery before stop()
                // returns to its caller and marks the meeting finished.
                DispatchQueue.main.async { continuation.resume() }
            }
        }
    }
}

private final class CaptureTrack {
    static let rate = 16_000.0
    private static let windowFrames = 288_000 // 18 seconds
    private static let overlapFrames = 12_000 // 0.75 seconds
    let source: String
    let chunks: URL
    private let archive: PCM16WaveWriter
    private let targetFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: rate, channels: 1, interleaved: false)!
    private var converter: AVAudioConverter?
    private var inputFormat: AVAudioFormat?
    private var rolling: [Float] = []
    private var rollingStart: Int64 = 0
    private var writtenFrames: Int64 = 0
    private var lastEmittedEnd: Int64 = 0
    var lastMeterUpdate: Double = 0
    var lastReceivedTime: Double = 0
    var receivedFrames: Int64 = 0

    init(source: String, directory: URL, chunks: URL) throws {
        self.source = source
        self.chunks = chunks
        archive = try PCM16WaveWriter(url: directory.appendingPathComponent("\(source).wav"))
        rolling.reserveCapacity(Self.windowFrames + 8_192)
    }

    func convert(_ sampleBuffer: CMSampleBuffer) throws -> [Float] {
        guard let description = CMSampleBufferGetFormatDescription(sampleBuffer),
              let format = AVAudioFormat(cmAudioFormatDescription: description) as AVAudioFormat? else {
            throw CaptureError.message("音频设备没有提供有效的 PCM 格式。")
        }
        var pending: [Float] = []
        if inputFormat != format {
            pending = try drainConverter()
            inputFormat = format
            converter = AVAudioConverter(from: format, to: targetFormat)
            converter?.primeMethod = .none
        }
        guard let converter else { throw CaptureError.message("无法将麦克风格式转换为 16 kHz 音频。") }

        var requiredSize = 0
        var retainedBlock: CMBlockBuffer?
        let sizingStatus = CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(
            sampleBuffer, bufferListSizeNeededOut: &requiredSize, bufferListOut: nil,
            bufferListSize: 0, blockBufferAllocator: nil, blockBufferMemoryAllocator: nil,
            flags: UInt32(kCMSampleBufferFlag_AudioBufferList_Assure16ByteAlignment), blockBufferOut: &retainedBlock)
        guard requiredSize > 0, sizingStatus == noErr || sizingStatus == kCMSampleBufferError_ArrayTooSmall else {
            throw CaptureError.message("无法读取音频缓冲区（\(sizingStatus)）。")
        }
        let storage = UnsafeMutableRawPointer.allocate(byteCount: requiredSize, alignment: 16)
        defer { storage.deallocate() }
        let bufferList = storage.assumingMemoryBound(to: AudioBufferList.self)
        let readStatus = CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(
            sampleBuffer, bufferListSizeNeededOut: nil, bufferListOut: bufferList,
            bufferListSize: requiredSize, blockBufferAllocator: nil, blockBufferMemoryAllocator: nil,
            flags: UInt32(kCMSampleBufferFlag_AudioBufferList_Assure16ByteAlignment), blockBufferOut: &retainedBlock)
        guard readStatus == noErr,
              let input = AVAudioPCMBuffer(pcmFormat: format, bufferListNoCopy: bufferList, deallocator: nil) else {
            throw CaptureError.message("读取音频采样失败（\(readStatus)）。")
        }
        input.frameLength = AVAudioFrameCount(CMSampleBufferGetNumSamples(sampleBuffer))
        let capacity = AVAudioFrameCount(ceil(Double(input.frameLength) * Self.rate / format.sampleRate)) + 256
        guard let output = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: capacity) else {
            throw CaptureError.message("无法分配音频转换缓冲区。")
        }
        var supplied = false
        var conversionError: NSError?
        let status = converter.convert(to: output, error: &conversionError) { _, status in
            if supplied { status.pointee = .noDataNow; return nil }
            supplied = true
            status.pointee = .haveData
            return input
        }
        if let conversionError { throw conversionError }
        guard status != .error, let channel = output.floatChannelData?[0] else {
            throw CaptureError.message("音频采样转换失败。")
        }
        // The retained CMBlockBuffer stays alive until conversion is complete.
        withExtendedLifetime(retainedBlock) {}
        return pending + Array(UnsafeBufferPointer(start: channel, count: Int(output.frameLength)))
    }

    func append(_ samples: [Float], at seconds: Double, onChunk: (AudioChunk) -> Void) throws {
        let target = Int64((seconds * Self.rate).rounded())
        let tolerance: Int64 = 640 // tolerate up to 40 ms of driver timestamp jitter
        if target > writtenFrames + tolerance { try pad(to: target, onChunk: onChunk) }
        let skip = target < writtenFrames - tolerance ? Int(min(Int64(samples.count), writtenFrames - target)) : 0
        if skip < samples.count { try appendContinuous(Array(samples[skip...]), onChunk: onChunk) }
    }

    func pad(to target: Int64, onChunk: (AudioChunk) -> Void) throws {
        // Bounded scratch buffers even after a long period of source silence.
        while writtenFrames < target {
            let count = Int(min(16_000, target - writtenFrames))
            try appendContinuous([Float](repeating: 0, count: count), onChunk: onChunk)
        }
    }

    private func appendContinuous(_ samples: [Float], onChunk: (AudioChunk) -> Void) throws {
        try archive.append(samples)
        writtenFrames += Int64(samples.count)
        rolling.append(contentsOf: samples)
        while rolling.count >= Self.windowFrames {
            let window = Array(rolling.prefix(Self.windowFrames))
            let boundary = AudioWindowing.boundary(pcm16: AudioWindowing.pcm16(window))
            try emit(Array(window.prefix(boundary.frames)), start: rollingStart, onChunk: onChunk)
            let advance = boundary.advance
            rolling.removeFirst(advance)
            rollingStart += Int64(advance)
        }
    }

    private func emit(_ samples: [Float], start: Int64, onChunk: (AudioChunk) -> Void) throws {
        let end = start + Int64(samples.count)
        lastEmittedEnd = end
        // Skip only digital silence. All captured audio remains in the archive.
        // Speech/VAD decisions are deliberately left to the ASR worker.
        guard samples.contains(where: { abs($0) > 0.000_02 }) else { return }
        let id = "\(source)-\(start)"
        let url = chunks.appendingPathComponent("\(id).wav")
        let writer = try PCM16WaveWriter(url: url)
        try writer.append(samples)
        try writer.close()
        onChunk(AudioChunk(id: id, source: source, start: Double(start) / Self.rate,
                           end: Double(end) / Self.rate, path: url.path))
    }

    private func drainConverter() throws -> [Float] {
        guard let converter else { return [] }
        var samples: [Float] = []
        for _ in 0..<16 {
            guard let output = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: 4_096) else {
                throw CaptureError.message("无法分配音频转换缓冲区。")
            }
            var failure: NSError?
            let status = converter.convert(to: output, error: &failure) { _, inputStatus in
                inputStatus.pointee = .endOfStream
                return nil
            }
            if let failure { throw failure }
            if let channel = output.floatChannelData?[0], output.frameLength > 0 {
                samples.append(contentsOf: UnsafeBufferPointer(start: channel, count: Int(output.frameLength)))
            }
            if status == .endOfStream || output.frameLength == 0 { break }
        }
        self.converter = nil
        inputFormat = nil
        return samples
    }

    func finish(padTo target: Int64? = nil, onChunk: (AudioChunk) -> Void) throws {
        let tail = try drainConverter()
        if !tail.isEmpty { try appendContinuous(tail, onChunk: onChunk) }
        if let target { try pad(to: target, onChunk: onChunk) }
        if !rolling.isEmpty && writtenFrames > lastEmittedEnd {
            try emit(rolling, start: rollingStart, onChunk: onChunk)
        }
        rolling.removeAll(keepingCapacity: false)
        try archive.close()
    }
}

/// A checkpointed WAV writer, deliberately independent of the ASR process.
/// The file always has a playable header, refreshed at most two seconds apart.
private final class PCM16WaveWriter {
    private let handle: FileHandle
    private var byteCount: UInt32 = 0
    private var lastCheckpointBytes: UInt32 = 0
    private var closed = false

    init(url: URL) throws {
        // Never truncate an earlier recording, including a retry after failure.
        try Data().write(to: url, options: .withoutOverwriting)
        handle = try FileHandle(forWritingTo: url)
        try handle.write(contentsOf: Self.header(dataBytes: 0))
    }

    func append(_ samples: [Float]) throws {
        guard !closed else { throw CaptureError.message("录音文件已经关闭。") }
        let bytes = UInt64(samples.count) * 2
        guard UInt64(byteCount) + bytes <= UInt64(UInt32.max) - 36 else {
            throw CaptureError.message("单次录音超过 WAV 文件大小上限，请开始新的会议。")
        }
        try handle.write(contentsOf: AudioWindowing.pcm16(samples))
        byteCount += UInt32(bytes)
        if byteCount - lastCheckpointBytes >= 64_000 { try checkpoint() }
    }

    private func checkpoint() throws {
        try handle.seek(toOffset: 0)
        try handle.write(contentsOf: Self.header(dataBytes: byteCount))
        try handle.seekToEnd()
        try handle.synchronize()
        lastCheckpointBytes = byteCount
    }

    func close() throws {
        guard !closed else { return }
        try checkpoint()
        try handle.close()
        closed = true
    }

    deinit { if !closed { try? close() } }

    private static func header(dataBytes: UInt32) -> Data {
        var data = Data()
        func fourCC(_ value: String) { data.append(contentsOf: value.utf8) }
        func u16(_ value: UInt16) { var value = value.littleEndian; withUnsafeBytes(of: &value) { data.append(contentsOf: $0) } }
        func u32(_ value: UInt32) { var value = value.littleEndian; withUnsafeBytes(of: &value) { data.append(contentsOf: $0) } }
        fourCC("RIFF"); u32(36 + dataBytes); fourCC("WAVE")
        fourCC("fmt "); u32(16); u16(1); u16(1); u32(16_000); u32(32_000); u16(2); u16(16)
        fourCC("data"); u32(dataBytes)
        return data
    }
}
