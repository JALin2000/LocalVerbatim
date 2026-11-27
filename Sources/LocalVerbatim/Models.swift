import Foundation

enum AppIdentity {
    static let englishName = "LocalVerbatim"
    static let chineseName = "本地逐字稿"
    static var displayName: String { tr(chineseName, englishName) }

    // Stable identifiers from the original installation. A display-name change
    // must not create an empty library, lose templates, or move audio paths.
    static let bundleIdentifier = "local.localscribe.meeting-recorder"
    static let dataDirectoryName = "LocalScribe"
    static var rootOverride: String? {
        let environment = ProcessInfo.processInfo.environment
        return environment["LOCALVERBATIM_ROOT"] ?? environment["LOCALSCRIBE_ROOT"]
    }
}

enum ModelVariant: String, Codable, CaseIterable {
    case bf16, quantized = "8bit"

    static func recommended(for ramBytes: UInt64 = ProcessInfo.processInfo.physicalMemory) -> Self {
        ramBytes <= 8 * 1_073_741_824 ? .quantized : .bf16
    }

    var directory: String { "Qwen3-ASR-1.7B-" + rawValue }
    var title: String { self == .bf16 ? "BF16" : tr("8 位量化", "8-bit quantized") }
    var downloadSize: String { self == .bf16 ? "4.08 GB" : "2.47 GB" }
    var downloadBytes: Int64 { self == .bf16 ? 4_080_000_000 : 2_470_000_000 }
}

enum AppPaths {
    static let bundledSupport: URL? = {
        guard let resources = Bundle.main.resourceURL else { return nil }
        let support = resources.appendingPathComponent("Support", isDirectory: true)
        return FileManager.default.fileExists(atPath: support.appendingPathComponent("engine/worker.py").path) ? support : nil
    }()
    static let root: URL = {
        if let override = AppIdentity.rootOverride {
            return URL(fileURLWithPath: override, isDirectory: true)
        }
        return bundledSupport ?? Bundle.main.bundleURL.deletingLastPathComponent()
    }()
    static let dataRoot: URL = {
        if AppIdentity.rootOverride != nil || bundledSupport == nil { return root }
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return support.appendingPathComponent(AppIdentity.dataDirectoryName, isDirectory: true)
    }()
    static var recordings: URL { AppSettings.shared.recordingsDirectory }
    static var modelVariant: ModelVariant {
        if let choice = AppSettings.shared.options.modelVariant { return choice }
        // Keep the installed model for existing users. On a fresh install,
        // the recommendation determines which of the two choices is offered first.
        return ModelVariant.allCases.first(where: { installedModel($0) != nil }) ?? .recommended()
    }

    static func installedModel(_ variant: ModelVariant) -> URL? {
        let settings = AppSettings.shared
        let cache = settings.modelCacheDirectory.appendingPathComponent(variant.directory, isDirectory: true)
        let bundled = root.appendingPathComponent("models").appendingPathComponent(variant.directory, isDirectory: true)
        let locations = settings.options.modelCachePath == nil ? [cache, bundled] : [cache]
        return locations.first {
            FileManager.default.fileExists(atPath: $0.appendingPathComponent("config.json").path) &&
            FileManager.default.fileExists(atPath: $0.appendingPathComponent("model.safetensors").path)
        }
    }

    static var model: URL {
        let variant = modelVariant
        return installedModel(variant) ?? AppSettings.shared.modelCacheDirectory.appendingPathComponent(variant.directory)
    }
    static var python: URL { root.appendingPathComponent("runtime/bin/python") }
    static var worker: URL { root.appendingPathComponent("engine/worker.py") }
}

struct TranscriptSegment: Codable, Identifiable {
    var id: String
    var source: String
    var start: Double
    var end: Double
    var text: String
    var language: String
    var speaker: String {
        switch source {
        case "microphone": return tr("我", "Me")
        case "imported": return tr("录音", "Recording")
        default: return tr("与会者", "Participants")
        }
    }
}

