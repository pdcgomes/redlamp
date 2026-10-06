import Foundation

/// A property of an XMP packet, by namespace and name, whatever prefix a file gives it.
struct XMPProperty: Sendable, Hashable, Comparable {
    let namespace: String
    let name: String

    init(_ namespace: String, _ name: String) {
        self.namespace = namespace
        self.name = name
    }

    static func < (lhs: XMPProperty, rhs: XMPProperty) -> Bool {
        (lhs.namespace, lhs.name) < (rhs.namespace, rhs.name)
    }
}

/// A value Redlamp writes: simple text, an unordered or ordered array of text (`rdf:Bag`, `rdf:Seq`),
/// or a language alternative's default (`rdf:Alt` with `xml:lang="x-default"`). An array written over
/// one keeps the kind it had.
enum XMPValue: Sendable, Hashable {
    case text(String)
    case bag([String])
    case seq([String])
    case alternative(String)
}

/// An XMP packet (XMP Specification Part 1, 7), read as far as its top-level properties: those of
/// the `rdf:Description` elements of its `rdf:RDF`, in either form RDF allows (attributes or
/// elements). Editing sets or removes properties and copies every other byte as it was, so what
/// other apps wrote, in whatever layout, comes back unchanged.
struct XMPPacket: Sendable {
    static let rdf = "http://www.w3.org/1999/02/22-rdf-syntax-ns#"
    static let meta = "adobe:ns:meta/"

    /// Where a top-level property is written.
    enum Place: Sendable, Hashable {
        /// An attribute of a description.
        case attribute(description: Int, index: Int)
        /// A child element of a description.
        case element(Int)
    }

    let xml: XMLElements
    let rdfElement: Int
    /// The `rdf:Description` children of `rdf:RDF`.
    let descriptions: [Int]

    /// Nil when `data` isn't XML in UTF-8 holding an `rdf:RDF` element.
    init?(_ data: Data) {
        self.init(bytes: [UInt8](data))
    }

    init?(bytes: [UInt8]) {
        guard let xml = XMLElements(bytes) else { return nil }
        var pending = [xml.root]
        var found: Int?
        while let element = pending.popLast() {
            if xml.elements[element].namespace == Self.rdf, xml.elements[element].name == "RDF" {
                found = element
                break
            }
            pending.append(contentsOf: xml.elements[element].children.reversed())
        }
        guard let found else { return nil }
        self.xml = xml
        rdfElement = found
        descriptions = xml.elements[found].children.filter {
            xml.elements[$0].namespace == Self.rdf && xml.elements[$0].name == "Description"
        }
    }

    var data: Data {
        Data(xml.bytes)
    }

    // MARK: - Reading

    /// Every place `property` is written, in document order: once, in a well-formed packet.
    func places(_ property: XMPProperty) -> [Place] {
        var found: [Place] = []
        for description in descriptions {
            let element = xml.elements[description]
            for (index, attribute) in element.attributes.enumerated()
                where !attribute.declaresNamespace && attribute.namespace == property.namespace
                && attribute.name == property.name {
                found.append(.attribute(description: description, index: index))
            }
            for child in element.children
                where xml.elements[child].namespace == property.namespace && xml.elements[child].name == property.name {
                found.append(.element(child))
            }
        }
        return found
    }

    func has(_ property: XMPProperty) -> Bool {
        !places(property).isEmpty
    }

    /// Every top-level property, with its value as written (an attribute's value, an element's
    /// content and attributes): what an edit leaves alone must come back the same.
    func properties() -> [(property: XMPProperty, written: String)] {
        var found: [(XMPProperty, String)] = []
        for description in descriptions {
            let element = xml.elements[description]
            for attribute in element.attributes where Self.isProperty(attribute) {
                guard let namespace = attribute.namespace else { continue }
                found.append((XMPProperty(namespace, attribute.name), xml.string(attribute.value)))
            }
            for child in element.children {
                let property = xml.elements[child]
                guard let namespace = property.namespace else { continue }
                let attributes = property.attributes.map { xml.string($0.whole) }.joined()
                found.append((XMPProperty(namespace, property.name), attributes + "|" + xml.string(property.content)))
            }
        }
        return found
    }

