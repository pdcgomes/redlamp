import Foundation

/// Lightroom Classic's keyword-list text file, as Adobe describes it, read and written (LIB-21):
/// a keyword a line, each inside the keyword above it with one more tab, its synonyms on lines of
/// their own in braces one tab further in (`{Lisboa}`), and a keyword that isn't exported in
/// brackets (`[Places]`). Lightroom reads it as UTF-8.
///
/// It holds a keyword's place, name, synonyms and Include on Export, and nothing else: reading what
/// this writes gives them all back. A name the format can't tell apart from a marked line, an
/// exported keyword whose name is in brackets or braces, is listed in `Export.unrepresentable`; one
/// that isn't exported is wrapped once more and reads back whole.
public enum LightroomKeywordFile {
    /// A keyword as the file holds it.
    public struct Keyword: Sendable, Hashable {
        public var path: KeywordPath
        public var synonyms: [String]
        public var includeOnExport: Bool

        public init(path: KeywordPath, synonyms: [String] = [], includeOnExport: Bool = true) {
            self.path = path
            self.synonyms = KeywordOptions.tidied(synonyms)
            self.includeOnExport = includeOnExport
        }
    }

    /// What writing a file gave.
    public struct Export: Sendable, Hashable {
        public var text: String
        public var keywords: Int
        /// Exported keywords whose names the file would read back as something else.
        public var unrepresentable: [KeywordPath]
        /// Keywords Lightroom Classic won't take in: a comma, semicolon or pipe in the name, or one that
        /// ends with an asterisk.
        public var refusedByLightroom: [KeywordPath]
    }

    // MARK: - Reading

    /// The keywords of a file's bytes: UTF-8 (with or without a byte-order mark), else UTF-16 with
    /// one, else Windows Latin 1. Throws `KeywordError.unreadableFile` for bytes that aren't text.
    public static func read(_ data: Data) throws -> [Keyword] {
        try read(text(of: data))
    }

    /// The keywords of `text`, in its order, each once: a keyword met twice keeps its first place and
    /// gathers its synonyms. Tabs at a line's start say how deep it is, and a line deeper than the one
    /// above by more than one tab goes inside it all the same. A synonym with no keyword above it, and
    /// lines with nothing on them, are left out.
    public static func read(_ text: String) -> [Keyword] {
        var keywords: [Keyword] = []
        var places: [KeywordPath: Int] = [:]
        var stack: [(depth: Int, path: KeywordPath)] = []
        for line in text.split(
            omittingEmptySubsequences: true,
            whereSeparator: { $0 == "\n" || $0 == "\r" || $0 == "\r\n" },
        ) {
            let depth = line.prefix { $0 == "\t" }.count
            let content = line.dropFirst(depth).trimmingCharacters(in: .whitespaces)
            guard !content.isEmpty else { continue }
            if let synonym = unwrapped(content, "{", "}") {
                guard let owner = stack.last(where: { $0.depth < depth })?.path, let place = places[owner],
                      let synonym = KeywordPath.canonical(synonym)
                else { continue }
                keywords[place].synonyms = KeywordOptions.tidied(keywords[place].synonyms + [synonym])
                continue
            }
            let bracketed = unwrapped(content, "[", "]")
            while let last = stack.last, last.depth >= depth {
                stack.removeLast()
            }
            let name = bracketed ?? content
            guard let path = stack.last.map({ $0.path.appending(name) }) ?? KeywordPath(names: [name]) else {
                continue
            }
            stack.append((depth, path))
            if places[path] == nil {
                places[path] = keywords.count
                keywords.append(Keyword(path: path, includeOnExport: bracketed == nil))
            }
        }
        return keywords
    }

    /// `text` without `open` at its start and `close` at its end, when it has both.
    private static func unwrapped(_ text: String, _ open: Character, _ close: Character) -> String? {
        guard text.count >= 2, text.first == open, text.last == close else { return nil }
        return String(text.dropFirst().dropLast())
    }

    static func text(of data: Data) throws -> String {
        var bytes = data
        if bytes.starts(with: [0xEF, 0xBB, 0xBF]) {
            bytes = bytes.dropFirst(3)
        }
        if let text = String(data: bytes, encoding: .utf8) {
            return text
        }
        if data.starts(with: [0xFF, 0xFE]) || data.starts(with: [0xFE, 0xFF]),
           let text = String(data: data, encoding: .utf16) {
            return text
        }
        guard !data.contains(0), let text = String(data: data, encoding: .windowsCP1252) else {
            throw KeywordError.unreadableFile
        }
        return text
    }

    // MARK: - Writing

    /// `keywords`, and the keywords containing them, as the file holds them: each level in the keyword
    /// list's order, a keyword's synonyms before the keywords inside it, a line feed after every line.
    public static func write(_ keywords: [Keyword]) -> Export {
        var byPath: [KeywordPath: Keyword] = [:]
        for keyword in keywords {
            byPath[keyword.path] = byPath[keyword.path].map { existing in
                Keyword(
                    path: existing.path, synonyms: existing.synonyms + keyword.synonyms,
                    includeOnExport: existing.includeOnExport,
                )
            } ?? keyword
        }
        for path in Array(byPath.keys) {
            for ancestor in path.ancestors where byPath[ancestor] == nil {
                byPath[ancestor] = Keyword(path: ancestor)
            }
        }
        var children: [KeywordPath?: [KeywordPath]] = [:]
        for path in byPath.keys {
            children[path.parent, default: []].append(path)
        }
        var lines: [String] = []
        var unrepresentable: [KeywordPath] = []
        var refused: [KeywordPath] = []
        var pending = (children[nil] ?? []).sorted(by: KeywordList.inOrder).reversed().map(\.self)
        while let path = pending.popLast() {
            guard let keyword = byPath[path] else { continue }
            let indent = String(repeating: "\t", count: path.depth)
            let name = keyword.path.name
            let marked = isMarked(name)
            if keyword.includeOnExport {
                lines.append(indent + name)
                if marked {
                    unrepresentable.append(path)
                }
            } else {
                lines.append(indent + "[" + name + "]")
            }
            if name.contains(where: { $0 == "," || $0 == ";" || $0 == "|" }) || name.hasSuffix("*") {
                refused.append(path)
            }
            for synonym in keyword.synonyms {
                lines.append(indent + "\t{" + synonym + "}")
            }
            pending += (children[path] ?? []).sorted(by: KeywordList.inOrder).reversed()
        }
        return Export(
            text: lines.map { $0 + "\n" }.joined(), keywords: byPath.count, unrepresentable: unrepresentable,
            refusedByLightroom: refused,
        )
    }

    /// Whether a line holding just `name` would be read as a synonym or a keyword not exported.
    private static func isMarked(_ name: String) -> Bool {
        unwrapped(name, "{", "}") != nil || unwrapped(name, "[", "]") != nil
    }
}

public extension LightroomKeywordFile.Keyword {
    /// The keyword as the file holds it, from the list.
    init(_ keyword: KeywordList.Keyword) {
        self.init(
            path: keyword.path,
            synonyms: keyword.options.synonyms,
            includeOnExport: keyword.options.includeOnExport,
        )
    }
}
