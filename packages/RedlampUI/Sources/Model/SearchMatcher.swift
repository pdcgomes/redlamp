/// Word matching for the ⌘F adjustment search and the command palette: every word typed
/// must match one of an item's terms, and the item scores the sum of its best matches.
enum SearchMatcher {
    /// The query's words, normalised.
    static func words(_ query: String) -> [String] {
        normalized(query).split(separator: " ").map(String.init)
    }

    /// The total score of `terms` for every word, or `nil` when a word matches none of them.
    static func score(_ words: [String], terms: [String]) -> Int? {
        guard !words.isEmpty else { return nil }
        let terms = terms.map(normalized)
        var total = 0
        for word in words {
            guard let best = terms.map({ score(word, $0) }).max(), best > 0 else { return nil }
            total += best
        }
        return total
    }

    /// Exact word 3, word prefix 2, substring 1.
    static func score(_ word: String, _ term: String) -> Int {
        let termWords = term.split(separator: " ").map(String.init)
        if termWords.contains(word) {
            return 3
        }
        if termWords.contains(where: { $0.hasPrefix(word) }) {
            return 2
        }
        return word.count >= 3 && term.contains(word) ? 1 : 0
    }

    static func normalized(_ text: String) -> String {
        text.lowercased()
            .replacingOccurrences(of: "colour", with: "color")
            .replacingOccurrences(of: "-", with: " ")
            .replacingOccurrences(of: "·", with: " ")
            .replacingOccurrences(of: ",", with: " ")
            .replacingOccurrences(of: "/", with: " ")
            .trimmingCharacters(in: .whitespaces)
    }
}