    /// A simple property's text: an attribute's value, an element's text or its `rdf:resource`.
    func text(_ property: XMPProperty) -> String? {
        guard let place = places(property).first else { return nil }
        switch place {
        case let .attribute(description, index):
            return xml.decode(xml.elements[description].attributes[index].value)
        case let .element(id):
            let element = xml.elements[id]
            if let resource = element.attribute(Self.rdf, "resource") {
                return xml.decode(resource.value)
            }
            guard element.children.isEmpty else { return nil }
            return xml.text(element.content)
        }
    }

    /// An array's items: each item's text of a `rdf:Bag` or `rdf:Seq`; a simple value as one item.
    func items(_ property: XMPProperty) -> [String] {
        guard let place = places(property).first else { return [] }
        if case let .element(id) = place, let array = array(in: id) {
            return array.items.compactMap(itemText)
        }
        return text(property).map { [$0] } ?? []
    }

    /// A language alternative's text in the default language, or else its first; a simple value as
    /// it is.
    func alternative(_ property: XMPProperty) -> String? {
        guard let place = places(property).first else { return nil }
        if case let .element(id) = place, let array = array(in: id) {
            return (defaultItem(of: array.items) ?? array.items.first).flatMap(itemText)
        }
        return text(property)
    }

    enum ArrayKind: String, Sendable {
        case bag = "Bag"
        case seq = "Seq"
        case alt = "Alt"
    }

    /// The `rdf:Bag`, `rdf:Seq` or `rdf:Alt` a property element holds, and its `rdf:li` items.
    func array(in id: Int) -> (element: Int, kind: ArrayKind, items: [Int])? {
        for child in xml.elements[id].children where xml.elements[child].namespace == Self.rdf {
            guard let kind = ArrayKind(rawValue: xml.elements[child].name) else { continue }
            let items = xml.elements[child].children.filter {
                xml.elements[$0].namespace == Self.rdf && xml.elements[$0].name == "li"
            }
            return (child, kind, items)
        }
        return nil
    }

    /// Whether a language alternative has an item in a language other than the default.
    func hasOtherLanguages(_ property: XMPProperty) -> Bool {
        guard case let .element(id)? = places(property).first, let array = array(in: id), array.kind == .alt
        else { return false }
        return array.items.contains { item in
            xml.elements[item].attribute(XMLElements.xmlNamespace, "lang").flatMap { xml.decode($0.value) }?
                .lowercased() != "x-default"
        }
    }

    func defaultItem(of items: [Int]) -> Int? {
        items.first { item in
            xml.elements[item].attribute(XMLElements.xmlNamespace, "lang").flatMap { xml.decode($0.value) }?
                .lowercased() == "x-default"
        }
    }

    private func itemText(_ item: Int) -> String? {
        let element = xml.elements[item]
        if let resource = element.attribute(Self.rdf, "resource") {
            return xml.decode(resource.value)
        }
        guard element.children.isEmpty else { return nil }
        return xml.text(element.content)
    }

    /// An attribute of a description that's a property: not a namespace declaration, nor RDF's or
    /// XML's own.
    static func isProperty(_ attribute: XMLElements.Attribute) -> Bool {
        !attribute.declaresNamespace && attribute.namespace != nil && attribute.namespace != rdf
            && attribute.namespace != XMLElements.xmlNamespace
    }
}

// MARK: - Editing

extension XMPPacket {
    private struct Edit {
        var range: Range<Int>
        var replacement: String
    }

