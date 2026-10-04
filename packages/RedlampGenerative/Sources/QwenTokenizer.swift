import Foundation

/// Qwen's byte-level BPE tokenizer (`Qwen2TokenizerFast`), read from its `tokenizer.json`. Added
/// tokens (`<|im_start|>`, `<think>`…) are split out first, then the rest is NFC-normalised, split
/// by the pre-tokenizer's pattern, mapped byte by byte to GPT-2's printable characters and merged
/// pair by pair, the lowest-ranked merge first.
public struct QwenTokenizer: Sendable {
    private struct Pair: Hashable {
        var left: String
        var right: String
    }

    private let vocabulary: [String: Int32]
    private let ranks: [Pair: Int]
    /// Longest first, so one that starts with another wins.
    private let added: [(content: String, id: Int32)]
    private let pattern: NSRegularExpression
    /// GPT-2's map from each byte to a printable character.
    private static let byteCharacters: [Character] = {
        var printable = Array(33 ... 126) + Array(161 ... 172) + Array(174 ... 255)
        var characters = printable
        var next = 0
        for byte in 0 ..< 256 where !printable.contains(byte) {
            printable.append(byte)
            characters.append(256 + next)
            next += 1
        }
        var map = [Character](repeating: " ", count: 256)
        for (byte, character) in zip(printable, characters) {
            map[byte] = Character(Unicode.Scalar(UInt32(character))!)
        }
        return map
    }()

    public enum TokenizerError: Error {
        case unreadable(String)
    }

    public init(contentsOf url: URL) throws {
        guard let json = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any],
              let model = json["model"] as? [String: Any], model["type"] as? String == "BPE",
              let vocabulary = model["vocab"] as? [String: Int], let merges = model["merges"] as? [Any]
        else { throw TokenizerError.unreadable("no BPE model in \(url.lastPathComponent)") }
        self.vocabulary = vocabulary.mapValues { Int32($0) }
        var ranks: [Pair: Int] = [:]
        ranks.reserveCapacity(merges.count)
        for (rank, merge) in merges.enumerated() {
            let parts = (merge as? [String]) ?? (merge as? String)?.split(separator: " ").map(String.init) ?? []
            guard parts.count == 2 else { throw TokenizerError.unreadable("merge \(rank)") }
            ranks[Pair(left: parts[0], right: parts[1])] = rank
        }
        self.ranks = ranks
        let added = (json["added_tokens"] as? [[String: Any]] ?? []).compactMap { token -> (String, Int32)? in
            guard let content = token["content"] as? String, let id = token["id"] as? Int else { return nil }
            return (content, Int32(id))
        }
        self.added = added.sorted { $0.0.count > $1.0.count }.map { (content: $0.0, id: $0.1) }
        guard let pretokenizer = json["pre_tokenizer"] as? [String: Any],
              let regex = Self.splitPattern(pretokenizer)
        else { throw TokenizerError.unreadable("no split pattern in \(url.lastPathComponent)") }
        pattern = try NSRegularExpression(pattern: regex)
    }

    /// The token for `content` among the added tokens.
    public func addedToken(_ content: String) -> Int32? {
        added.first { $0.content == content }?.id
    }

    public func encode(_ text: String) -> [Int32] {
        var ids: [Int32] = []
        var rest = Substring(text)
        while !rest.isEmpty {
            // The nearest added token, the longest where two start together.
            var nearest: (range: Range<String.Index>, id: Int32)?
            for token in added {
                guard let range = rest.range(of: token.content) else { continue }
                if nearest.map({ range.lowerBound < $0.range.lowerBound }) ?? true {
                    nearest = (range, token.id)
                }
            }
            guard let nearest else {
                ids += encodeOrdinary(String(rest))
                break
            }
            ids += encodeOrdinary(String(rest[..<nearest.range.lowerBound]))
            ids.append(nearest.id)
            rest = rest[nearest.range.upperBound...]
        }
        return ids
    }

    private func encodeOrdinary(_ text: String) -> [Int32] {
        guard !text.isEmpty else { return [] }
        let normalized = text.precomposedStringWithCanonicalMapping as NSString
        var ids: [Int32] = []
        var cursor = 0
        func emit(_ range: NSRange) {
            guard range.length > 0 else { return }
            let piece = normalized.substring(with: range)
            let mapped = String(piece.utf8.map { Self.byteCharacters[Int($0)] })
            ids += merged(mapped).compactMap { vocabulary[$0] }
        }
        // Matches are pieces of their own, and so is any text between them.
        for match in pattern.matches(in: normalized as String, range: NSRange(location: 0, length: normalized.length)) {
            emit(NSRange(location: cursor, length: match.range.location - cursor))
            emit(match.range)
            cursor = match.range.location + match.range.length
        }
        emit(NSRange(location: cursor, length: normalized.length - cursor))
        return ids
    }

    /// `word`'s characters merged, the lowest-ranked adjacent pair first, the leftmost on a tie.
    private func merged(_ word: String) -> [String] {
        var symbols = word.map { String($0) }
        while symbols.count > 1 {
            var best: (rank: Int, index: Int)?
            for index in 0 ..< symbols.count - 1 {
                guard let rank = ranks[Pair(left: symbols[index], right: symbols[index + 1])] else { continue }
                if best.map({ rank < $0.rank }) ?? true {
                    best = (rank, index)
                }
            }
            guard let best else { break }
            symbols[best.index] += symbols[best.index + 1]
            symbols.remove(at: best.index + 1)
        }
        return symbols
    }

    /// The pattern of the pre-tokenizer's Split step, alone or in a Sequence.
    private static func splitPattern(_ pretokenizer: [String: Any]) -> String? {
        if pretokenizer["type"] as? String == "Split" {
            return (pretokenizer["pattern"] as? [String: Any])?["Regex"] as? String
        }
        let steps = pretokenizer["pretokenizers"] as? [[String: Any]] ?? []
        return steps.lazy.compactMap(splitPattern).first
    }
}
