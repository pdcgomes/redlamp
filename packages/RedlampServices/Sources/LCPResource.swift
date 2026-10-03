import Foundation

/// RDF as XMP writes it, read into resources: each property's namespace, name and value, whether
/// the file writes it as an attribute (`stCamera:Make="Canon"`) or as an element
/// (`<stCamera:Make>Canon</stCamera:Make>`), and a nested resource as an `rdf:Description` or as a
/// property element with `rdf:parseType="Resource"` (RDF 1.1 XML Syntax). Lens profiles (LNS-04)
/// use every one of these forms.
struct LCPResource: Sendable {
    enum Value: Sendable {
        case literal(String)
        case resource(LCPResource)
        /// The items of an `rdf:Seq`, `rdf:Bag` or `rdf:Alt`.
        case list([Value])

        var resources: [LCPResource] {
            switch self {
            case .literal: []
            case let .resource(resource): [resource]
            case let .list(items): items.flatMap(\.resources)
            }
        }
    }

    struct Property: Sendable {
        var namespace: String
        var name: String
        var value: Value
    }

    var properties: [Property] = []

    func value(_ name: String, in namespace: String) -> Value? {
        properties.first { $0.namespace == namespace && $0.name == name }?.value
    }

    /// The resources a property holds wherever it appears in this resource or the ones inside it,
    /// depth first.
    func resources(under name: String, in namespace: String) -> [LCPResource] {
        properties.flatMap { property in
            property.namespace == namespace && property.name == name
                ? property.value.resources
                : property.value.resources.flatMap { $0.resources(under: name, in: namespace) }
        }
    }
}

extension LCPResource {
    static let rdf = "http://www.w3.org/1999/02/22-rdf-syntax-ns#"
    static let xml = "http://www.w3.org/XML/1998/namespace"

    /// The resources an XMP packet describes (the node elements of its `rdf:RDF`); nil when the
    /// data isn't well-formed XML.
    static func read(_ data: Data) -> [LCPResource]? {
        let tree = XMLTree()
        let parser = XMLParser(data: data)
        parser.shouldProcessNamespaces = true
        parser.shouldReportNamespacePrefixes = true
        parser.delegate = tree
        guard parser.parse(), let root = tree.root else { return nil }
        return root.first { $0.namespace == rdf && $0.name == "RDF" }?.children.map(node) ?? []
    }

    /// A node element: its property attributes and property elements.
    private static func node(_ element: XMLTree.Element) -> LCPResource {
        LCPResource(properties: propertyAttributes(element) + element.children.map { child in
            Property(namespace: child.namespace, name: child.name, value: value(child))
        })
    }

    /// A property element's value, in each of the forms RDF/XML allows.
    private static func value(_ element: XMLTree.Element) -> Value {
        if element.attribute("parseType", in: rdf) == "Resource" {
            return .resource(node(element))
        }
        if let child = element.children.first {
            guard child.namespace == rdf, ["Seq", "Bag", "Alt"].contains(child.name) else {
                return .resource(node(child))
            }
            return .list(child.children.map(value))
        }
        let attributes = propertyAttributes(element)
        return attributes.isEmpty
            ? .literal(element.text.trimmingCharacters(in: .whitespacesAndNewlines))
            : .resource(LCPResource(properties: attributes))
    }

    /// Attributes that are properties: all but RDF's own (`rdf:about`, `rdf:parseType`) and `xml:lang`.
    private static func propertyAttributes(_ element: XMLTree.Element) -> [Property] {
        element.attributes.filter { $0.namespace != rdf && $0.namespace != xml }.map { attribute in
            Property(namespace: attribute.namespace, name: attribute.name, value: .literal(attribute.value))
        }
    }
}

/// A document's elements with their namespaces resolved, as `XMLParser` reports them.
private final class XMLTree: NSObject, XMLParserDelegate {
    struct Attribute {
        var namespace: String
        var name: String
        var value: String
    }

    struct Element {
        var namespace: String
        var name: String
        var attributes: [Attribute]
        var children: [Element] = []
        var text = ""

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

    private(set) var root: Element?
    private var open: [Element] = []
    /// Each prefix's namespaces, innermost last.
    private var prefixes: [String: [String]] = [:]

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
        let attributes = attributeDict.sorted { $0.key < $1.key }.map { name, value -> Attribute in
            let parts = name.split(separator: ":", maxSplits: 1).map(String.init)
            guard parts.count == 2 else { return Attribute(namespace: "", name: name, value: value) }
            let namespace = parts[0] == "xml" ? LCPResource.xml : prefixes[parts[0]]?.last
            return Attribute(namespace: namespace ?? parts[0], name: parts[1], value: value)
        }
        open.append(Element(namespace: namespaceURI ?? "", name: elementName, attributes: attributes))
    }

    func parser(_: XMLParser, foundCharacters string: String) {
        guard !open.isEmpty else { return }
        open[open.count - 1].text += string
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
