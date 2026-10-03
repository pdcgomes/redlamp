import Foundation

/// The Camera Raw settings an XMP packet holds: the properties in the `crs` namespace of its
/// top-level `rdf:Description` elements, in every form XMP allows (XMP Specification Part 1,
/// 7.4–7.9): attributes or elements for simple values, `rdf:Seq` and `rdf:Bag` for lists,
/// `rdf:Alt` for language alternatives, and structures as a nested `rdf:Description`,
/// `rdf:parseType="Resource"` or field attributes. A structure's fields stay inside it, so a
/// profile's own name or process version never reads as the preset's.
struct CameraRawSettings: Sendable {
    static let namespace = "http://ns.adobe.com/camera-raw-settings/1.0/"

    enum Value: Sendable, Equatable {
        /// A simple value, or a language alternative's default text.
        case text(String)
        /// An array of simple values, such as a curve's points.
        case list([String])
        /// A structure's simple fields in the Camera Raw namespace, such as a profile's `Name`.
        case structure([String: String])
        /// An array of structures, such as masks: only how many there are.
        case structures(Int)
    }

    private(set) var values: [String: Value] = [:]

    subscript(name: String) -> Value? {
        values[name]
    }

    func text(_ name: String) -> String? {
        if case let .text(text) = values[name] {
            return text
        }
        return nil
    }

    func number(_ name: String) -> Double? {
        guard let text = text(name), let value = Double(text.trimmingCharacters(in: .whitespaces)) else { return nil }
        return value.isFinite ? value : nil
    }

    /// `True` and `False` in any case, or a number, which is on unless it is zero.
    func flag(_ name: String) -> Bool? {
        switch text(name)?.lowercased() {
        case "true": true
        case "false": false
        default: number(name).map { $0 != 0 }
        }
    }
}

extension CameraRawSettings {
    static let rdf = "http://www.w3.org/1999/02/22-rdf-syntax-ns#"
    static let xml = "http://www.w3.org/XML/1998/namespace"

    /// Reads an XMP packet, or nil when `data` isn't well-formed XML with an `rdf:RDF` element. A
    /// document type declaration is refused: XMP has none, and its entities could expand without
    /// bound. So is anything larger than a recipe file may be.
    init?(xmp data: Data) {
        guard data.count <= RecipeValidator.maximumFileSize, data.range(of: Data("<!DOCTYPE".utf8)) == nil,
              let root = XMLTree.parse(data),
              let rdf = root.first(where: { $0.namespace == Self.rdf && $0.name == "RDF" })
        else { return nil }
        for description in rdf.children where description.namespace == Self.rdf && description.name == "Description" {
            for attribute in description.attributes where attribute.namespace == Self.namespace {
                add(attribute.name, .text(attribute.value))
            }
            for property in description.children where property.namespace == Self.namespace {
                add(property.name, Self.value(of: property))
            }
        }
    }

    /// A property has one value; a repeat in a later description is ignored.
    private mutating func add(_ name: String, _ value: Value) {
        if values[name] == nil {
            values[name] = value
        }
    }

    private static func value(of property: XMLTree.Element) -> Value {
        if let resource = property.attribute("resource", in: rdf) {
            return .text(resource)
        }
        if property.attribute("parseType", in: rdf) == "Resource" {
            return structure(property)
        }
        if let node = property.children.first {
            guard node.namespace == rdf, ["Seq", "Bag", "Alt"].contains(node.name) else {
                // A nested rdf:Description, or a typed node standing in for one.
                return structure(node)
            }
            let items = node.children.filter { $0.namespace == rdf && $0.name == "li" }
            if node.name == "Alt" {
                let chosen = items.first { $0.attribute("lang", in: xml) == "x-default" } ?? items.first
                return .text(chosen?.trimmedText ?? "")
            }
            return items.allSatisfy(isSimple) ? .list(items.map(\.trimmedText)) : .structures(items.count)
        }
        return property.attributes.contains(where: isField) ? structure(property) : .text(property.trimmedText)
    }