struct RecognitionHints: Codable, Equatable {
    var templateID: String?
    var vocabulary = ""
    var context = ""
}

struct TermTemplate: Codable, Identifiable {
    var id = UUID().uuidString
    var name: String
    var vocabulary: String
    var context: String
}

struct MeetingPreferences: Codable {
    var templates: [TermTemplate] = []
    var lastMeetingID: String?
    var lastUsedHints: RecognitionHints?
}

struct RefinementRun: Codable, Identifiable {
    var id = UUID().uuidString
    var created = Date()
    var finished: Date?
    var state = "waiting"
    var error: String?
    var language = ""
    var vocabulary = ""
    var context = ""
    var chunks: [AudioChunk] = []
    var completedIDs: [String] = []
    var segments: [TranscriptSegment] = []
    var isActive: Bool { ["waiting", "planning", "queued", "running"].contains(state) }
    var outstanding: [AudioChunk] { chunks.filter { !completedIDs.contains($0.id) } }
    var fraction: Double { chunks.isEmpty ? (state == "complete" ? 1 : 0) : Double(completedIDs.count) / Double(chunks.count) }
}

struct Meeting: Codable, Identifiable {
    var id = UUID().uuidString
    var directoryName: String? = nil
    var title = tr("未命名会议", "Untitled meeting")
    var created = Date()
    var duration: Double = 0
    var peakMemoryGB: Double?
    var status = "draft"
    var language = ""
    var vocabulary: String?
    var recognitionContext: String?
    var templateID: String?
    var autoRefineRequested: Bool?
    var importedAudioFilename: String?
    var isImported: Bool { importedAudioFilename != nil }
    var audioSources: [String] { isImported ? ["imported"] : ["microphone", "system"] }
    var refinement: RefinementRun?
    var refinementHistory: [RefinementRun]?
    var notes = ""
    var chunks: [AudioChunk] = []
    var completedIDs: [String] = []
    var segments: [TranscriptSegment] = []
    var folder: URL {
        let name = directoryName.flatMap { value in
            value != "." && value != ".." && !value.contains("/") && !value.contains("\\") && !value.contains("\0") ? value : nil
        } ?? id
        return AppPaths.recordings.appendingPathComponent(name, isDirectory: true)
    }
    var ordered: [TranscriptSegment] { segments.sorted { $0.start == $1.start ? $0.source < $1.source : $0.start < $1.start } }
    var outstanding: [AudioChunk] { chunks.filter { !completedIDs.contains($0.id) } }
    var hints: RecognitionHints { RecognitionHints(templateID: templateID, vocabulary: vocabulary ?? "", context: recognitionContext ?? "") }

    func ordered(version: String) -> [TranscriptSegment] {
        guard let run = refinementRun(version: version) else { return ordered }
        return run.segments.sorted { $0.start == $1.start ? $0.source < $1.source : $0.start < $1.start }
    }

    static func historyVersion(_ run: RefinementRun) -> String { "refinement:\(run.id)" }

    func refinementRun(version: String) -> RefinementRun? {
        if version == "refined" { return refinement }
        return refinementHistory?.first { Self.historyVersion($0) == version }
    }

    var preferredTranscriptVersion: String {
        if refinement?.state == "complete" { return "refined" }
        if let previous = refinementHistory?.last(where: { $0.state == "complete" }) { return Self.historyVersion(previous) }
        return "original"
    }

    func displayText(_ text: String, version: String, reduceFillers: Bool) -> String {
        guard reduceFillers else { return text }
        let clean = FillerReducer.reduce(text, reduceRepetitions: refinementRun(version: version) != nil)
        return clean.isEmpty ? tr("（语气词已省略）", "(Filler words omitted)") : clean
    }

