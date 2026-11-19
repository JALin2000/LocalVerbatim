import Foundation

@main struct RefinementChecks {
    static func main() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("localverbatim-refinement-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let frames = 1_028_000 // 64.25 seconds
        var wave = Data()
        func tag(_ s: String) { wave.append(contentsOf: s.utf8) }
        func u16(_ x: UInt16) { var v = x.littleEndian; withUnsafeBytes(of: &v) { wave.append(contentsOf: $0) } }
        func u32(_ x: UInt32) { var v = x.littleEndian; withUnsafeBytes(of: &v) { wave.append(contentsOf: $0) } }
        tag("RIFF"); u32(UInt32(36 + frames * 2)); tag("WAVE"); tag("fmt "); u32(16)
        u16(1); u16(1); u32(16_000); u32(32_000); u16(2); u16(16); tag("data"); u32(UInt32(frames * 2))
        for i in 0..<frames {
            let silent = (352_000..<363_200).contains(i) // 22–22.7s pause
            u16(UInt16(bitPattern: Int16(silent ? 0 : (i % 16 < 8 ? 6000 : -6000))))
        }
        for source in ["microphone", "system"] { try wave.write(to: folder.appendingPathComponent("\(source).wav")) }
        let jobs = try RefinementPlanner.plan(folder: folder)
        for source in ["microphone", "system"] {
            let track = jobs.filter { $0.source == source }.sorted { $0.start < $1.start }
            precondition(track.first!.start == 0 && abs(track.last!.end - 64.25) < 0.00001)
            precondition(abs(track.first!.end - 22.7) < 0.00001, "Planner missed the pause end")
            precondition(Set(track.map(\.id)).count == track.count)
            for (index, job) in track.enumerated() {
                precondition(job.end - job.start <= 30 && job.end > job.start)
                if index > 0 {
                    let overlap = track[index - 1].end - job.start
                    precondition(overlap >= 0 && overlap <= 1.00001, "Audio gap or excess overlap")
                }
            }
        }
        var invalid = wave; invalid[24] = 0
        try invalid.write(to: folder.appendingPathComponent("system.wav"))
        do { _ = try RefinementPlanner.plan(folder: folder); preconditionFailure("Invalid rate accepted") }
        catch {}
        print("PASS: bounded 30-second plans, pause boundaries, no gaps, equal source coverage, format rejection")
    }
}
