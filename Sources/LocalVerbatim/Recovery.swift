import Foundation

/// Restores ASR jobs from the application's own checkpointed PCM WAV archives.
/// Call only after capture has stopped: archive header repair is a disk write.
enum RecordingRecovery {
    private static let sampleRate = 16_000
    private static let windowFrames: Int64 = 288_000

    static func recover(_ meeting: Meeting) throws -> Meeting {
        var recovered = meeting
        let chunkDirectory = MeetingFiles.chunks(in: meeting.folder)
        // Keep order and IDs stable, while resolving paths relative to the
        // meeting's current location rather than a previous installation path.
        var seen = Set<String>()
        recovered.chunks = meeting.chunks.compactMap { chunk in
            guard seen.insert(chunk.id).inserted else { return nil }
            let name = URL(fileURLWithPath: chunk.path).lastPathComponent
            return AudioChunk(id: chunk.id, source: chunk.source, start: chunk.start,
                              end: chunk.end, path: MeetingFiles.chunk(name, in: meeting.folder).path)
        }
        var positions = Dictionary(uniqueKeysWithValues: recovered.chunks.enumerated().map { ($0.element.id, $0.offset) })
        let completed = Set(meeting.completedIDs)
        var archiveDuration: Double?

        for source in meeting.audioSources {
            let archiveURL = meeting.folder.appendingPathComponent("\(source).wav")
            guard FileManager.default.fileExists(atPath: archiveURL.path) else { continue }
            let archive = try RecoveryWaveArchive(url: archiveURL)
            defer { archive.close() }
            archiveDuration = max(archiveDuration ?? 0, Double(archive.frameCount) / Double(sampleRate))
            var start: Int64 = 0
            var lastFullEnd: Int64 = 0

            func restoreWindow(start: Int64, count: Int64) throws {
                let id = "\(source)-\(start)"
                guard !completed.contains(id) else { return }
                let expectedDataBytes = UInt32(count * 2)
                let canonical = chunkDirectory.appendingPathComponent("\(id).wav")
                let current = positions[id].map { URL(fileURLWithPath: recovered.chunks[$0].path) }
                var chosen: URL?
                // Reuse complete existing files, including a recovered filename
                // persisted by an earlier recovery pass.
                for candidate in [current, canonical].compactMap({ $0 }) {
                    if RecoveryWaveArchive.isValidChunk(candidate, dataBytes: expectedDataBytes) {
                        chosen = candidate
                        break
                    }
                }
                if chosen == nil {
                    let data = try archive.readFrames(start: start, count: Int(count))
                    // The recorder omits digital silence from ASR jobs. PCM16
                    // zero samples are exactly two zero bytes.
                    guard data.contains(where: { $0 != 0 }) else { return }
                    try FileManager.default.createDirectory(at: chunkDirectory, withIntermediateDirectories: true)
                    let destination: URL
                    if !FileManager.default.fileExists(atPath: canonical.path) {
                        destination = canonical
                    } else {
                        // A crash can leave an orphan partial chunk. Preserve
                        // it, and put the reconstructed audio at a fresh path.
                        let alternative = chunkDirectory.appendingPathComponent("\(id)-recovered.wav")
                        if RecoveryWaveArchive.isValidChunk(alternative, dataBytes: expectedDataBytes) {
                            chosen = alternative
                            destination = alternative
                        } else if !FileManager.default.fileExists(atPath: alternative.path) {
                            destination = alternative
                        } else {
                            destination = chunkDirectory.appendingPathComponent("\(id)-recovered-\(UUID().uuidString).wav")
                        }
                    }
                    if chosen == nil {
                        var wave = RecoveryWaveArchive.header(dataBytes: expectedDataBytes)
                        wave.append(data)
                        // The exclusive option also protects against a second
                        // process unexpectedly creating this path concurrently.
                        try wave.write(to: destination, options: .withoutOverwriting)
                        chosen = destination
                    }
                }
                guard let chosen else { return }
                let chunk = AudioChunk(id: id, source: source,
                                       start: Double(start) / Double(sampleRate),
                                       end: Double(start + count) / Double(sampleRate), path: chosen.path)
                if let position = positions[id] { recovered.chunks[position] = chunk }
                else {
                    positions[id] = recovered.chunks.count
                    recovered.chunks.append(chunk)
                }
            }

            while start + windowFrames <= archive.frameCount {
                let data = try archive.readFrames(start: start, count: Int(windowFrames))
                let boundary = AudioWindowing.boundary(pcm16: data)
                var count = Int64(boundary.frames)
                var advance = Int64(boundary.advance)
                // Existing metadata remains authoritative for recordings made
                // with an earlier fixed-window version. Never shift completed
                // jobs onto a new segmentation scheme during recovery.
                if let position = positions["\(source)-\(start)"] {
                    let existing = recovered.chunks[position]
                    let existingCount = Int64((existing.end * Double(sampleRate)).rounded()) - start
                    if existingCount > 0 && existingCount <= windowFrames && existingCount != count {
                        count = existingCount
                        advance = max(1, count - Int64(AudioWindowing.defaultOverlap))
                    }
                    if let next = recovered.chunks.filter({ $0.source == source })
                        .map({ Int64(($0.start * Double(sampleRate)).rounded()) })
                        .filter({ $0 > start && $0 <= start + count }).min() {
                        advance = next - start
                    }
                }
                try restoreWindow(start: start, count: count)
                lastFullEnd = start + count
                start += advance
            }
            // Match CaptureTrack exactly: do not create an overlap-only tail
            // when the archive ends precisely at a full window boundary.
            if archive.frameCount > lastFullEnd && archive.frameCount > start {
                try restoreWindow(start: start, count: archive.frameCount - start)
            }
        }
        if let archiveDuration { recovered.duration = archiveDuration }
        return recovered
    }
}