    func exportText(format: String, version: String = "original", reduceFillers: Bool = false) -> String {
        let ordered = ordered(version: version).map { segment -> TranscriptSegment in
            var value = segment
            value.text = displayText(segment.text, version: version, reduceFillers: reduceFillers)
            return value
        }
        let heading = refinementRun(version: version) != nil ? title + tr(" · 二次识别", " · Second pass") : title
        if format == "srt" {
            return ordered.enumerated().map { i, s in
                "\(i + 1)\n\(srtTime(s.start)) --> \(srtTime(s.end))\n[\(s.speaker)] \(s.text)\n"
            }.joined(separator: "\n")
        }
        let lines = ordered.map { "[\(clockText($0.start))] \($0.speaker): \($0.text)" }.joined(separator: "\n\n")
        if format == "md" {
            return "# \(heading)\n\n\(formattedDate(created, time: true)) · \(clockText(duration))\n\n## \(tr("逐字稿", "Transcript"))\n\n\(lines)\n\n## \(tr("我的笔记", "My notes"))\n\n\(notes)\n"
        }
        return "\(heading)\n\n\(lines)\n\n\(tr("我的笔记", "My notes"))\n\(notes)\n"
    }
}

func clockText(_ seconds: Double) -> String {
    let total = max(0, Int(seconds))
    if total >= 3600 { return String(format: "%02d:%02d:%02d", total / 3600, total / 60 % 60, total % 60) }
    return String(format: "%02d:%02d", total / 60, total % 60)
}

func srtTime(_ seconds: Double) -> String {
    let ms = max(0, Int((seconds * 1000).rounded()))
    return String(format: "%02d:%02d:%02d,%03d", ms / 3_600_000, ms / 60_000 % 60, ms / 1000 % 60, ms % 1000)
}

// Only remove an exact lexical suffix/prefix in the known audio overlap.
// Ignore punctuation/case differences, keep fillers and non-overlapping repeats.
// Recordings and original model output remain in the job results on disk.
func trimOverlap(previous: TranscriptSegment?, chunk: AudioChunk, text: String) -> String {
    guard let previous, previous.source == chunk.source,
          chunk.start < previous.end, previous.end - chunk.start <= 2 else { return text }
    func normalized(_ value: String) -> [(Character, String.Index)] {
        var result: [(Character, String.Index)] = []
        for index in value.indices {
            let end = value.index(after: index)
            for character in String(value[index]).lowercased() where character.isLetter || character.isNumber {
                result.append((character, end))
            }
        }
        return result
    }
    let old = normalized(previous.text).map(\.0), new = normalized(text)
    let maximum = min(32, old.count, new.count)
    guard maximum >= 4 else { return text }
    let fillers = Set("嗯啊哦呃哎唉诶哈额唔喔")
    for count in stride(from: maximum, through: 4, by: -1) {
        let prefix = new.prefix(count).map(\.0)
        guard Array(old.suffix(count)) == prefix else { continue }
        let han = prefix.filter { $0.unicodeScalars.contains { (0x3400...0x9FFF).contains($0.value) } }
        let boundary = new[count - 1].1
        let rawPrefix = text[..<boundary]
        let latinWords = rawPrefix.split { !$0.isLetter && !$0.isNumber }.filter {
            $0.unicodeScalars.allSatisfy { $0.isASCII }
        }
        let meaningfulHan = han.filter { !fillers.contains($0) }.count
        let cutsLatinWord = boundary < text.endIndex && text[boundary].unicodeScalars.allSatisfy {
            $0.isASCII && CharacterSet.alphanumerics.contains($0)
        }
        if (meaningfulHan >= 4 && han.count <= 12) || (han.isEmpty && !cutsLatinWord && latinWords.count >= 2 && latinWords.count <= 6) {
            let separators = CharacterSet.whitespacesAndNewlines.union(.punctuationCharacters)
            return String(text[boundary...].drop(while: { $0.unicodeScalars.allSatisfy { separators.contains($0) } }))
        }
    }
    return text
}
