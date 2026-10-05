import Foundation

/// An XML document's elements, with where each tag, attribute and content lies in its bytes, so one
/// part can be replaced and every other byte copied as it was. As much XML as XMP uses (XMP
/// Specification Part 1, 7.3): UTF-8, namespaces, comments, processing instructions, CDATA and
/// character references. A document type declaration is refused: XMP has none, and its entities
/// could expand without limit.
struct XMLElements: Sendable {
    static let xmlNamespace = "http://www.w3.org/XML/1998/namespace"

    struct Attribute: Sendable {
        let prefix: String
        let name: String
        /// Nil without a prefix, and for a namespace declaration.
        let namespace: String?
        /// From the whitespace before its name to its closing quote.
        let whole: Range<Int>
        /// Between its quotes.
        let value: Range<Int>
        let quote: UInt8
        /// `xmlns` or `xmlns:prefix`.
        let declaresNamespace: Bool
    }

    struct Element: Sendable {
        let qualifiedName: String
        let prefix: String
        let name: String
        let namespace: String?
        /// From `<` to `>`, or to `/>` for an empty-element tag.
        let start: Range<Int>
        /// Nil for an empty-element tag.
        var end: Range<Int>?
        let attributes: [Attribute]
        var children: [Int] = []
        let parent: Int?
        /// The prefixes in scope, with their namespaces.
        let scope: [String: String]

        var whole: Range<Int> {
            start.lowerBound ..< (end?.upperBound ?? start.upperBound)
        }

        var content: Range<Int> {
            start.upperBound ..< (end?.lowerBound ?? start.upperBound)
        }

        func attribute(_ namespace: String, _ name: String) -> Attribute? {
            attributes.first { $0.namespace == namespace && $0.name == name }
        }
    }

    let bytes: [UInt8]
    private(set) var elements: [Element] = []
    private(set) var root = 0

    /// Nil when `bytes` isn't a well-formed document in UTF-8.
    init?(_ bytes: [UInt8]) {
        self.bytes = bytes
        guard parse() else { return nil }
    }

    // MARK: - Parsing

    private static let depthLimit = 256

    private mutating func parse() -> Bool {
        let count = bytes.count
        var index = bytes.starts(with: [0xEF, 0xBB, 0xBF]) ? 3 : 0
        var open: [Int] = []
        var root: Int?
        while index < count {
            guard bytes[index] == Byte.less else {
                let next = find([Byte.less], from: index) ?? count
                if open.isEmpty, !bytes[index ..< next].allSatisfy(Byte.isWhitespace) {
                    return false
                }
                index = next
                continue
            }
            if starts("<?", at: index) {
                guard let end = find(Array("?>".utf8), from: index + 2) else { return false }
                index = end + 2
            } else if starts("<!--", at: index) {
                guard let end = find(Array("-->".utf8), from: index + 4) else { return false }
                index = end + 3
            } else if starts("<![CDATA[", at: index) {
                guard !open.isEmpty, let end = find(Array("]]>".utf8), from: index + 9) else { return false }
                index = end + 3
            } else if starts("<!", at: index) {
                return false
            } else if starts("</", at: index) {
                guard let current = open.popLast(), let end = endTag(at: index, closing: current) else { return false }
                elements[current].end = index ..< end
                index = end
            } else {
                guard open.count < Self.depthLimit,
                      let tag = startTag(at: index, parent: open.last) else { return false }
                let id = elements.count
                elements.append(tag.element)
                if let parent = open.last {
                    elements[parent].children.append(id)
                } else {
                    guard root == nil else { return false }
                    root = id
                }
                if !tag.empty {
                    open.append(id)
                }
                index = tag.end
            }
        }
        guard open.isEmpty, let root else { return false }
        self.root = root
        return true
    }

    /// The end tag at `index`, which must close `element`; where it ends.
    private func endTag(at index: Int, closing element: Int) -> Int? {
        var cursor = index + 2
        let nameStart = cursor
        while cursor < bytes.count, Byte.isName(bytes[cursor]) {
            cursor += 1
        }
        let name = string(nameStart ..< cursor)
        while cursor < bytes.count, Byte.isWhitespace(bytes[cursor]) {
            cursor += 1
        }
        guard cursor < bytes.count, bytes[cursor] == Byte.greater, name == elements[element].qualifiedName else {
            return nil
        }
        return cursor + 1
    }

    /// A start tag: its element, where it ends, and whether it's an empty-element tag.
    private struct StartTag {
        let element: Element
        let end: Int
        let empty: Bool
    }

    /// An attribute as written, before its namespace is known.
    private struct WrittenAttribute {
        let name: String
        let whole: Range<Int>
        let value: Range<Int>
        let quote: UInt8
    }

