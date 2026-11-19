import Foundation

/// Human-readable library folders; working files stay out of the normal Finder view.
/// Individual moves are same-volume, non-overwriting and restartable. Readers
/// accept the legacy locations while an interrupted organization is completed.
enum MeetingFiles {
    static let workingDirectory = ".localverbatim"
    static func working(in folder: URL) -> URL { folder.appendingPathComponent(workingDirectory, isDirectory: true) }
    static func metadata(in folder: URL) -> URL { working(in: folder).appendingPathComponent("meeting.json") }
    static func readableMetadata(in folder: URL) -> URL {
        let current = metadata(in: folder)
        let legacy = folder.appendingPathComponent("meeting.json")
        return exists(current) || !exists(legacy) ? current : legacy
    }
    static func chunks(in folder: URL) -> URL { working(in: folder).appendingPathComponent("chunks", isDirectory: true) }
    static func chunk(_ name: String, in folder: URL) -> URL {
        let leaf = URL(fileURLWithPath: name).lastPathComponent
        let current = chunks(in: folder).appendingPathComponent(leaf)
        let legacy = folder.appendingPathComponent("chunks/\(leaf)")
        return exists(current) || !exists(legacy) ? current : legacy
    }
    static func results(in folder: URL) -> URL { working(in: folder).appendingPathComponent("results", isDirectory: true) }
    static func refinement(in folder: URL, runID: String) -> URL {
        working(in: folder).appendingPathComponent("refinement", isDirectory: true).appendingPathComponent(safeIdentifier(runID), isDirectory: true)
    }
    static func snapshot(in folder: URL) -> URL { working(in: folder).appendingPathComponent("transcript-original.json") }
    static func transcripts(in folder: URL) -> URL { folder.appendingPathComponent("Transcripts", isDirectory: true) }
    static func transcript(in folder: URL, format: String, refined: Bool = false) -> URL {
        transcripts(in: folder).appendingPathComponent("\(refined ? "refined" : "original").\(format)")
    }
    static func save(_ meeting: Meeting) throws {
        let target = readableMetadata(in: meeting.folder)
        try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(meeting).write(to: target, options: .atomic)
    }
    static func qualityFolder(audio: URL, refined: Bool) -> URL {
        // Live jobs use <meeting>/.localverbatim/chunks/file.wav; legacy jobs
        // can still use <meeting>/chunks/file.wav during recovery.
        let parent = audio.deletingLastPathComponent()
        let folder: URL
        if refined { folder = parent }
        else if parent.deletingLastPathComponent().lastPathComponent == workingDirectory {
            folder = parent.deletingLastPathComponent().deletingLastPathComponent()
        } else { folder = parent.deletingLastPathComponent() }
        return working(in: folder).appendingPathComponent("quality", isDirectory: true)
    }

