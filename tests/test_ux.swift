import Foundation

@main struct UXChecks {
    @MainActor static func main() async throws {
        guard ProcessInfo.processInfo.environment["LOCALVERBATIM_ROOT"] != nil else { fatalError("Isolated root required") }
        let root = AppPaths.dataRoot
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let file = root.appendingPathComponent("partial-settings.json")
        try Data("{\"interfaceLanguage\":\"en\",\"textSize\":18}".utf8).write(to: file)
        let settings = AppSettings(file: file)
        precondition(settings.options.textSize == 18 && settings.options.recordingBadge && settings.options.autoRefine)
        precondition(settings.options.interfaceTextSize == .standard && settings.options.modelVariant == nil)
        precondition(AppSettings.systemInterfaceLanguage(["zh-CN"]) == "zh-Hans")
        precondition(AppSettings.systemInterfaceLanguage(["zh-Hant-TW"]) == "zh-Hans")
        precondition(AppSettings.systemInterfaceLanguage(["en-GB", "zh-CN"]) == "en")
        precondition(AppSettings.systemInterfaceLanguage(["fr-FR"]) == "en")
        precondition(InterfaceTextSize.small.scale < InterfaceTextSize.standard.scale &&
                     InterfaceTextSize.standard.scale < InterfaceTextSize.large.scale)
        let gib: UInt64 = 1_073_741_824
        precondition(ModelVariant.recommended(for: 8 * gib) == .quantized)
        precondition(ModelVariant.recommended(for: 8 * gib + 1) == .bf16)
        precondition(ModelVariant.recommended(for: 16 * gib) == .bf16)
        precondition(settings.update {
            $0.hideDockForHotkeys = true
            $0.interfaceTextSize = .large
            $0.modelVariant = .quantized
        })
        precondition(AppSettings(file: file).options.interfaceTextSize == .large)
        precondition(AppSettings(file: file).options.modelVariant == .quantized)
        precondition(AppSettings(file: file).options.hideDockForHotkeys)
        let badFile = root.appendingPathComponent("not-a-directory"); try Data().write(to: badFile)
        let failed = AppSettings(file: badFile.appendingPathComponent("settings.json"))
        precondition(!failed.update { $0.interfaceLanguage = "zh-Hans" })
        precondition(failed.options.interfaceLanguage == "system")

        let parsed = Vocabulary.adding("Acme,API，中文；Acme\nAPI\nProject plan", to: [])
        precondition(parsed.terms == ["Acme", "API", "中文", "Project plan"] && parsed.duplicates == 2)
        let bounded = Vocabulary.adding((0..<45).map { "word\($0)" }.joined(separator: ","), to: [])
        precondition(bounded.terms.count == 40 && bounded.rejected == 5)
        precondition(Vocabulary.adding(String(repeating: "长", count: 81), to: []).terms.isEmpty)

        let source = root.appendingPathComponent("source"), target = root.appendingPathComponent("target")
        try FileManager.default.createDirectory(at: source.appendingPathComponent("nested"), withIntermediateDirectories: true)
        let bytes = Data((0..<4096).map { UInt8($0 % 251) })
        try bytes.write(to: source.appendingPathComponent("nested/audio.wav"))
        try StorageMigration.copyVerified(from: source, to: target)
        let originalHashes = try StorageMigration.hashes(in: source)
        let copiedHashes = try StorageMigration.hashes(in: target)
        precondition(originalHashes == copiedHashes)
        do { try StorageMigration.copyVerified(from: source, to: source.appendingPathComponent("inside")); fatalError("Nested destination accepted") } catch {}
        do { try StorageMigration.copyVerified(from: source, to: target); fatalError("Existing directory overwritten") } catch {}
        let intact = try Data(contentsOf: source.appendingPathComponent("nested/audio.wav")); precondition(intact == bytes)

        precondition(FillerReducer.reduce("嗯，呃，我们讨论 API，然后确认预算。") == "我们讨论 API，然后确认预算。")
        precondition(FillerReducer.reduce("Um, uh, no, I do not agree.") == "no, I do not agree.")
        precondition(FillerReducer.reduce("The album is human-made. “um” is a filler. 阿里云 API") == "The album is human-made. “um” is a filler. 阿里云 API")
        precondition(FillerReducer.reduce("嗯嗯嗯，啊。") == "")
        var meeting = Meeting()
        meeting.segments = [TranscriptSegment(id: "original", source: "microphone", start: 900, end: 918, text: "嗯，API 不是这个意思。", language: "Chinese")]
        let raw = meeting.exportText(format: "txt")
        let reduced = meeting.exportText(format: "txt", reduceFillers: true)
        precondition(raw.contains("嗯，API") && !reduced.contains("嗯，API") && reduced.contains("API 不是这个意思。"))
        precondition(meeting.segments[0].text == "嗯，API 不是这个意思。" && meeting.segments[0].start == 900)

        // A reading filter must agree across the UI/export paths and preserve
        // raw/current/historical source text, timing, and technical content.
        let speech = "嗯，我我我先整理这个这个书签，API API，不不不，不能删掉否定。"
        meeting.segments[0].text = speech
        var run = RefinementRun(); run.state = "complete"
        run.segments = [TranscriptSegment(id: "refined", source: "system", start: 900, end: 918, text: speech, language: "Chinese")]
        meeting.refinement = run
        var older = run; older.id = "earlier-pass"; meeting.refinementHistory = [older]
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        let beforeReading = try encoder.encode(meeting)
        precondition(meeting.displayText(speech, version: "original", reduceFillers: true).contains("我我我"))
        for version in ["refined", Meeting.historyVersion(older)] {
            let display = meeting.displayText(speech, version: version, reduceFillers: true)
            precondition(display.contains("我先整理这个书签") && display.contains("API API") && display.contains("不不不"))
            precondition(meeting.displayText(speech, version: version, reduceFillers: false) == speech)
            for format in ["txt", "md", "srt"] {
                precondition(meeting.exportText(format: format, version: version, reduceFillers: true).contains(display))
                precondition(meeting.exportText(format: format, version: version).contains(speech))
            }
            precondition(meeting.exportText(format: "srt", version: version, reduceFillers: true).contains("00:15:00,000 --> 00:15:18,000"))
        }
        let afterReading = try encoder.encode(meeting)
        precondition(beforeReading == afterReading, "Reading/export cleanup mutated stored transcripts or timings")

        let began = Date()
        do {
            let _: Bool = try await boundedOperation(seconds: 0.02, message: "timeout") {
                await withCheckedContinuation { continuation in
                    DispatchQueue.global().asyncAfter(deadline: .now() + 0.2) { continuation.resume(returning: true) }
                }
            }
            fatalError("Uncooperative callback exceeded the deadline")
        } catch { precondition(Date().timeIntervalSince(began) < 0.15) }
        let pending = Task { @MainActor in
            try await boundedOperation(seconds: 10, message: "timeout") {
                await withCheckedContinuation { continuation in
                    DispatchQueue.global().asyncAfter(deadline: .now() + 0.2) { continuation.resume(returning: true) }
                }
            }
        }
        pending.cancel()
        do { _ = try await pending.value; fatalError("Cancellation was ignored") } catch is CancellationError {} catch { fatalError("Unexpected error") }
        try await Task.sleep(nanoseconds: 300_000_000) // Late callbacks must not double-resume.
        print("PASS: partial settings migration, atomic persistence failure, comma/chip parser limits, verified storage copy, original retention, unsafe destination rejection, timeout/cancellation with late OS callbacks")
    }
}