    /// The start tag at `index`, its names resolved in the namespaces in scope there.
    private func startTag(at index: Int, parent: Int?) -> StartTag? {
        var cursor = index + 1
        let nameStart = cursor
        while cursor < bytes.count, Byte.isName(bytes[cursor]) {
            cursor += 1
        }
        guard cursor > nameStart else { return nil }
        let qualifiedName = string(nameStart ..< cursor)
        var written: [WrittenAttribute] = []
        var empty = false
        while true {
            let gap = cursor
            while cursor < bytes.count, Byte.isWhitespace(bytes[cursor]) {
                cursor += 1
            }
            guard cursor < bytes.count else { return nil }
            if bytes[cursor] == Byte.greater || bytes[cursor] == Byte.slash {
                empty = bytes[cursor] == Byte.slash
                guard !empty || (cursor + 1 < bytes.count && bytes[cursor + 1] == Byte.greater) else { return nil }
                cursor += empty ? 2 : 1
                break
            }
            guard cursor > gap, let attribute = attribute(at: cursor, after: gap) else { return nil }
            written.append(attribute)
            cursor = attribute.whole.upperBound
        }

        var scope = parent.map { elements[$0].scope } ?? ["xml": Self.xmlNamespace]
        for attribute in written where attribute.name == "xmlns" || attribute.name.hasPrefix("xmlns:") {
            guard let uri = decode(attribute.value) else { return nil }
            scope[attribute.name == "xmlns" ? "" : String(attribute.name.dropFirst(6))] = uri
        }
        var attributes: [Attribute] = []
        for attribute in written {
            let (prefix, name) = Self.split(attribute.name)
            let declares = attribute.name == "xmlns" || prefix == "xmlns"
            var namespace: String?
            if !declares, !prefix.isEmpty {
                guard let uri = scope[prefix], !uri.isEmpty else { return nil }
                namespace = uri
            }
            attributes.append(Attribute(
                prefix: prefix, name: name, namespace: namespace, whole: attribute.whole, value: attribute.value,
                quote: attribute.quote, declaresNamespace: declares,
            ))
        }
        let (prefix, name) = Self.split(qualifiedName)
        let namespace = scope[prefix].flatMap { $0.isEmpty ? nil : $0 }
        guard prefix.isEmpty || namespace != nil else { return nil }
        let element = Element(
            qualifiedName: qualifiedName, prefix: prefix, name: name, namespace: namespace, start: index ..< cursor,
            attributes: attributes, parent: parent, scope: scope,
        )
        return StartTag(element: element, end: cursor, empty: empty)
    }

    /// The attribute whose name starts at `index`, the whitespace before it from `gap`.
    private func attribute(at index: Int, after gap: Int) -> WrittenAttribute? {
        var cursor = index
        while cursor < bytes.count, Byte.isName(bytes[cursor]) {
            cursor += 1
        }
        guard cursor > index else { return nil }
        let name = string(index ..< cursor)
        while cursor < bytes.count, Byte.isWhitespace(bytes[cursor]) {
            cursor += 1
        }
        guard cursor < bytes.count, bytes[cursor] == Byte.equals else { return nil }
        cursor += 1
        while cursor < bytes.count, Byte.isWhitespace(bytes[cursor]) {
            cursor += 1
        }
        guard cursor < bytes.count, bytes[cursor] == Byte.quote || bytes[cursor] == Byte.apostrophe else { return nil }
        let quote = bytes[cursor]
        guard let close = find([quote], from: cursor + 1), !bytes[cursor + 1 ..< close].contains(Byte.less) else {
            return nil
        }
        return WrittenAttribute(name: name, whole: gap ..< close + 1, value: cursor + 1 ..< close, quote: quote)
    }

    /// A qualified name's prefix and local name; the prefix is empty without one.
    private static func split(_ name: String) -> (String, String) {
        guard let colon = name.firstIndex(of: ":") else { return ("", name) }
        return (String(name[..<colon]), String(name[name.index(after: colon)...]))
    }

    // MARK: - Values

    /// An attribute's value, its references replaced; nil when one isn't XML's.
    func decode(_ range: Range<Int>) -> String? {
        var decoded: [UInt8] = []
        decoded.reserveCapacity(range.count)
        var index = range.lowerBound
        while index < range.upperBound {
            if bytes[index] == Byte.ampersand {
                guard let (scalar, end) = reference(at: index, before: range.upperBound) else { return nil }
                decoded.append(contentsOf: scalar)
                index = end
            } else {
                decoded.append(bytes[index])
                index += 1
            }
        }
        return Self.text(decoded)
    }

    /// The text of `range` inside an element: references replaced, CDATA as it is, comments and
    /// processing instructions left out. Nil when it holds an element or a reference XML doesn't
    /// define.
    func text(_ range: Range<Int>) -> String? {
        var decoded: [UInt8] = []
        decoded.reserveCapacity(range.count)
        var index = range.lowerBound
        while index < range.upperBound {
            let byte = bytes[index]
            if byte == Byte.less {
                if starts("<!--", at: index) {
                    guard let end = find(Array("-->".utf8), from: index + 4), end + 3 <= range.upperBound
                    else { return nil }
                    index = end + 3
                } else if starts("<![CDATA[", at: index) {
                    guard let end = find(Array("]]>".utf8), from: index + 9), end + 3 <= range.upperBound
                    else { return nil }
                    decoded.append(contentsOf: bytes[index + 9 ..< end])
                    index = end + 3
                } else if starts("<?", at: index) {
                    guard let end = find(Array("?>".utf8), from: index + 2), end + 2 <= range.upperBound
                    else { return nil }
                    index = end + 2
                } else {
                    return nil
                }
            } else if byte == Byte.ampersand {
                guard let (scalar, end) = reference(at: index, before: range.upperBound) else { return nil }
                decoded.append(contentsOf: scalar)
                index = end
            } else {
                decoded.append(byte)
                index += 1
            }
        }
        return Self.text(decoded)
    }

