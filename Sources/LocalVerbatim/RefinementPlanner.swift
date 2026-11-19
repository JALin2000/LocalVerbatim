import Foundation

/// Plans bounded 30-second reads of finalized archives. Audio is never copied
/// into a second recording or loaded into memory for the whole meeting.
enum RefinementPlanner {
    static func plan(folder: URL) throws -> [AudioChunk] {
        var jobs: [AudioChunk] = []
        for source in ["microphone", "system"] {
            let path = folder.appendingPathComponent("\(source).wav")
            let handle = try FileHandle(forReadingFrom: path)
            defer { try? handle.close() }
            guard let header = try handle.read(upToCount: 44), header.count == 44 else { throw failure("录音文件头不完整") }
            func u16(_ i: Int) -> UInt16 { UInt16(header[i]) | UInt16(header[i+1]) << 8 }
            func u32(_ i: Int) -> UInt32 { UInt32(header[i]) | UInt32(header[i+1]) << 8 | UInt32(header[i+2]) << 16 | UInt32(header[i+3]) << 24 }
            guard String(data: header[0..<4], encoding: .ascii) == "RIFF",
                  String(data: header[8..<12], encoding: .ascii) == "WAVE",
                  String(data: header[36..<40], encoding: .ascii) == "data",
                  u16(20) == 1, u16(22) == 1, u32(24) == 16_000, u16(34) == 16 else {
                throw failure("二次识别需要完整的 16 kHz 单声道 PCM16 录音")
            }
            let size = try handle.seekToEnd()
            guard size >= 44, UInt64(u32(40)) == size - 44, (size - 44) % 2 == 0 else { throw failure("录音尚未完整保存，请先恢复录音") }
            let total = Int64((size - 44) / 2)
            var first: Int64 = 0
            while first < total {
                try Task.checkCancellation()
                let count = Int(min(480_000, total - first))
                try handle.seek(toOffset: 44 + UInt64(first) * 2)
                var audio = Data()
                while audio.count < count * 2 {
                    guard let part = try handle.read(upToCount: count * 2 - audio.count), !part.isEmpty else { throw failure("读取录音失败") }
                    audio.append(part)
                }
                let boundary = first + Int64(count) == total ? (count, 0) : chooseBoundary(audio)
                let end = first + Int64(boundary.0)
                jobs.append(AudioChunk(id: "refine-\(source)-\(first)", source: source,
                                       start: Double(first) / 16_000, end: Double(end) / 16_000, path: path.path))
                if end == total { break }
                first = end - Int64(boundary.1)
            }
        }
        return jobs.sorted { $0.start == $1.start ? $0.source < $1.source : $0.start < $1.start }
    }

    static func chooseBoundary(_ audio: Data) -> (Int, Int) {
        let frames = audio.count / 2
        var chosen = (frames, min(16_000, max(0, frames - 1)))
        var gap: Int?
        func consider(_ end: Int) {
            if let start = gap, end - start >= 9_600, end >= 352_000 {
                chosen = (end, min(16_000, end - start))
            }
        }
        audio.withUnsafeBytes { (bytes: UnsafeRawBufferPointer) in
            for start in stride(from: 0, to: frames, by: 320) {
                let end = min(frames, start + 320)
                var energy: Int64 = 0, peak = 0
                for i in start..<end {
                    let value = Int(Int16(bitPattern: UInt16(bytes[2*i]) | UInt16(bytes[2*i+1]) << 8))
                    energy += Int64(value * value); peak = max(peak, abs(value))
                }
                if energy <= Int64(end - start) * 65 * 65 && peak <= 328 {
                    if gap == nil { gap = start }
                } else { consider(start); gap = nil }
            }
        }
        consider(frames)
        return chosen
    }

    private static func failure(_ description: String) -> NSError {
        NSError(domain: "LocalVerbatim.Refinement", code: 1, userInfo: [NSLocalizedDescriptionKey: description])
    }
}
