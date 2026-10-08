import Foundation

/// Photo Mechanic's code replacements (LIB-22): a file of lines, each a code and its texts separated by
/// tabs, and a text where `\code\` becomes the code's first text and `\code#2\` its second. A code is
/// matched as it's written, else ignoring case; one the file doesn't have, or a column it doesn't have,
/// is left as written.
public struct CodeReplacements: Sendable, Hashable {
    /// Each code's texts, by the code.
    public var codes: [String: [String]]

    public init(codes: [String: [String]] = [:]) {
        self.codes = codes
    }

    /// The codes of a tab-separated file's text; lines without a tab, and blank ones, are left out. The
    /// first line for a code wins.
    public init(text: String) {
        var codes: [String: [String]] = [:]
        for line in text.split(whereSeparator: \.isNewline) {
            let columns = line.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
            guard columns.count > 1, let code = XMPSource.trimmed(columns[0]), codes[code] == nil else { continue }
            codes[code] = columns.dropFirst().map { $0.trimmingCharacters(in: .whitespaces) }
        }
        self.init(codes: codes)
    }

    /// The codes in the file at `url`, read as UTF-8 or else as Mac OS Roman, as older files are.
    public init(contentsOf url: URL) throws {
        try self.init(text: Self.text(contentsOf: url))
    }

    /// The text of the file at `url`, read as UTF-8 or else as Mac OS Roman.
    public static func text(contentsOf url: URL) throws -> String {
        let data = try Data(contentsOf: url)
        guard let text = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .macOSRoman) else {
            throw MetadataError.unreadableFile(url.lastPathComponent)
        }
        return text
    }

    /// The numbers, from 1, of the lines of `text` that `init(text:)` leaves out though they hold something:
    /// those without a tab, those with no code before it, and those whose code an earlier line has.
    public static func ignoredLines(in text: String) -> [Int] {
        var seen = Set<String>()
        var ignored: [Int] = []
        for (number, line) in text.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline).enumerated()
            where !line.allSatisfy(\.isWhitespace) {
            let columns = line.split(separator: "\t", maxSplits: 1, omittingEmptySubsequences: false)
            let code = columns.count > 1 ? XMPSource.trimmed(String(columns[0])) : nil
            if code.map({ seen.insert($0).inserted }) != true {
                ignored.append(number + 1)
            }
        }
        return ignored
    }

    /// The library's, `Code Replacements.txt` in `LibraryPaths.definitions`: Photo Mechanic's tab-separated
    /// text, kept as it's written.
    public static let fileName = "Code Replacements.txt"

    public static func url(in paths: LibraryPaths) -> URL {
        paths.definitions.appending(path: fileName)
    }

    /// The text of the library's file at `url`; none when there's no file.
    public static func load(from url: URL) throws -> String {
        do {
            return try text(contentsOf: url)
        } catch let error as CocoaError where error.code == .fileReadNoSuchFile {
            return ""
        }
    }

    /// Writes `text` to `url` as UTF-8, replacing what's there in one step; no text removes the file.
    public static func save(_ text: String, to url: URL) throws {
        guard !text.allSatisfy(\.isWhitespace) else {
            if FileManager.default.fileExists(atPath: url.path) {
                try FileManager.default.removeItem(at: url)
            }
            return
        }
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: url, options: .atomic)
    }

    /// `text` with each `\code\` and `\code#n\` it has a text for replaced by it.
    public func expanded(_ text: String) -> String {
        guard !codes.isEmpty, text.contains("\\") else { return text }
        var result = ""
        var rest = text[...]
        while let open = rest.firstIndex(of: "\\") {
            result += rest[..<open]
            let after = rest.index(after: open)
            guard let close = rest[after...].firstIndex(of: "\\") else {
                rest = rest[open...]
                break
            }
            let inside = String(rest[after ..< close])
            if let replacement = replacement(for: inside) {
                result += replacement
                rest = rest[rest.index(after: close)...]
            } else {
                result += "\\"
                rest = rest[after...]
            }
        }
        return result + rest
    }

    /// The text for `code` or `code#n`; nil when there's none.
    private func replacement(for inside: String) -> String? {
        var code = inside
        var column = 1
        if let hash = inside.lastIndex(of: "#"), let number = Int(inside[inside.index(after: hash)...]), number > 0 {
            code = String(inside[..<hash])
            column = number
        }
        let texts = codes[code] ?? codes.first { $0.key.caseInsensitiveCompare(code) == .orderedSame }?.value
        guard let texts, column <= texts.count else { return nil }
        return texts[column - 1]
    }
}

public extension LibraryMetadata {
    /// `Code Replacements.txt` in the library's definitions.
    var codesURL: URL {
        CodeReplacements.url(in: paths)
    }

    /// The library's code replacements file as it's written; empty when there's none.
    func codeReplacementsText() async throws -> String {
        let url = codesURL
        return try await LibraryIndex.offCaller { try CodeReplacements.load(from: url) }
    }

    /// The codes of the library's code replacements file.
    func codeReplacements() async throws -> CodeReplacements {
        try await CodeReplacements(text: codeReplacementsText())
    }

    /// Keeps `text` as the library's code replacements file.
    func saveCodeReplacements(_ text: String) async throws {
        let url = codesURL
        try await LibraryIndex.offCaller { try CodeReplacements.save(text, to: url) }
    }
}