    /// The packet with each property in `changes` set to its value, or removed where it's nil, and
    /// every other byte as it was; nil when the packet can't be edited so (it has no description to
    /// add to, say, or the edits would cross). A property added goes in the first description that
    /// already has one of its namespace, else the first: text as an attribute, arrays as elements,
    /// with the namespace declared where it isn't in scope, under `prefixes`' name for it.
    func editing(_ changes: [(XMPProperty, XMPValue?)], prefixes: [String: String]) -> [UInt8]? {
        guard !descriptions.isEmpty else {
            return withDescription().flatMap { $0.editing(changes, prefixes: prefixes) }
        }
        var edits: [Edit] = []
        var attributesAdded: [Int: [(XMPProperty, String)]] = [:]
        var elementsAdded: [Int: [(XMPProperty, XMPValue)]] = [:]
        for (property, value) in changes {
            let places = places(property)
            guard let value else {
                edits += places.map(removal)
                continue
            }
            guard let first = places.first else {
                let target = target(for: property)
                if case let .text(text) = value {
                    attributesAdded[target, default: []].append((property, text))
                } else {
                    elementsAdded[target, default: []].append((property, value))
                }
                continue
            }
            edits += places.dropFirst().map(removal)
            switch (first, value) {
            case let (.attribute(description, index), .text(text)):
                let attribute = xml.elements[description].attributes[index]
                edits.append(Edit(range: attribute.value, replacement: Self.escape(text, quote: attribute.quote)))
            case let (.attribute(description, _), _):
                edits.append(removal(first))
                elementsAdded[description, default: []].append((property, value))
            case let (.element(id), _):
                guard let edit = replacing(id, with: value) else { return nil }
                edits.append(edit)
            }
        }
        for description in Set(attributesAdded.keys).union(elementsAdded.keys).sorted() {
            edits += adding(
                to: description, attributes: attributesAdded[description] ?? [],
                elements: elementsAdded[description] ?? [], prefixes: prefixes,
            )
        }
        return apply(edits)
    }

    /// A packet of nothing but an empty description, as Redlamp starts a new `.xmp`.
    static func empty(toolkit: String) -> XMPPacket {
        let text = """
        <x:xmpmeta xmlns:x="adobe:ns:meta/" x:xmptk="\(escape(toolkit, quote: Byte.quote))">
         <rdf:RDF xmlns:rdf="http://www.w3.org/1999/02/22-rdf-syntax-ns#">
          <rdf:Description
            rdf:about=""/>
         </rdf:RDF>
        </x:xmpmeta>

        """
        guard let packet = XMPPacket(bytes: Array(text.utf8)) else { preconditionFailure("the empty packet parses") }
        return packet
    }

    /// The packet with an empty description added to its `rdf:RDF`.
    private func withDescription() -> XMPPacket? {
        let rdf = xml.elements[rdfElement]
        let rdfPrefix = rdf.prefix.isEmpty ? "" : rdf.prefix + ":"
        let indentation = xml.indentation(of: rdfElement)
        let description = "<\(rdfPrefix)Description \(rdfPrefix)about=\"\"/>"
        let edit = if rdf.end == nil {
            Edit(
                range: rdf.start.upperBound - 2 ..< rdf.start.upperBound,
                replacement: ">\n\(indentation) \(description)\n\(indentation)</\(rdf.qualifiedName)>",
            )
        } else {
            Edit(range: rdf.start.upperBound ..< rdf.start.upperBound, replacement: "\n\(indentation) \(description)")
        }
        return apply([edit]).flatMap { XMPPacket(bytes: $0) }
    }

    /// Where a new property goes: the first description with one of its namespace already, else
    /// the first.
    private func target(for property: XMPProperty) -> Int {
        descriptions.first { description in
            let element = xml.elements[description]
            return element.attributes.contains { Self.isProperty($0) && $0.namespace == property.namespace }
                || element.children.contains { xml.elements[$0].namespace == property.namespace }
        } ?? descriptions[0]
    }

    /// Removes the property at `place`: an attribute with the space before it, an element with its
    /// line when nothing else is on it.
    private func removal(_ place: Place) -> Edit {
        switch place {
        case let .attribute(description, index):
            Edit(range: xml.elements[description].attributes[index].whole, replacement: "")
        case let .element(id):
            Edit(range: xml.lineStart(of: id) ..< xml.elements[id].whole.upperBound, replacement: "")
        }
    }

