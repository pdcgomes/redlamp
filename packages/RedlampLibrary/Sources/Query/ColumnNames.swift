import Foundation
import RedlampDocument

/// The names a column of the store holds codes of (LIB-06): creators, copyrights, custom labels and
/// the parts of places. Code 0 is none, and a name gets the next code the first time it's seen and
/// keeps it while the store lives, even once no photo has it. Past `limit` names, the rest share the
/// last code, as cameras past 65,535 do.
struct NameCodes: Sendable {
    /// The names by code: "" for code 0.
    private(set) var names: ContiguousArray<String> = [""]
    private var codes: [String: UInt32] = [:]
    /// Each name with A to Z lowercased, when it's all ASCII, so `QueryText.contains` runs byte by byte.
    private var lowercased: ContiguousArray<ContiguousArray<UInt8>?> = [nil]
    /// The other names folded (`FoldedText`), by code.
    private var folded: [Int: FoldedText] = [:]
    let limit: UInt32

    init(limit: UInt32) {
        self.limit = limit
    }

    /// The codes of `names` in order, `names[0]` being none, as the snapshot saves them (LIB-44).
    init(names: [String], limit: UInt32) {
        self.init(limit: limit)
        for name in names.dropFirst() {
            _ = code(for: name)
        }
    }

    /// Names, none included.
    var count: Int {
        names.count
    }

    /// The code of `name`, given one the first time it's seen; 0 for none or an empty name.
    mutating func code(for name: String?) -> UInt32 {
        guard let name, !name.isEmpty else { return 0 }
        if let code = codes[name] {
            return code
        }
        guard names.count <= Int(limit) else { return limit }
        let code = UInt32(names.count)
        names.append(name)
        let ascii = QueryText.asciiLowercased(name)
        lowercased.append(ascii)
        if ascii == nil {
            folded[Int(code)] = FoldedText(name)
        }
        codes[name] = code
        return code
    }

    /// The name of `code`; nil for none.
    func name(of code: Int) -> String? {
        code > 0 && code < names.count ? names[code] : nil
    }

    /// The codes whose names hold `part`, ignoring case, accents and width, as `QueryText.contains`
    /// finds it.
    func codes(containing part: String) -> [UInt32] {
        let needle = FoldedText(part)
        var found: [UInt32] = []
        for code in 1 ..< names.count {
            let matches = if let name = lowercased[code] {
                FoldedText(ascii: name).contains(needle)
            } else {
                folded[code]?.contains(needle) ?? false
            }
            if matches {
                found.append(UInt32(code))
            }
        }
        return found
    }

    /// The codes whose names are `name`, ignoring case, accents and width, as `QueryText.isSame`
    /// compares them.
    func codes(named name: String) -> [UInt32] {
        let wanted = QueryText.asciiLowercased(name)
        var found: [UInt32] = []
        for code in 1 ..< names.count {
            let matches = if let wanted, let candidate = lowercased[code] {
                candidate == wanted
            } else {
                QueryText.isSame(names[code], name)
            }
            if matches {
                found.append(UInt32(code))
            }
        }
        return found
    }

    /// Bytes its names and tables take, about.
    var memoryFootprint: Int {
        let text = names.reduce(0) { $0 + $1.utf8.count } * 3
        let folding = folded.values.reduce(0) { $0 + $1.bytes.count * 2 } + folded.capacity * 24
        return text + names.capacity * 16 + lowercased.capacity * 8 + codes.capacity * 24 + folding
    }
}

/// The places photos are at, as IPTC Core's location has them: each place is its five parts'
/// codes together (a place within the city, the city, the state or province, the country and its
/// code), each part's names kept on their own, so a term on one part looks through that part's
/// names alone. Place 0 is none.
struct PlaceCodes: Sendable {
    enum Part: Int, Sendable, Hashable, CaseIterable {
        case sublocation, city, state, country, countryCode

        /// The part `field` filters; nil for a field that isn't one.
        init?(_ field: LibraryQuery.Field) {
            switch field {
            case .sublocation: self = .sublocation
            case .city: self = .city
            case .state: self = .state
            case .country: self = .country
            case .countryCode: self = .countryCode
            default: return nil
            }
        }

        /// Its column in the index.
        var column: String {
            switch self {
            case .sublocation: "sublocation"
            case .city: "city"
            case .state: "province"
            case .country: "country"
            case .countryCode: "country_code"
            }
        }

        func name(in location: PhotoLocation) -> String? {
            switch self {
            case .sublocation: location.sublocation
            case .city: location.city
            case .state: location.state
            case .country: location.country
            case .countryCode: location.countryCode
            }
        }
    }