    /// UTF-8 as a string, with XML's line ends (CR LF, a lone CR) as LF; nil when it isn't UTF-8.
    private static func text(_ bytes: [UInt8]) -> String? {
        guard var text = String(bytes: bytes, encoding: .utf8) else { return nil }
        if text.contains("\r") {
            text = text.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
        }
        return text
    }

    /// The UTF-8 of the reference at `index`, and where it ends.
    private func reference(at index: Int, before limit: Int) -> ([UInt8], Int)? {
        guard let semicolon = find([Byte.semicolon], from: index + 1), semicolon < limit, semicolon - index <= 12
        else { return nil }
        let name = string(index + 1 ..< semicolon)
        let scalar: Unicode.Scalar? = switch name {
        case "lt": "<"
        case "gt": ">"
        case "amp": "&"
        case "quot": "\""
        case "apos": "'"
        case _ where name.hasPrefix("#x"): UInt32(name.dropFirst(2), radix: 16).flatMap(Unicode.Scalar.init)
        case _ where name.hasPrefix("#"): UInt32(name.dropFirst(1), radix: 10).flatMap(Unicode.Scalar.init)
        default: nil
        }
        guard let scalar else { return nil }
        return (Array(String(Character(scalar)).utf8), semicolon + 1)
    }

    // MARK: - Layout

    /// The spaces and tabs between the line's start and `element`'s `<`; empty when something else is
    /// before it on its line.
    func indentation(of element: Int) -> String {
        let start = elements[element].start.lowerBound
        var index = start
        while index > 0, bytes[index - 1] == Byte.space || bytes[index - 1] == Byte.tab {
            index -= 1
        }
        guard index == 0 || bytes[index - 1] == Byte.newline || bytes[index - 1] == Byte.carriageReturn else {
            return ""
        }
        return string(index ..< start)
    }

    /// Where `element` starts, taking in the line end and indentation before it when nothing else
    /// is on its line before it: what removing it removes.
    func lineStart(of element: Int) -> Int {
        let start = elements[element].start.lowerBound
        var index = start
        while index > 0, bytes[index - 1] == Byte.space || bytes[index - 1] == Byte.tab {
            index -= 1
        }
        guard index > 0, bytes[index - 1] == Byte.newline || bytes[index - 1] == Byte.carriageReturn else {
            return start
        }
        index -= 1
        if bytes[index] == Byte.newline, index > 0, bytes[index - 1] == Byte.carriageReturn {
            index -= 1
        }
        return index
    }

    /// The whitespace before an attribute's name.
    func gap(before attribute: Attribute) -> String {
        var index = attribute.whole.lowerBound
        while index < attribute.whole.upperBound, Byte.isWhitespace(bytes[index]) {
            index += 1
        }
        return string(attribute.whole.lowerBound ..< index)
    }

    func string(_ range: Range<Int>) -> String {
        String(decoding: bytes[range], as: UTF8.self)
    }

    // MARK: - Searching

    func starts(_ prefix: StaticString, at index: Int) -> Bool {
        let count = prefix.utf8CodeUnitCount
        guard index + count <= bytes.count else { return false }
        return prefix.withUTF8Buffer { prefix in
            (0 ..< count).allSatisfy { bytes[index + $0] == prefix[$0] }
        }
    }

    func find(_ pattern: [UInt8], from index: Int) -> Int? {
        guard let first = pattern.first, index < bytes.count else { return nil }
        var cursor = index
        while cursor + pattern.count <= bytes.count {
            if bytes[cursor] == first,
               pattern.count == 1 || bytes[cursor ..< cursor + pattern.count].elementsEqual(pattern) {
                return cursor
            }
            cursor += 1
        }
        return nil
    }
}

enum Byte {
    static let tab: UInt8 = 0x09
    static let newline: UInt8 = 0x0A
    static let carriageReturn: UInt8 = 0x0D
    static let space: UInt8 = 0x20
    static let quote: UInt8 = 0x22
    static let ampersand: UInt8 = 0x26
    static let apostrophe: UInt8 = 0x27
    static let slash: UInt8 = 0x2F
    static let semicolon: UInt8 = 0x3B
    static let less: UInt8 = 0x3C
    static let equals: UInt8 = 0x3D
    static let greater: UInt8 = 0x3E

    static func isWhitespace(_ byte: UInt8) -> Bool {
        byte == space || byte == newline || byte == carriageReturn || byte == tab
    }

    static func isName(_ byte: UInt8) -> Bool {
        !isWhitespace(byte) && byte != slash && byte != greater && byte != equals && byte != less && byte != quote
            && byte != apostrophe
    }
}
