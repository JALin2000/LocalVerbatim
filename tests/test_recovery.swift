// Run with tests/run_swift_tests.sh. These are offline synthetic recordings.
import Foundation
import Darwin

@main
struct RecoveryChecks {
    static func main() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("localverbatim-recovery-\(UUID().uuidString)", isDirectory: true)
        setenv("LOCALVERBATIM_ROOT", root.path, 1)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try missingTailMovedPathsAndHeader()
        try missingPendingChunk()
        try emptyAndExactBoundaries()
        try invalidFormatsStayUntouched()
        try halfWrittenSample()
        try adaptivePauseRecovery()
        print("PASS: recovery repairs checkpoint headers; reconstructs missing/tail jobs; rebases moved paths; preserves completed IDs and existing files; is idempotent; handles silence, empty archives, exact boundaries, invalid formats and partial samples")
    }

    private static func missingTailMovedPathsAndHeader() throws {
        var meeting = Meeting()
        meeting.status = "interrupted"
        let chunks = meeting.folder.appendingPathComponent("chunks")
        try FileManager.default.createDirectory(at: chunks, withIntermediateDirectories: true)
        let archive = meeting.folder.appendingPathComponent("microphone.wav")
        try makeWave(archive, frames: 960_000, declaredFrames: 0)
        try makeWave(meeting.folder.appendingPathComponent("system.wav"), frames: 960_000, silence: true)
        let existing = chunks.appendingPathComponent("microphone-276000.wav")
        try makeWave(existing, frames: 288_000)
        let existingBytes = try Data(contentsOf: existing)
        let orphan = chunks.appendingPathComponent("microphone-828000.wav")
        try makeWave(orphan, frames: 100, declaredFrames: 132_000)
        let orphanBytes = try Data(contentsOf: orphan)
        meeting.duration = 12
        meeting.completedIDs = ["microphone-0"]
        meeting.chunks = [
            AudioChunk(id: "microphone-0", source: "microphone", start: 0, end: 18, path: "/old/install/Recordings/microphone-0.wav"),
            AudioChunk(id: "microphone-276000", source: "microphone", start: 17.25, end: 35.25, path: "/old/install/Recordings/microphone-276000.wav")
        ]
        let result = try RecordingRecovery.recover(meeting)
        precondition(result.duration == 60)
        precondition(result.status == "interrupted")
        precondition(result.completedIDs == meeting.completedIDs)
        precondition(result.chunks.count == 4 && result.outstanding.count == 3)
        precondition(result.chunks.map(\.id) == ["microphone-0", "microphone-276000", "microphone-552000", "microphone-828000"])
        precondition(result.chunks.allSatisfy { $0.path.hasPrefix(chunks.path + "/") || $0.path.hasPrefix(MeetingFiles.chunks(in: meeting.folder).path + "/") })
        precondition(result.chunks.last!.start == 51.75 && result.chunks.last!.end == 60)
        precondition(result.chunks.last!.path == MeetingFiles.chunks(in: meeting.folder).appendingPathComponent("microphone-828000.wav").path) // The malformed legacy orphan remains untouched.
        let existingAfter = try Data(contentsOf: existing)
        let orphanAfter = try Data(contentsOf: orphan)
        precondition(existingAfter == existingBytes)
        precondition(orphanAfter == orphanBytes)
        precondition(!FileManager.default.fileExists(atPath: chunks.appendingPathComponent("microphone-0.wav").path))
        let repaired = try prefix(archive)
        precondition(u32(repaired, 40) == 1_920_000 && u32(repaired, 4) == 1_920_036)
        let again = try RecordingRecovery.recover(result)
        precondition(again.chunks.map(\.path) == result.chunks.map(\.path))
        precondition(again.chunks.map(\.id) == result.chunks.map(\.id))
        precondition(again.completedIDs == result.completedIDs)
    }

    private static func missingPendingChunk() throws {
        var meeting = Meeting()
        try FileManager.default.createDirectory(at: meeting.folder, withIntermediateDirectories: true)
        try makeWave(meeting.folder.appendingPathComponent("microphone.wav"), frames: 288_000)
        meeting.chunks = [AudioChunk(id: "microphone-0", source: "microphone", start: 0, end: 18, path: "/missing/microphone-0.wav")]
        let result = try RecordingRecovery.recover(meeting)
        precondition(result.chunks.count == 1)
        precondition(FileManager.default.fileExists(atPath: result.chunks[0].path))
        let restoredHeader = try prefix(URL(fileURLWithPath: result.chunks[0].path))
        precondition(restoredHeader.count == 44)
    }

    private static func emptyAndExactBoundaries() throws {
        let absent = Meeting()
        let absentResult = try RecordingRecovery.recover(absent)
        precondition(absentResult.chunks.isEmpty && absentResult.duration == 0)
        let empty = Meeting()
        try FileManager.default.createDirectory(at: empty.folder, withIntermediateDirectories: true)
        try makeWave(empty.folder.appendingPathComponent("microphone.wav"), frames: 0)
        let emptyResult = try RecordingRecovery.recover(empty)
        precondition(emptyResult.chunks.isEmpty && emptyResult.duration == 0)
        let exact = Meeting()
        try FileManager.default.createDirectory(at: exact.folder, withIntermediateDirectories: true)
        try makeWave(exact.folder.appendingPathComponent("system.wav"), frames: 288_000)
        let exactResult = try RecordingRecovery.recover(exact)
        precondition(exactResult.chunks.count == 1 && exactResult.duration == 18)
        let partial = Meeting()
        try FileManager.default.createDirectory(at: partial.folder, withIntermediateDirectories: true)
        try makeWave(partial.folder.appendingPathComponent("system.wav"), frames: 8_000)
        let partialResult = try RecordingRecovery.recover(partial)
        precondition(partialResult.chunks.count == 1 && partialResult.chunks[0].end == 0.5)
    }

    private static func invalidFormatsStayUntouched() throws {
        let meeting = Meeting()
        try FileManager.default.createDirectory(at: meeting.folder, withIntermediateDirectories: true)
        let archive = meeting.folder.appendingPathComponent("microphone.wav")
        try makeWave(archive, frames: 16_000, declaredFrames: 0)
        var data = try Data(contentsOf: archive)
        data[24] = 0x40; data[25] = 0x1f // 8000 Hz instead of 16000
        try data.write(to: archive)
        var failed = false
        do { _ = try RecordingRecovery.recover(meeting) } catch { failed = true }
        precondition(failed, "invalid format must fail")
        let invalidAfter = try Data(contentsOf: archive)
        precondition(invalidAfter == data, "invalid format must not be modified")
        try Data([0, 1, 2]).write(to: archive)
        failed = false
        do { _ = try RecordingRecovery.recover(meeting) } catch { failed = true }
        precondition(failed, "truncated header must fail")
    }

    private static func halfWrittenSample() throws {
        let meeting = Meeting()
        try FileManager.default.createDirectory(at: meeting.folder, withIntermediateDirectories: true)
        let archive = meeting.folder.appendingPathComponent("microphone.wav")
        try makeWave(archive, frames: 16_000)
        let handle = try FileHandle(forWritingTo: archive)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data([128]))
        try handle.close()
        let result = try RecordingRecovery.recover(meeting)
        precondition(result.duration == 1 && result.chunks.count == 1)
        let size = (try FileManager.default.attributesOfItem(atPath: archive.path)[.size] as! NSNumber).intValue
        precondition(size == 32_044)
    }

    private static func adaptivePauseRecovery() throws {
        var meeting = Meeting()
        try FileManager.default.createDirectory(at: meeting.folder, withIntermediateDirectories: true)
        let archive = meeting.folder.appendingPathComponent("microphone.wav")
        try makeWave(archive, frames: 400_000)
        let handle = try FileHandle(forWritingTo: archive)
        try handle.seek(toOffset: 44 + 204_160 * 2)
        try handle.write(contentsOf: Data(repeating: 0, count: (218_880 - 204_160) * 2))
        try handle.close()
        let result = try RecordingRecovery.recover(meeting)
        precondition(result.chunks.count == 2)
        precondition(result.chunks[0].end == 13.68 && result.chunks[1].start == 12.93)
        precondition(result.chunks[1].id == "microphone-206880")
        let again = try RecordingRecovery.recover(result)
        precondition(again.chunks.map(\.id) == result.chunks.map(\.id))
        // Completed legacy windows must not be replaced by new pause cuts.
        meeting.chunks = [AudioChunk(id: "microphone-0", source: "microphone", start: 0, end: 18, path: "/old/microphone-0.wav")]
        meeting.completedIDs = ["microphone-0"]
        let legacy = try RecordingRecovery.recover(meeting)
        precondition(legacy.completedIDs == meeting.completedIDs)
        precondition(legacy.chunks.first!.end == 18 && legacy.chunks.last!.start == 17.25)
    }

    private static func makeWave(_ url: URL, frames: Int, declaredFrames: Int? = nil, silence: Bool = false) throws {
        var header = Data()
        func tag(_ value: String) { header.append(contentsOf: value.utf8) }
        func word(_ value: UInt16) { header.append(UInt8(value & 255)); header.append(UInt8(value >> 8)) }
        func dword(_ value: UInt32) { for shift in [0, 8, 16, 24] { header.append(UInt8((value >> shift) & 255)) } }
        let bytes = UInt32((declaredFrames ?? frames) * 2)
        tag("RIFF"); dword(36 + bytes); tag("WAVE"); tag("fmt "); dword(16)
        word(1); word(1); dword(16000); dword(32000); word(2); word(16); tag("data"); dword(bytes)
        precondition(FileManager.default.createFile(atPath: url.path, contents: header))
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        try handle.seekToEnd()
        let block = Data(repeating: silence ? 0 : 17, count: 32_000)
        var remaining = frames * 2
        while remaining > 0 {
            let count = min(remaining, block.count)
            try handle.write(contentsOf: block.prefix(count))
            remaining -= count
        }
    }

    private static func prefix(_ url: URL) throws -> Data {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        return try handle.read(upToCount: 44) ?? Data()
    }

    private static func u32(_ data: Data, _ index: Int) -> UInt32 {
        UInt32(data[index]) | UInt32(data[index + 1]) << 8 | UInt32(data[index + 2]) << 16 | UInt32(data[index + 3]) << 24
    }
}