    /// Each part's names, in `Part`'s order.
    private(set) var parts = [NameCodes](repeating: NameCodes(limit: .max), count: Part.allCases.count)
    /// The parts' codes of each place, `Part.allCases.count` a place.
    private var placeParts = ContiguousArray<UInt32>(repeating: 0, count: Part.allCases.count)
    private var codes: [Key: UInt32] = [:]

    private struct Key: Hashable {
        var sublocation, city, state, country, countryCode: UInt32
    }

    init() {}

    /// The places of `placeParts`, each its five parts' codes into `parts`' names, as the snapshot
    /// saves them (LIB-44); nil when they don't make places.
    init?(parts names: [[String]], placeParts: [UInt32]) {
        let width = Part.allCases.count
        guard names.count == width, placeParts.count >= width, placeParts.count % width == 0,
              placeParts.prefix(width).allSatisfy({ $0 == 0 })
        else { return nil }
        parts = names.map { NameCodes(names: $0, limit: .max) }
        guard zip(parts, names).allSatisfy({ $0.count == $1.count }) else { return nil }
        self.placeParts = ContiguousArray(placeParts)
        for place in 1 ..< placeParts.count / width {
            let part = placeParts[place * width ..< (place + 1) * width]
            guard zip(part, parts).allSatisfy({ Int($0) < $1.count }) else { return nil }
            let at = part.startIndex
            codes[Key(
                sublocation: part[at], city: part[at + 1], state: part[at + 2], country: part[at + 3],
                countryCode: part[at + 4],
            )] = UInt32(place)
        }
    }

    /// Each part's names and the places' parts, as the snapshot saves them.
    var saved: (parts: [[String]], placeParts: [UInt32]) {
        (parts.map { Array($0.names) }, Array(placeParts))
    }

    /// Places, none included.
    var count: Int {
        placeParts.count / Part.allCases.count
    }

    /// The code of `location`'s place, given one the first time it's seen; 0 when it has no part.
    mutating func code(for location: PhotoLocation?) -> UInt32 {
        guard let location else { return 0 }
        var part = [UInt32](repeating: 0, count: Part.allCases.count)
        for kind in Part.allCases {
            part[kind.rawValue] = parts[kind.rawValue].code(for: kind.name(in: location))
        }
        guard part.contains(where: { $0 != 0 }) else { return 0 }
        let key = Key(sublocation: part[0], city: part[1], state: part[2], country: part[3], countryCode: part[4])
        if let code = codes[key] {
            return code
        }
        let code = UInt32(count)
        placeParts.append(contentsOf: part)
        codes[key] = code
        return code
    }

    /// The code of `part`'s name at `place`.
    func code(of part: Part, at place: Int) -> UInt32 {
        place < count ? placeParts[place * Part.allCases.count + part.rawValue] : 0
    }

    /// The location of `place`; nil for none.
    func location(of place: Int) -> PhotoLocation? {
        guard place > 0, place < count else { return nil }
        func name(_ part: Part) -> String? {
            parts[part.rawValue].name(of: Int(code(of: part, at: place)))
        }
        return PhotoLocation(
            country: name(.country), state: name(.state), city: name(.city), sublocation: name(.sublocation),
            countryCode: name(.countryCode),
        )
    }

    /// The places whose `part`, or any part when it's nil, holds `text`, ignoring case, accents and
    /// width.
    func places(where part: Part?, contains text: String) -> [UInt32] {
        let kinds = part.map { [$0] } ?? Part.allCases
        var tables: [(Part, ContiguousArray<UInt64>)] = []
        for kind in kinds {
            let found = parts[kind.rawValue].codes(containing: text)
            if !found.isEmpty {
                tables.append((kind, CodeTable.make(found)))
            }
        }
        guard !tables.isEmpty else { return [] }
        return (1 ..< count).compactMap { place in
            tables.contains { CodeTable.contains($0.1, code(of: $0.0, at: place)) } ? UInt32(place) : nil
        }
    }

    var memoryFootprint: Int {
        parts.reduce(0) { $0 + $1.memoryFootprint } + placeParts.capacity * 4 + codes.capacity * 28
    }
}

/// A bit for each of a column's codes.
enum CodeTable {
    static func make(_ codes: some Sequence<UInt32>) -> ContiguousArray<UInt64> {
        var table = ContiguousArray<UInt64>(repeating: 0, count: Int(codes.max() ?? 0) / 64 + 1)
        for code in codes {
            table[Int(code >> 6)] |= 1 << UInt64(code & 63)
        }
        return table
    }

    @inline(__always)
    static func contains(_ table: ContiguousArray<UInt64>, _ code: UInt32) -> Bool {
        let word = Int(code >> 6)
        return word < table.count && table[word] >> UInt64(code & 63) & 1 != 0
    }
}
