import Foundation
import RedlampEngineAPI

/// Nine keywords at hand, applied with ⌥1 to ⌥9 (Lightroom Classic's keyword sets, LIB-21): the
/// keywords of an event, a place, the people at it. Keywords can be in any number of sets, and a set
/// changes nothing in the photos.
public struct KeywordSet: Sendable, Hashable, Identifiable {
    public static let size = 9
    /// The set of the nine keywords applied last, which every library has.
    public static let recentName = "Recent Keywords"

    public var name: String
    /// Its nine places in order, ⌥1 to ⌥9; nil where one is empty.
    public var keywords: [KeywordPath?]

    public var id: String {
        name
    }

    /// The set named `name` with `keywords` in its places from the first, nine at most.
    public init(name: String, keywords: [KeywordPath?]) {
        self.name = name
        self.keywords = Array((keywords + Array(repeating: nil, count: Self.size)).prefix(Self.size))
    }

    /// The keyword ⌥`number` applies, 1 to 9.
    public func keyword(forShortcut number: Int) -> KeywordPath? {
        (1 ... Self.size).contains(number) ? keywords[number - 1] : nil
    }

    /// The nine keywords applied last, the latest first.
    public static func recent(_ keywords: [KeywordPath]) -> KeywordSet {
        KeywordSet(name: recentName, keywords: keywords)
    }

    /// The sets a library starts with, under Lightroom Classic's names for its own; they're the
    /// user's to change or remove.
    public static let builtIn: [KeywordSet] = [
        ("Outdoor Photography", [
            "Landscape", "Wildlife", "Macro", "Flowers & Plants", "Sunset", "Mountains", "Water", "Snow", "Hiking",
        ]),
        ("Portrait Photography", [
            "Portrait", "Studio", "Headshot", "Family", "Couple", "Children", "Group", "Candid", "Black & White",
        ]),
        ("Wedding Photography", [
            "Bride", "Groom", "Ceremony", "Reception", "Family", "Friends", "Getting Ready", "Details", "Candid",
        ]),
    ].map { name, keywords in KeywordSet(name: name, keywords: keywords.map(KeywordPath.init)) }

    // MARK: - JSON

    /// `{"name": "Wedding", "keywords": ["Bride", null, "Groom"]}`, empty places at the end left out.
    var json: JSONValue {
        var places = keywords.map { $0.map { JSONValue.string($0.text) } ?? .null }
        while places.last == .null {
            places.removeLast()
        }
        return .object(["name": .string(name), "keywords": .array(places)])
    }

    init?(json: JSONValue) {
        guard case let .object(object) = json, let name = object["name"]?.textValue else { return nil }
        var keywords: [KeywordPath?] = []
        if case let .array(places)? = object["keywords"] {
            keywords = places.map { $0.textValue.flatMap(KeywordPath.init) }
        }
        self.init(name: name, keywords: keywords)
    }
}