    /// Sets the property element `id` to `value`: its text, or its default language's item, in
    /// place where it can; otherwise the element is written again, in the form it had.
    private func replacing(_ id: Int, with value: XMPValue) -> Edit? {
        let element = xml.elements[id]
        let indentation = xml.indentation(of: id)
        let rdfPrefix = prefix(for: Self.rdf, in: element.scope) ?? "rdf"
        switch value {
        case let .text(text):
            if element.children.isEmpty, element.end != nil, element.attribute(Self.rdf, "resource") == nil {
                return Edit(range: element.content, replacement: Self.escape(text))
            }
            return Edit(
                range: element.whole,
                replacement: "<\(element.qualifiedName)>\(Self.escape(text))</\(element.qualifiedName)>",
            )
        case let .bag(items), let .seq(items):
            let written: ArrayKind = if case .seq = value {
                .seq
            } else {
                .bag
            }
            let kind = array(in: id).map(\.kind).flatMap { $0 == .alt ? nil : $0 } ?? written
            return Edit(
                range: element.whole,
                replacement: Self.array(
                    element.qualifiedName, kind: kind, items: items, indentation: indentation, rdf: rdfPrefix,
                ),
            )
        case let .alternative(text):
            if let array = array(in: id), array.kind == .alt {
                if let item = defaultItem(of: array.items) {
                    let li = xml.elements[item]
                    if li.children.isEmpty, li.end != nil {
                        return Edit(range: li.content, replacement: Self.escape(text))
                    }
                    return Edit(range: li.whole, replacement: Self.defaultItem(text, rdf: rdfPrefix))
                }
                if let first = array.items.first {
                    let start = xml.elements[first].start.lowerBound
                    return Edit(
                        range: start ..< start,
                        replacement: Self.defaultItem(text, rdf: rdfPrefix) + "\n" + xml.indentation(of: first),
                    )
                }
            }
            return Edit(
                range: element.whole,
                replacement: Self.alternative(element.qualifiedName, text, indentation: indentation, rdf: rdfPrefix),
            )
        }
    }

    /// Adds properties to `description`: text as attributes after its last, laid out as it is, and
    /// arrays as elements after its last child, declaring their namespaces on it where they aren't
    /// in scope.
    private func adding(
        to description: Int, attributes: [(XMPProperty, String)], elements: [(XMPProperty, XMPValue)],
        prefixes: [String: String],
    ) -> [Edit] {
        let element = xml.elements[description]
        var scope = element.scope
        var declarations: [String] = []
        func prefix(of namespace: String) -> String {
            if let found = self.prefix(for: namespace, in: scope) {
                return found
            }
            let preferred = prefixes[namespace] ?? "ns"
            var name = preferred
            var number = 1
            while scope[name] != nil || name == "xml" || name == "xmlns" {
                name = preferred + String(number)
                number += 1
            }
            scope[name] = namespace
            declarations.append("xmlns:\(name)=\"\(Self.escape(namespace, quote: Byte.quote))\"")
            return name
        }
        let rdfPrefix = self.prefix(for: Self.rdf, in: scope) ?? "rdf"
        let named = attributes.map { property, text in (prefix(of: property.namespace), property, text) }
        let children = elements.map { property, value in (prefix(of: property.namespace), property, value) }

        let last = element.attributes.last
        let gap = last.map { xml.gap(before: $0) } ?? " "
        let attributeEnd = last?.whole.upperBound ?? element.start.lowerBound + 1 + element.qualifiedName.utf8.count
        let attributeText = (declarations + named.map { prefix, property, text in
            "\(prefix):\(property.name)=\"\(Self.escape(text, quote: Byte.quote))\""
        }).map { gap + $0 }.joined()

        let indentation = xml.indentation(of: description)
        let childIndentation = element.children.first.map { xml.indentation(of: $0) } ?? indentation + " "
        let childText = children.map { prefix, property, value in
            let name = "\(prefix):\(property.name)"
            let written = switch value {
            case let .text(text): "<\(name)>\(Self.escape(text))</\(name)>"
            case let .bag(items):
                Self.array(name, kind: .bag, items: items, indentation: childIndentation, rdf: rdfPrefix)
            case let .seq(items):
                Self.array(name, kind: .seq, items: items, indentation: childIndentation, rdf: rdfPrefix)
            case let .alternative(text):
                Self.alternative(name, text, indentation: childIndentation, rdf: rdfPrefix)
            }
            return "\n" + childIndentation + written
        }.joined()

        if element.end == nil {
            guard !childText.isEmpty else {
                return [Edit(range: attributeEnd ..< attributeEnd, replacement: attributeText)]
            }
            return [Edit(
                range: attributeEnd ..< element.start.upperBound,
                replacement: attributeText + ">" + childText + "\n" + indentation + "</\(element.qualifiedName)>",
            )]
        }
        var edits: [Edit] = []
        if !attributeText.isEmpty {
            edits.append(Edit(range: attributeEnd ..< attributeEnd, replacement: attributeText))
        }
        if !childText.isEmpty {
            let position = element.children.last.map { xml.elements[$0].whole.upperBound } ?? element.start.upperBound
            edits.append(Edit(range: position ..< position, replacement: childText))
        }
        return edits
    }

