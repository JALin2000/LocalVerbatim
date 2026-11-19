import Foundation

@main struct OverlapTests {
    static func main() {
        func clean(_ previous: String, _ next: String, source: String = "microphone", start: Double = 17.25) -> String {
            let p = TranscriptSegment(id: "old", source: "microphone", start: 0, end: 18, text: previous, language: "")
            let c = AudioChunk(id: "new", source: source, start: start, end: 35.25, path: "/unused")
            return trimOverlap(previous: p, chunk: c, text: next)
        }
        precondition(clean("午餐准备好了，然后装。", "好了，然后装进餐盒。") == "进餐盒。")
        precondition(clean("清单最多填写。", "清单最多填写九项。") == "九项。")
        precondition(clean("在新建清单时，我们用。", "清单时，我们用CSV。") == "CSV。")
        precondition(clean("confirm the next steps.", "Next steps. Please send feedback.") == "Please send feedback.")
        precondition(clean("嗯嗯嗯嗯。", "嗯，嗯嗯嗯，你说。") == "嗯，嗯嗯嗯，你说。")
        precondition(clean("清单最多填写。", "清单最多填写九项。", start: 19) == "清单最多填写九项。")
        precondition(clean("清单最多填写。", "清单最多填写九项。", source: "system") == "清单最多填写九项。")
        precondition(clean("可以，可以。", "可以，可以，再试试。", start: 18) == "可以，可以，再试试。")
        precondition(clean("the problem", "the problems are different") == "the problems are different")
        print("PASS: overlap punctuation/case, Chinese seams, cross-source separation and legitimate repeats")
    }
}