    static func safeTitle(_ text: String) -> String {
        let forbidden = CharacterSet(charactersIn: "/\\:?*\"<>|").union(.controlCharacters)
        let cleaned = text.precomposedStringWithCanonicalMapping.unicodeScalars.map { forbidden.contains($0) ? " " : String($0) }.joined()
        let words = cleaned.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ").trimmingCharacters(in: CharacterSet(charactersIn: ". "))
        var result = ""
        for character in words {
            let next = result + String(character)
            if next.utf8.count > 140 { break }
            result = next
        }
        return result.isEmpty ? "Meeting" : result
    }
    static func safeIdentifier(_ text: String) -> String {
        let value = text.filter { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-") }
        return value.isEmpty ? "unknown" : String(value.prefix(80))
    }
    static func directoryName(for meeting: Meeting, fullID: Bool = false) -> String {
        let date = DateFormatter(); date.locale = Locale(identifier: "en_US_POSIX"); date.dateFormat = "yyyy-MM-dd HH-mm"
        let identifier = safeIdentifier(meeting.id)
        return "\(date.string(from: meeting.created)) · \(safeTitle(meeting.title)) [\(fullID ? identifier : String(identifier.prefix(8)))]"
    }
    static func assignNewFolder(_ meeting: inout Meeting) {
        let short = directoryName(for: meeting)
        meeting.directoryName = exists(AppPaths.recordings.appendingPathComponent(short)) ? directoryName(for: meeting, fullID: true) : short
    }
    static func rebase(_ meeting: inout Meeting) {
        let folder = meeting.folder
        meeting.chunks = meeting.chunks.map { old in
            AudioChunk(id: old.id, source: old.source, start: old.start, end: old.end,
                       path: chunk(URL(fileURLWithPath: old.path).lastPathComponent, in: folder).path)
        }
        if var run = meeting.refinement {
            run.chunks = run.chunks.map { old in
                AudioChunk(id: old.id, source: old.source, start: old.start, end: old.end,
                           path: folder.appendingPathComponent("\(old.source).wav").path)
            }
            meeting.refinement = run
        }
        meeting.refinementHistory = meeting.refinementHistory?.map { old in
            var run = old
            run.chunks = old.chunks.map { chunk in
                AudioChunk(id: chunk.id, source: chunk.source, start: chunk.start, end: chunk.end,
                           path: folder.appendingPathComponent("\(chunk.source).wav").path)
            }
            return run
        }
    }

    static func organize(_ meeting: inout Meeting) throws {
        let fm = FileManager.default
        let source = meeting.folder.standardizedFileURL
        guard source.deletingLastPathComponent() == AppPaths.recordings.standardizedFileURL,
              (try source.resourceValues(forKeys: [.isSymbolicLinkKey])).isSymbolicLink != true else {
            throw failure("Meeting folder must be a real directory inside the recording library.")
        }
        var destination = AppPaths.recordings.appendingPathComponent(directoryName(for: meeting), isDirectory: true)
        if source != destination.standardizedFileURL && exists(destination) {
            destination = AppPaths.recordings.appendingPathComponent(directoryName(for: meeting, fullID: true), isDirectory: true)
        }
        if source != destination.standardizedFileURL {
            guard !exists(destination) else { throw failure("A meeting folder with this name already exists. No files were overwritten.") }
            try fm.moveItem(at: source, to: destination)
            meeting.directoryName = destination.lastPathComponent
        }
        // Update the caller even if a later non-overwriting move fails.
        defer { rebase(&meeting) }
        let folder = meeting.folder
        try fm.createDirectory(at: working(in: folder), withIntermediateDirectories: true)
        try fm.createDirectory(at: results(in: folder), withIntermediateDirectories: true)
        try fm.createDirectory(at: transcripts(in: folder), withIntermediateDirectories: true)
        let legacyMetadata = folder.appendingPathComponent("meeting.json")
        let archive = working(in: folder).appendingPathComponent("legacy-meeting.json")
        if exists(legacyMetadata), !exists(archive) {
            try Data(contentsOf: legacyMetadata).write(to: archive, options: .withoutOverwriting)
        }
        try moveIfPresent(folder.appendingPathComponent("chunks"), chunks(in: folder))
        try moveIfPresent(folder.appendingPathComponent("refinement"), working(in: folder).appendingPathComponent("refinement"))
        try moveIfPresent(folder.appendingPathComponent("transcript-original.json"), snapshot(in: folder))
        for item in try fm.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.isRegularFileKey]) where item.lastPathComponent.hasSuffix(".result.json") {
            try moveIfPresent(item, results(in: folder).appendingPathComponent(item.lastPathComponent))
        }
        for ext in ["txt", "md", "srt"] {
            try moveIfPresent(folder.appendingPathComponent("transcript.\(ext)"), transcript(in: folder, format: ext))
            try moveIfPresent(folder.appendingPathComponent("transcript-refined.\(ext)"), transcript(in: folder, format: ext, refined: true))
        }
        // Metadata is moved last. A restart can find either location, and
        // filenames/absolute chunk paths are rebound from the actual folder.
        try moveIfPresent(legacyMetadata, metadata(in: folder))
    }
    private static func moveIfPresent(_ from: URL, _ to: URL) throws {
        guard exists(from) else { return }
        guard !exists(to) else { throw failure("File organization stopped because a destination exists: \(to.lastPathComponent). Both copies were retained.") }
        try FileManager.default.moveItem(at: from, to: to)
    }
    private static func exists(_ path: URL) -> Bool { FileManager.default.fileExists(atPath: path.path) }
    private static func failure(_ message: String) -> NSError { NSError(domain: "LocalVerbatim.MeetingFiles", code: 1, userInfo: [NSLocalizedDescriptionKey: message]) }
}