private enum RecoveryError: LocalizedError {
    case invalid(String)
    var errorDescription: String? {
        switch self { case .invalid(let reason): return "无法恢复录音：\(reason)" }
    }
}

private final class RecoveryWaveArchive {
    let frameCount: Int64
    private let handle: FileHandle
    private var isClosed = false

    init(url: URL) throws {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        guard attributes[.type] as? FileAttributeType == .typeRegular,
              let number = attributes[.size] as? NSNumber else {
            throw RecoveryError.invalid("\(url.lastPathComponent) 不是普通音频文件。")
        }
        let size = number.uint64Value
        guard size >= 44 else { throw RecoveryError.invalid("\(url.lastPathComponent) 的 WAV 文件头不完整。") }
        let fullSampleBytes = (size - 44) / 2 * 2
        guard fullSampleBytes <= UInt64(UInt32.max) - 36 else {
            throw RecoveryError.invalid("\(url.lastPathComponent) 超过标准 WAV 大小上限。")
        }
        let opened = try FileHandle(forUpdating: url)
        do {
            let initial = try Self.readExactly(opened, count: 44)
            guard Self.hasExpectedFormat(initial) else {
                throw RecoveryError.invalid("\(url.lastPathComponent) 不是本地逐字稿（LocalVerbatim）的 16 kHz 单声道 PCM16 WAV。")
            }
            let dataBytes = UInt32(fullSampleBytes)
            if Self.u32(initial, 4) != 36 + dataBytes || Self.u32(initial, 40) != dataBytes || size != 44 + fullSampleBytes {
                // Ignore a possible half-written final sample; no complete
                // sample is removed. Do not trust the last checkpoint lengths.
                if size != 44 + fullSampleBytes { try opened.truncate(atOffset: 44 + fullSampleBytes) }
                try opened.seek(toOffset: 0)
                try opened.write(contentsOf: Self.header(dataBytes: dataBytes))
                try opened.synchronize()
            }
            frameCount = Int64(fullSampleBytes / 2)
            handle = opened
        } catch {
            try? opened.close()
            throw error
        }
    }

    func readFrames(start: Int64, count: Int) throws -> Data {
        guard start >= 0, count >= 0, count <= 288_000, start + Int64(count) <= frameCount else {
            throw RecoveryError.invalid("恢复窗口超出音频边界。")
        }
        try handle.seek(toOffset: 44 + UInt64(start) * 2)
        return try Self.readExactly(handle, count: count * 2)
    }

    func close() {
        if !isClosed { try? handle.close(); isClosed = true }
    }

    deinit { close() }

    static func isValidChunk(_ url: URL, dataBytes: UInt32) -> Bool {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
              attributes[.type] as? FileAttributeType == .typeRegular,
              let size = attributes[.size] as? NSNumber,
              size.uint64Value == 44 + UInt64(dataBytes),
              let handle = try? FileHandle(forReadingFrom: url) else { return false }
        defer { try? handle.close() }
        guard let header = try? readExactly(handle, count: 44) else { return false }
        return hasExpectedFormat(header) && u32(header, 4) == 36 + dataBytes && u32(header, 40) == dataBytes
    }

    private static func readExactly(_ handle: FileHandle, count: Int) throws -> Data {
        var data = Data()
        data.reserveCapacity(count)
        while data.count < count {
            guard let part = try handle.read(upToCount: count - data.count), !part.isEmpty else {
                throw RecoveryError.invalid("音频文件在恢复过程中被截断。")
            }
            data.append(part)
        }
        return data
    }

    private static func hasExpectedFormat(_ data: Data) -> Bool {
        guard data.count == 44 else { return false }
        func tag(_ offset: Int, _ text: String) -> Bool { Data(data[offset..<(offset + 4)]) == Data(text.utf8) }
        return tag(0, "RIFF") && tag(8, "WAVE") && tag(12, "fmt ") && tag(36, "data")
            && u32(data, 16) == 16 && u16(data, 20) == 1 && u16(data, 22) == 1
            && u32(data, 24) == 16_000 && u32(data, 28) == 32_000
            && u16(data, 32) == 2 && u16(data, 34) == 16
    }

    private static func u16(_ data: Data, _ offset: Int) -> UInt16 {
        UInt16(data[offset]) | UInt16(data[offset + 1]) << 8
    }

    private static func u32(_ data: Data, _ offset: Int) -> UInt32 {
        UInt32(data[offset]) | UInt32(data[offset + 1]) << 8 | UInt32(data[offset + 2]) << 16 | UInt32(data[offset + 3]) << 24
    }

    static func header(dataBytes: UInt32) -> Data {
        var data = Data()
        func tag(_ text: String) { data.append(contentsOf: text.utf8) }
        func u16(_ value: UInt16) { var little = value.littleEndian; withUnsafeBytes(of: &little) { data.append(contentsOf: $0) } }
        func u32(_ value: UInt32) { var little = value.littleEndian; withUnsafeBytes(of: &little) { data.append(contentsOf: $0) } }
        tag("RIFF"); u32(36 + dataBytes); tag("WAVE"); tag("fmt "); u32(16)
        u16(1); u16(1); u32(16_000); u32(32_000); u16(2); u16(16)
        tag("data"); u32(dataBytes)
        return data
    }
}