    /// A structure's simple Camera Raw fields; a qualified simple value (`rdf:value` beside its
    /// qualifiers) reads as that value.
    private static func structure(_ node: XMLTree.Element) -> Value {
        if let value = node.children.first(where: { $0.namespace == rdf && $0.name == "value" }) {
            return .text(value.trimmedText)
        }
        var fields: [String: String] = [:]
        for attribute in node.attributes where attribute.namespace == namespace {
            fields[attribute.name] = attribute.value
        }
        for field in node.children where field.namespace == namespace && isSimple(field) {
            fields[field.name] = field.trimmedText
        }
        return .structure(fields)
    }

    private static func isSimple(_ element: XMLTree.Element) -> Bool {
        element.children.isEmpty && element.attribute("parseType", in: rdf) == nil
            && !element.attributes.contains(where: isField)
    }

    /// A structure field written as an attribute (XMP Specification Part 1, 7.9.2.4): any but
    /// RDF's own (`rdf:about`, `rdf:parseType`) and `xml:lang`.
    private static func isField(_ attribute: XMLTree.Attribute) -> Bool {
        attribute.namespace != nil && attribute.namespace != rdf && attribute.namespace != xml
    }
}

/// A document's elements with their namespaces resolved, as `XMLParser` reports them.
private final class XMLTree: NSObject, XMLParserDelegate {
    struct Attribute {
        var namespace: String?
        var name: String
        var value: String
    }

    struct Element {
        var namespace: String?
        var name: String
        var attributes: [Attribute]
        var children: [Element] = []
        var text = ""

        var trimmedText: String {
            text.trimmingCharacters(in: .whitespacesAndNewlines)
        }

        func attribute(_ name: String, in namespace: String) -> String? {
            attributes.first { $0.namespace == namespace && $0.name == name }?.value
        }

        /// This element or the first of its descendants, depth first, that `matches`.
        func first(where matches: (Element) -> Bool) -> Element? {
            if matches(self) {
                return self
            }
            for child in children {
                if let found = child.first(where: matches) {
                    return found
                }
            }
            return nil
        }
    }

    private var root: Element?
    private var open: [Element] = []
    /// Each prefix's namespaces, innermost last.
    private var prefixes: [String: [String]] = [:]

    static func parse(_ data: Data) -> Element? {
        let tree = XMLTree()
        let parser = XMLParser(data: data)
        parser.shouldProcessNamespaces = true
        parser.shouldReportNamespacePrefixes = true
        parser.shouldResolveExternalEntities = false
        parser.delegate = tree
        guard parser.parse() else { return nil }
        return tree.root
    }

    func parser(_: XMLParser, didStartMappingPrefix prefix: String, toURI namespaceURI: String) {
        prefixes[prefix, default: []].append(namespaceURI)
    }

    func parser(_: XMLParser, didEndMappingPrefix prefix: String) {
        prefixes[prefix]?.removeLast()
    }

    func parser(
        _: XMLParser,
        didStartElement elementName: String,
        namespaceURI: String?,
        qualifiedName _: String?,
        attributes attributeDict: [String: String] = [:],
    ) {
        // Attribute names arrive qualified; an unprefixed attribute is in no namespace.
        let attributes = attributeDict.map { name, value -> Attribute in
            let parts = name.split(separator: ":", maxSplits: 1).map(String.init)
            guard parts.count == 2 else { return Attribute(namespace: nil, name: name, value: value) }
            let namespace = parts[0] == "xml" ? CameraRawSettings.xml : prefixes[parts[0]]?.last
            return Attribute(namespace: namespace, name: parts[1], value: value)
        }
        let namespace = namespaceURI.flatMap { $0.isEmpty ? nil : $0 }
        open.append(Element(namespace: namespace, name: elementName, attributes: attributes))
    }

    func parser(_: XMLParser, foundCharacters string: String) {
        guard !open.isEmpty else { return }
        open[open.count - 1].text += string
    }

    func parser(_: XMLParser, foundCDATA block: Data) {
        guard !open.isEmpty else { return }
        open[open.count - 1].text += String(decoding: block, as: UTF8.self)
    }

    func parser(_: XMLParser, didEndElement _: String, namespaceURI _: String?, qualifiedName _: String?) {
        guard let element = open.popLast() else { return }
        if open.isEmpty {
            root = element
        } else {
            open[open.count - 1].children.append(element)
        }
    }
}
