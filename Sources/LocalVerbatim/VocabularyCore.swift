import Foundation

struct VocabularyUpdate {
    var terms: [String]
    var added = 0
    var duplicates = 0
    var rejected = 0
}

enum Vocabulary {
    static let separators = CharacterSet(charactersIn: ",，;；、\n\r\t")
    static func terms(_ value: String) -> [String] {
        value.components(separatedBy: separators).map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
    }
    static func adding(_ input: String, to existing: [String]) -> VocabularyUpdate {
        var result = VocabularyUpdate(terms: existing)
        var seen = Set(existing.map { $0.lowercased() })
        for term in terms(input) {
            if seen.contains(term.lowercased()) { result.duplicates += 1; continue }
            guard term.count <= 80, result.terms.count < 40,
                  (result.terms + [term]).joined(separator: ", ").count <= 2000 else { result.rejected += 1; continue }
            result.terms.append(term); seen.insert(term.lowercased()); result.added += 1
        }
        return result
    }
}