    /// The prefix bound to `namespace` in `scope`, the shortest and then the first by name.
    private func prefix(for namespace: String, in scope: [String: String]) -> String? {
        scope.filter { !$0.key.isEmpty && $0.value == namespace }.keys
            .min { ($0.count, $0) < ($1.count, $1) }
    }

    /// The bytes with `edits` made; nil when two of them cross.
    private func apply(_ edits: [Edit]) -> [UInt8]? {
        var merged: [Edit] = []
        let ordered = edits.enumerated().sorted {
            ($0.element.range.lowerBound, $0.element.range.count, $0.offset)
                < ($1.element.range.lowerBound, $1.element.range.count, $1.offset)
        }.map(\.element)
        for edit in ordered {
            if let last = merged.last, last.range.isEmpty, edit.range.isEmpty, last.range == edit.range {
                merged[merged.count - 1].replacement += edit.replacement
                continue
            }
            if let last = merged.last, edit.range.lowerBound < last.range.upperBound {
                return nil
            }
            merged.append(edit)
        }
        var result: [UInt8] = []
        result.reserveCapacity(xml.bytes.count + merged.reduce(0) { $0 + $1.replacement.utf8.count })
        var cursor = 0
        for edit in merged {
            result.append(contentsOf: xml.bytes[cursor ..< edit.range.lowerBound])
            result.append(contentsOf: edit.replacement.utf8)
            cursor = edit.range.upperBound
        }
        result.append(contentsOf: xml.bytes[cursor...])
        return result
    }

    // MARK: - Writing values

    private static func array(
        _ name: String, kind: ArrayKind, items: [String], indentation: String, rdf: String,
    ) -> String {
        let lines = items.map { "\(indentation)  <\(rdf):li>\(escape($0))</\(rdf):li>" }
        return (["<\(name)>", "\(indentation) <\(rdf):\(kind.rawValue)>"] + lines
            + ["\(indentation) </\(rdf):\(kind.rawValue)>", "\(indentation)</\(name)>"]).joined(separator: "\n")
    }

    private static func alternative(_ name: String, _ text: String, indentation: String, rdf: String) -> String {
        [
            "<\(name)>", "\(indentation) <\(rdf):Alt>", "\(indentation)  " + defaultItem(text, rdf: rdf),
            "\(indentation) </\(rdf):Alt>", "\(indentation)</\(name)>",
        ].joined(separator: "\n")
    }

    private static func defaultItem(_ text: String, rdf: String) -> String {
        "<\(rdf):li xml:lang=\"x-default\">\(escape(text))</\(rdf):li>"
    }

    /// `text` as XML's character data, or as an attribute's value inside `quote`: markup escaped,
    /// line ends and tabs in attributes as references (an attribute's own would read as spaces),
    /// and characters XML 1.0 can't hold left out.
    static func escape(_ text: String, quote: UInt8? = nil) -> String {
        var escaped = ""
        escaped.reserveCapacity(text.utf8.count)
        for scalar in text.unicodeScalars {
            switch scalar {
            case "&": escaped += "&amp;"
            case "<": escaped += "&lt;"
            case ">": escaped += "&gt;"
            case "\"" where quote == Byte.quote: escaped += "&quot;"
            case "'" where quote == Byte.apostrophe: escaped += "&apos;"
            case "\n" where quote != nil: escaped += "&#xA;"
            case "\r" where quote != nil: escaped += "&#xD;"
            case "\t" where quote != nil: escaped += "&#x9;"
            case "\n", "\r", "\t": escaped.unicodeScalars.append(scalar)
            case _ where scalar.value < 0x20 || (0xFFFE ... 0xFFFF).contains(scalar.value): break
            default: escaped.unicodeScalars.append(scalar)
            }
        }
        return escaped
    }
}
