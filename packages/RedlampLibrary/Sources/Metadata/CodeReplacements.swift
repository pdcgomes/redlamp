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
        let data = try Data(contentsOf: url)
        guard let text = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .macOSRoman) else {
            throw MetadataError.unreadableFile(url.lastPathComponent)
        }
        self.init(text: text)
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
