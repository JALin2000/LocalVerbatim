import Foundation

/// A deterministic presentation filter. Stored ASR output, timings and notes
/// remain untouched; an explicit allowlist handles common Chinese restarts.
enum FillerReducer {
    static func reduce(_ input: String, reduceRepetitions: Bool = false) -> String {
        // The first pass keeps its original filler-only behavior. Repetition
        // cleanup is an opt-in presentation filter for the refined transcript.
        var text: String
        if reduceRepetitions {
            text = transformOutsideQuotes(input) { fragment in
                normalizeSpacing(reduceRepeatedFragments(removeIsolatedFillers(fragment)))
            }
        } else {
            text = normalizeSpacing(removeIsolatedFillers(input))
        }
        text = text.replacingOccurrences(of: #"^[\s,，。.!！?？;；:：、]+"#, with: "", options: .regularExpression)
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func removeIsolatedFillers(_ input: String) -> String {
        var text = input
        // Only isolated filler tokens, with explicit boundaries. Do not strip
        // words such as album, human, or quoted examples such as “um”.
        let patterns = [
            #"(?i)(?<![\p{L}\p{N}\"'“‘])(?:u+h+|u+m+|erm+|hmm+)(?![\p{L}\p{N}\"'”’])(?:[\t ]*[,，、][\t ]*)?"#,
            #"(?<![\p{L}\p{N}\"'“‘])(?:[嗯呃额唔]+|啊+|唉+|哎+)(?=$|[\s,，。.!！?？;；:：、])[\t ,，、]*"#
        ]
        for pattern in patterns {
            text = text.replacingOccurrences(of: pattern, with: "", options: .regularExpression)
        }
        return text
    }

    private static func normalizeSpacing(_ input: String) -> String {
        var text = input
        text = text.replacingOccurrences(of: #"[ \t]{2,}"#, with: " ", options: .regularExpression)
        text = text.replacingOccurrences(of: #"([。.!！?？])[ \t]*[。.,，、]+"#, with: "$1", options: .regularExpression)
        return text
    }

    private static func reduceRepeatedFragments(_ input: String) -> String {
        // Deliberately finite Chinese restart rules, not arbitrary word or
        // sentence deduplication. Keep punctuation-separated emphasis except
        // for the narrowly specified unfinished "放到这个" restart.
        let rules: [(String, String)] = [
            // Longer pronoun stutters are clearer than two-word emphasis.
            (#"([我你他她它])\1{2,}(?!\1)(?=[\t ]*\p{L})"#, "$1"),
            // A short list of common continuations avoids treating arbitrary
            // repeated Chinese characters as stutters (人人/好好/一一, etc.).
            (#"([我你他她它])\1+(?=[这那是想说觉认要会能跟和也就可已不没很把先再来去在用有对给让做看打按操们])"#, "$1"),
            // Repeated abandoned deictic starts: 我这我这我跟… → 我跟… .
            (#"([我你他她它])(?:这\1)+(?=[跟想说觉认要会是])"#, "$1"),
            (#"(我们|你们|他们|她们|它们|这个|那个|就在)(?:\1)+(?=[\t ]*[\p{L}\p{N}])"#, "$1"),
            (#"(我是|你是|他是|她是|它是)(?:\1)+(?=[\t ]*[\p{L}\p{N}])"#, "$1"),
            (#"(就是|首先|然后|应该|你看|我们先)(?:\1)+(?!\1)(?=[\t ]*[\p{L}\p{N}])"#, "$1"),
            (#"(放到这个|放到那个)(?:[\t ]*[,，]?[\t ]*\1)+(?=[\t ]*[\p{L}\p{N}])"#, "$1"),
            // Keep the ordinary verb reduplication 看看, and limit 再 cleanup
            // to the specific directional restart 再再往上.
            (#"看{3,}(?!看)(?=[\t ]*[\p{L}\p{N}])"#, "看看"),
            (#"再{2,}(?=往上)"#, "再"),
            // Standalone repeated acknowledgements retain one utterance.
            (#"(?<![\p{L}\p{N}])([哦噢])\1+(?=$|[\s,，。.!！?？;；:：、])"#, "$1"),
            (#"(?<![\p{L}\p{N}])行{3,}(?=$|[\s,，。.!！?？;；:：、])"#, "行"),
            // Keep normal agreement/emphasis such as 对对 and 对对对.
            (#"对{4,}"#, "对")
        ]
        var text = input
        for (pattern, replacement) in rules {
            text = text.replacingOccurrences(of: pattern, with: replacement, options: .regularExpression)
        }
        return text
    }

    private static func transformOutsideQuotes(_ input: String, transform: (String) -> String) -> String {
        // Protect complete quoted examples, including their filler words,
        // spacing and punctuation. An unfinished quote protects the rest too.
        let closers: [Character: Character] = [
            "\"": "\"", "'": "'", "“": "”", "‘": "’", "「": "」", "『": "』", "`": "`"
        ]
        var output = ""
        var fragment = ""
        var closingQuote: Character?
        var previous: Character?
        var escaped = false
        for character in input {
            if let closer = closingQuote {
                fragment.append(character)
                if character == closer && !escaped {
                    output += fragment
                    fragment = ""
                    closingQuote = nil
                }
            } else if let closer = closers[character],
                      character != "'" || !(previous?.isLetter == true || previous?.isNumber == true) {
                output += transform(fragment)
                fragment = String(character)
                closingQuote = closer
                escaped = false
                previous = character
                continue
            } else {
                fragment.append(character)
            }
            escaped = character == "\\" && !escaped
            previous = character
        }
        output += closingQuote == nil ? transform(fragment) : fragment
        return output
    }
}
