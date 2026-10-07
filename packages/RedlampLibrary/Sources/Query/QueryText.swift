import Foundation

/// How the query language matches text: ignoring case, accents and width, as completion does
/// (DEC-45). The column engine and the SQL it compiles to call the same functions (`QuerySQL`
/// registers them with SQLite), so both answer alike.
enum QueryText {
    /// Whether the trigram index can search for `text`: three characters or more as the index holds
    /// text (`indexed`), as SQLite counts them (Unicode scalars).
    static func isSearchable(_ text: String) -> Bool {
        indexed(text).unicodeScalars.count >= 3
    }

    /// `text` with its case, accents and width folded, as completion compares names.
    static func folded(_ text: some StringProtocol) -> String {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: nil)
    }

    /// `text` as the text index holds it and is searched for there: folded (`folded`) and composed,
    /// so its trigrams are of whole characters; ASCII as it is, since the tokenizer folds its case.
    /// The trigram tokenizer's `remove_diacritics` takes accents only from Latin letters (Greek ό,
    /// Cyrillic ё and ß stay) and folds no width, and the index keeps no copy of the text to fold
    /// later, so the writer folds it on the way in (`redlamp_text`).
    static func indexed(_ text: String) -> String {
        text.utf8.allSatisfy { $0 < 0x80 } ? text : folded(text).precomposedStringWithCanonicalMapping
    }

    /// `part` anywhere in `text`, ignoring case, accents and width, byte by byte (`FoldedText`).
    static func contains(_ text: String, _ part: String) -> Bool {
        guard let needle = asciiLowercased(part), let haystack = asciiLowercased(text) else {
            return FoldedText(text).contains(FoldedText(part))
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

    /// Whether `text` is `name`, ignoring case, accents and width: byte by byte, folded
    /// (`FoldedText`) unless both are ASCII.
    static func isSame(_ text: String, _ name: String) -> Bool {
        guard let left = asciiLowercased(text), let right = asciiLowercased(name) else {
            return FoldedText(text).bytes == FoldedText(name).bytes
        }
        return left == right
    }

    /// An FTS5 query for `text` as one phrase, folded as the index holds text (`indexed`), in every
    /// column of `photo_text` or only `column`.
    static func match(_ text: String, in column: LibraryIndex.TextColumn? = nil) -> String {
        let phrase = "\"" + indexed(text).replacingOccurrences(of: "\"", with: "\"\"") + "\""
        return column.map { "\($0.rawValue) : \(phrase)" } ?? phrase
    }
}

/// Text folded once to search for or search in byte by byte, ignoring case, accents and width:
/// each character folded as completion folds names (`QueryText.folded`, so `sao` finds São) and
/// then decomposed, so the composed and decomposed forms of what folding keeps (ガ, 한) match,
/// with where each character starts, so a match never starts or ends inside one (an `s` isn't found
/// in a `ß`, folded to `ss`, nor 👍 in 👍🏽). ASCII is only lowercased.
struct FoldedText: Sendable, Hashable {
    let bytes: ContiguousArray<UInt8>
    /// Whether a character starts at each byte, and a last true for the end; nil when every byte is
    /// a character.
    let starts: ContiguousArray<Bool>?

    init(_ text: String) {
        if let ascii = QueryText.asciiLowercased(text) {
            bytes = ascii
            starts = nil
            return
        }
        var bytes = ContiguousArray<UInt8>()
        var starts = ContiguousArray<Bool>()
        bytes.reserveCapacity(text.utf8.count + 8)
        starts.reserveCapacity(text.utf8.count + 9)
        for character in text {
            let count = bytes.count
            if let ascii = character.asciiValue, character.utf8.count == 1 {
                bytes.append((0x41 ... 0x5A).contains(ascii) ? ascii | 0x20 : ascii)
            } else {
                bytes.append(contentsOf: QueryText.folded(String(character)).decomposedStringWithCanonicalMapping.utf8)
            }
            if bytes.count > count {
                starts.append(true)
                starts.append(contentsOf: repeatElement(false, count: bytes.count - count - 1))
            }
        }
        starts.append(true)
        self.bytes = bytes
        self.starts = starts
    }

    /// ASCII already lowercased (`QueryText.asciiLowercased`).
    init(ascii: ContiguousArray<UInt8>) {
        bytes = ascii
        starts = nil
    }

    /// Whether `needle` is in it, starting and ending where characters do; an empty needle is in
    /// nothing, as Foundation has it.
    func contains(_ needle: FoldedText) -> Bool {
        let length = needle.bytes.count
        guard length > 0, length <= bytes.count else { return false }
        return bytes.withUnsafeBytes { haystack in
            needle.bytes.withUnsafeBytes { needle in
                guard let base = haystack.baseAddress else { return false }
                guard let starts else {
                    return memmem(base, haystack.count, needle.baseAddress, length) != nil
                }
                var from = 0
                while haystack.count - from >= length,
                      let found = memmem(base + from, haystack.count - from, needle.baseAddress, length) {
                    let at = base.distance(to: UnsafeRawPointer(found))
                    if starts[at], starts[at + length] {
                        return true
                    }
                    from = at + 1
                }
                return false
            }
        }
    }
}

/// The order the Finder lists names in, near enough to sort a million names quickly: letters
/// ignoring case, accents and width, runs of digits by their value, and spaces and punctuation
/// before digits, which come before letters. Names with the same key keep the order of their
/// photos' IDs.
enum FinderOrder {
    /// Bytes that sort as the names do.
    static func key(_ name: String) -> [UInt8] {
        var key = ContiguousArray<UInt8>()
        appendKey(of: name, to: &key)
        return Array(key)
    }

    /// Appends `name`'s key to `key`: a run of digits as a marker, the count of its digits after
    /// leading zeros and then those digits, or a single zero for a run of zeros.
    static func appendKey(of name: String, to key: inout ContiguousArray<UInt8>) {
        let folded = name.utf8.allSatisfy { $0 < 0x80 } ? name : QueryText.folded(name)
        // Where the run of digits being read keeps its count, -1 outside a run.
        var countAt = -1
        var digits = 0
        func endDigits() {
            guard countAt >= 0 else { return }
            if digits == 0 {
                key.append(UInt8(ascii: "0"))
                digits = 1
            }
            key[countAt] = UInt8(min(digits, 255))
            countAt = -1
        }
        for byte in folded.utf8 {
            switch byte {
            case UInt8(ascii: "0") ... UInt8(ascii: "9"):
                if countAt < 0 {
                    key.append(digitMarker)
                    countAt = key.count
                    key.append(0)
                    digits = 0
                }
                if digits > 0 || byte != UInt8(ascii: "0") {
                    key.append(byte)
                    digits += 1
                }
            case UInt8(ascii: "A") ... UInt8(ascii: "Z"):
                endDigits()
                key.append(byte + 0x20)
            case UInt8(ascii: "a") ... UInt8(ascii: "z"), 0x80...:
                endDigits()
                key.append(byte)
            default:
                endDigits()
                key.append(punctuation[Int(byte)])
            }
        }
        endDigits()
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
