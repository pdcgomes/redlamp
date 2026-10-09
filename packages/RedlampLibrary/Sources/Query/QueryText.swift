import Foundation
import RedlampDocument

/// How the query language matches text: ignoring case, accents and width, as completion does
/// (DEC-52). The column engine and the SQL it compiles to call the same functions (`QuerySQL`
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

    /// Bytes already folded, and where their characters start, with a last true for the end.
    init(folded bytes: ContiguousArray<UInt8>, starts: ContiguousArray<Bool>?) {
        self.bytes = bytes
        self.starts = starts
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

/// The library's name order, Folders' own (`FileOrder`): its keys sort a million names without
/// comparing strings, and the index's SQL sorts with `compare`. Names with the same key keep the
/// order of their photos' IDs.
enum FinderOrder {
    /// Bytes that sort as the names do.
    static func key(_ name: String) -> [UInt8] {
        FileOrder.key(name)
    }

    static func appendKey(of name: String, to key: inout ContiguousArray<UInt8>) {
        FileOrder.appendKey(of: name, to: &key)
    }

    /// Orders two names as `key` does.
    static func compare(_ lhs: String, _ rhs: String) -> Int {
        switch FileOrder.compare(lhs, rhs) {
        case .orderedAscending: -1
        case .orderedSame: 0
        case .orderedDescending: 1
        }
    }
}

extension LibraryQuery {
    /// The query as it's run: values of `name`, `title`, `caption` and extensions too short for the
    /// trigram index are left out, and nil when that leaves nothing. Free text is kept whatever its
    /// length: too short for the index, it's still matched against the small tables
    /// (`QueryPlan.compile`).
    var searchable: LibraryQuery? {
        switch self {
        case .all:
            return nil
        case .text:
            return self
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
