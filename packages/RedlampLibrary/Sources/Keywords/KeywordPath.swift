import Foundation

/// A keyword's place in the keyword list (LIB-21): its names from the top down, `Places`, `Portugal`,
/// `Lisbon`, and its text, as sidecars, the index and the definitions keep it: the names with `/`
/// between them, `%2F` for a slash inside a name and `%25` for a percent sign (`Music/AC%2FDC`).
///
/// Names are kept in Unicode's composed form without spaces at their ends; a control character (a
/// tab, a line break) inside one becomes a space, and a name left empty is dropped. Two paths are the
/// same keyword when their texts are equal: case counts, as it does in the index.
public struct KeywordPath: Sendable, Hashable, Comparable, Codable, CustomStringConvertible {
    /// The names from the top of the list down; never empty.
    public let names: [String]
    /// The names, encoded and joined with `/`.
    public let text: String

    /// The path made of `names`; nil when none is left once each is tidied.
    public init?(names: some Sequence<String>) {
        let names = names.compactMap(Self.canonical)
        guard !names.isEmpty else { return nil }
        self.init(canonical: names)
    }

    private init(canonical names: [String]) {
        self.names = names
        text = names.map(Self.encode).joined(separator: "/")
    }

    /// The path `text` writes: its levels split at each `/`, then decoded and tidied, empty ones left
    /// out. Nil when none is left.
    public init?(_ text: String) {
        self.init(names: text.split(separator: "/", omittingEmptySubsequences: true).map(Self.decode))
    }

    /// The keyword's own name: the last of `names`.
    public var name: String {
        names[names.count - 1]
    }

    /// The keyword it's inside; nil at the top of the list.
    public var parent: KeywordPath? {
        names.count > 1 ? KeywordPath(canonical: Array(names.dropLast())) : nil
    }

    /// How many keywords contain it: 0 at the top of the list.
    public var depth: Int {
        names.count - 1
    }

    /// The keywords containing it, from the top down.
    public var ancestors: [KeywordPath] {
        (1 ..< names.count).map { KeywordPath(canonical: Array(names.prefix($0))) }
    }

    /// `name` inside this keyword; nil when `name` is left empty once tidied.
    public func appending(_ name: String) -> KeywordPath? {
        Self.canonical(name).map { KeywordPath(canonical: names + [$0]) }
    }

    /// Whether it is `other` or inside it.
    public func isWithin(_ other: KeywordPath) -> Bool {
        names.count >= other.names.count && names.starts(with: other.names)
    }

    /// The path with `prefix`, which it's within, replaced by `replacement`.
    public func replacingPrefix(_ prefix: KeywordPath, with replacement: KeywordPath) -> KeywordPath {
        guard isWithin(prefix) else { return self }
        return KeywordPath(canonical: replacement.names + names.dropFirst(prefix.names.count))
    }

    /// The names as the keyword list shows the path: `Places › Portugal › Lisbon`.
    public var displayName: String {
        names.joined(separator: " › ")
    }

    public var description: String {
        text
    }

    public static func == (lhs: KeywordPath, rhs: KeywordPath) -> Bool {
        lhs.text == rhs.text
    }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(text)
    }

    /// By their texts' bytes: a keyword just before the keywords inside it.
    public static func < (lhs: KeywordPath, rhs: KeywordPath) -> Bool {
        lhs.names.lexicographicallyPrecedes(rhs.names) { $0.utf8.lexicographicallyPrecedes($1.utf8) }
    }

    public init(from decoder: Decoder) throws {
        let text = try decoder.singleValueContainer().decode(String.self)
        guard let path = KeywordPath(text) else {
            throw DecodingError.dataCorrupted(.init(
                codingPath: decoder.codingPath, debugDescription: "a keyword path with no names in it",
            ))
        }
        self = path
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(text)
    }

    // MARK: - Names

    /// `name` as a path's level writes it: `%` as `%25`, then `/` as `%2F`.
    public static func encode(_ name: String) -> String {
        guard name.contains(where: { $0 == "%" || $0 == "/" }) else { return name }
        return name.replacingOccurrences(of: "%", with: "%25").replacingOccurrences(of: "/", with: "%2F")
    }

    /// A path's level as a name: `%2F` (either case) a slash, `%25` a percent sign, and any other
    /// `%` itself.
    public static func decode(_ level: some StringProtocol) -> String {
        guard level.contains("%") else { return String(level) }
        var name = ""
        var rest = level[...]
        while let percent = rest.firstIndex(of: "%") {
            name += rest[..<percent]
            let escape = rest[percent...].prefix(3).uppercased()
            switch escape {
            case "%2F":
                name += "/"
                rest = rest[rest.index(percent, offsetBy: 3)...]
            case "%25":
                name += "%"
                rest = rest[rest.index(percent, offsetBy: 3)...]
            default:
                name += "%"
                rest = rest[rest.index(after: percent)...]
            }
        }
        return name + rest
    }

    /// `name` tidied as paths keep names: control characters as spaces, no spaces at its ends, in
    /// Unicode's composed form; nil when nothing is left.
    public static func canonical(_ name: String) -> String? {
        var tidy = name
        if tidy.unicodeScalars.contains(where: Self.isControl) {
            tidy = String(String.UnicodeScalarView(tidy.unicodeScalars.map { Self.isControl($0) ? " " : $0 }))
        }
        tidy = tidy.trimmingCharacters(in: .whitespacesAndNewlines).precomposedStringWithCanonicalMapping
        return tidy.isEmpty ? nil : tidy
    }

    /// The paths `texts` write, each once, in order, those with no names in them left out.
    public static func paths(_ texts: some Sequence<String>) -> [KeywordPath] {
        var seen = Set<KeywordPath>()
        return texts.compactMap(KeywordPath.init).filter { seen.insert($0).inserted }
    }

    /// `texts` as their paths' texts: tidied, each once, in order.
    public static func texts(_ texts: some Sequence<String>) -> [String] {
        paths(texts).map(\.text)
    }

    private static func isControl(_ scalar: Unicode.Scalar) -> Bool {
        scalar.properties.generalCategory == .control || scalar == "\u{2028}" || scalar == "\u{2029}"
    }
}
