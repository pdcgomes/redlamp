import Foundation

/// How the query language matches text. The column engine and the SQL it compiles to call the same
/// functions (`QuerySQL` registers them with SQLite), so both answer alike.
enum QueryText {
    /// Whether the trigram index can search for `text`: three characters or more, as SQLite counts
    /// them (Unicode scalars).
    static func isSearchable(_ text: String) -> Bool {
        text.unicodeScalars.count >= 3
    }

    /// `part` anywhere in `text`, ignoring case: byte by byte when both are ASCII, as most names are,
    /// and as Foundation compares them otherwise.
    static func contains(_ text: String, _ part: String) -> Bool {
        guard let needle = asciiLowercased(part), let haystack = asciiLowercased(text) else {
            return text.range(of: part, options: .caseInsensitive) != nil
        }
        return contains(haystack, needle)
    }

    /// `text`'s bytes with A to Z lowercased, when it's all ASCII.
    static func asciiLowercased(_ text: String) -> ContiguousArray<UInt8>? {
        var bytes = ContiguousArray<UInt8>()
        bytes.reserveCapacity(text.utf8.count)
        for byte in text.utf8 {
            guard byte < 0x80 else { return nil }
            bytes.append((0x41 ... 0x5A).contains(byte) ? byte | 0x20 : byte)
        }
        return bytes
    }

    /// Whether `needle` is in `haystack`; an empty needle is in nothing, as Foundation has it.
    static func contains(_ haystack: ContiguousArray<UInt8>, _ needle: ContiguousArray<UInt8>) -> Bool {
        guard !needle.isEmpty, needle.count <= haystack.count else { return false }
        return haystack.withUnsafeBytes { haystack in
            needle.withUnsafeBytes { needle in
                memmem(haystack.baseAddress, haystack.count, needle.baseAddress, needle.count) != nil
            }
        }
    }

    /// Whether `value` names the keyword or collection at `path`, or one above it: its levels
    /// (`Places/Portugal`) are a run of the path's levels (`Places/Portugal/Lisbon`), ignoring case.
    static func levelsMatch(path: String, value: String) -> Bool {
        let wanted = levels(value)
        guard !wanted.isEmpty else { return false }
        let have = levels(path)
        guard have.count >= wanted.count else { return false }
        return (0 ... have.count - wanted.count).contains { start in
            zip(have[start...], wanted).allSatisfy { $0.caseInsensitiveCompare($1) == .orderedSame }
        }
    }

    private static func levels(_ path: String) -> [Substring] {
        path.split(separator: "/").map { $0.trimmingCharacters(in: .whitespaces)[...] }.filter { !$0.isEmpty }
    }

    /// An FTS5 query for `text` as one phrase, in every column of `photo_text` or only `column`.
    static func match(_ text: String, in column: LibraryIndex.TextColumn? = nil) -> String {
        let phrase = "\"" + text.replacingOccurrences(of: "\"", with: "\"\"") + "\""
        return column.map { "\($0.rawValue) : \(phrase)" } ?? phrase
    }
}

/// The order the Finder lists names in, near enough to sort a million names quickly: letters
/// ignoring case, accents and width, runs of digits by their value, and spaces and punctuation
/// before digits, which come before letters. Names with the same key keep the order of their
/// photos' IDs.
enum FinderOrder {
    /// Bytes that sort as the names do.
    static func key(_ name: String) -> [UInt8] {
        let folded = name.utf8.allSatisfy { $0 < 0x80 } ? name
            : name.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: nil)
        var key: [UInt8] = []
        key.reserveCapacity(folded.utf8.count + 4)
        var digits: [UInt8] = []
        func flushDigits() {
            guard !digits.isEmpty else { return }
            let significant = digits.drop { $0 == UInt8(ascii: "0") }
            let run = significant.isEmpty ? [UInt8(ascii: "0")] : Array(significant)
            key.append(digitMarker)
            key.append(UInt8(min(run.count, 255)))
            key.append(contentsOf: run)
            digits.removeAll(keepingCapacity: true)
        }
        for byte in folded.utf8 {
            switch byte {
            case UInt8(ascii: "0") ... UInt8(ascii: "9"):
                digits.append(byte)
            case UInt8(ascii: "A") ... UInt8(ascii: "Z"):
                flushDigits()
                key.append(byte + 0x20)
            case UInt8(ascii: "a") ... UInt8(ascii: "z"), 0x80...:
                flushDigits()
                key.append(byte)
            default:
                flushDigits()
                key.append(punctuation[Int(byte)])
            }
        }
        flushDigits()
        return key
    }

    /// Orders two names as `key` does.
    static func compare(_ lhs: String, _ rhs: String) -> Int {
        let (left, right) = (key(lhs), key(rhs))
        return left.lexicographicallyPrecedes(right) ? -1 : right.lexicographicallyPrecedes(left) ? 1 : 0
    }

    /// Below every letter and above all punctuation, which maps to 1 up to 33 in byte order.
    private static let digitMarker: UInt8 = 0x30

    private static let punctuation: [UInt8] = {
        var table = [UInt8](repeating: 0, count: 128)
        var next: UInt8 = 1
        for byte in 0 ..< 128 {
            let isAlphanumeric = (0x30 ... 0x39).contains(byte) || (0x41 ... 0x5A).contains(byte)
                || (0x61 ... 0x7A).contains(byte)
            if byte >= 0x20, !isAlphanumeric {
                table[byte] = next
                next += 1
            }
        }
        return table
    }()
}

extension LibraryQuery {
    /// The query as it's run: free text, and values of `name`, `title`, `caption` and extensions,
    /// too short for the trigram index are left out, and nil when that leaves nothing.
    var searchable: LibraryQuery? {
        switch self {
        case .all:
            return nil
        case let .text(text):
            return QueryText.isSearchable(text) ? self : nil
        case var .filter(filter):
            filter.values = filter.values.filter { $0.isSearchable(as: filter.field) }
            return filter.values.isEmpty ? nil : .filter(filter)
        case let .not(query):
            return query.searchable.map(LibraryQuery.not)
        case let .and(queries), let .or(queries):
            let kept = queries.compactMap(\.searchable)
            let isOr = if case .or = self {
                true
            } else {
                false
            }
            return kept.isEmpty ? nil : LibraryQuery.joined(kept, or: isOr)
        }
    }
}

extension LibraryQuery.Value {
    func isSearchable(as field: LibraryQuery.Field) -> Bool {
        switch (field, self) {
        case let (.name, .text(text)), let (.title, .text(text)), let (.caption, .text(text)):
            QueryText.isSearchable(text)
        case let (.ext, .text(ext)):
            QueryText.isSearchable("." + ext)
        default:
            true
        }
    }
}
