import Foundation
import RedlampDocument

/// What the photos a query finds can be counted by.
public enum Facet: String, Sendable, Hashable, CaseIterable {
    case camera, lens, rating, flag, label, year, month, folder, kind
    case day, iso, focal, aperture
    /// IPTC Core's creator, and its location's city and country.
    case creator, city, country
    /// A label's name outside the five colours.
    case customLabel
    /// Which way the photos are turned: landscape, portrait, square.
    case orientation
}

/// How many of a query's photos share each value of a facet.
public struct FacetCounts: Sendable, Hashable {
    public let facet: Facet
    /// The values the photos have, in the value's order (names alphabetically, numbers and dates
    /// ascending), photos without one last.
    public let values: [FacetValue]

    public init(facet: Facet, values: [FacetValue]) {
        self.facet = facet
        self.values = values
    }

    /// Every photo is counted once.
    public var total: Int {
        values.reduce(0) { $0 + $1.count }
    }
}

public struct FacetValue: Sendable, Hashable {
    /// The value as the query language writes it (a camera's name, `3`, `pick`, `red`, `2019-06`, a
    /// folder's path, `raw`); nil for photos without one.
    public let name: String?
    public let count: Int
    /// The filter that finds these photos, when the language has one.
    public let filter: LibraryQuery?

    public init(name: String?, count: Int, filter: LibraryQuery?) {
        self.name = name
        self.count = count
        self.filter = filter
    }
}

public extension QueryEngine {
    /// How `query`'s photos count by each of `facets`, a pass over the column store each, handed
    /// over as each pass ends. A search or a request for facets made after this one cancels it;
    /// before the store is built, it waits for it.
    func facets(
        _ facets: [Facet] = Facet.allCases, for query: LibraryQuery,
    ) -> AsyncThrowingStream<FacetCounts, any Error> {
        let (stream, continuation) = AsyncThrowingStream.makeStream(of: FacetCounts.self)
        let task = Task.detached(priority: .utility) { [self] in
            do {
                guard let (store, vocabulary, generation) = await loadedSnapshot() else {
                    return continuation.finish()
                }
                var matches = try await matches(
                    for: query.searchable, in: store, vocabulary: vocabulary, generation: generation,
                )
                if !query.findsUnreadable {
                    matches = store.readable(matches)
                }
                for facet in facets {
                    try Task.checkCancellation()
                    try continuation.yield(store.counts(by: facet, of: matches, names: vocabulary.names))
                }
                continuation.finish()
            } catch {
                continuation.finish(throwing: error)
            }
        }
        continuation.onTermination = { _ in task.cancel() }
        startFacets(task)
        return stream
    }
}

extension ColumnStore {
    /// How the rows of `matches` count by `facet`. Throws `CancellationError` when the task running
    /// it is cancelled partway.
    func counts(by facet: Facet, of matches: RowBits, names: QueryNames) throws -> FacetCounts {
        switch facet {
        case .camera:
            return try FacetCounts(
                facet: facet,
                values: named(counts(matches, cameras, size: cameraIDs.count)) { code in
                    code == 0 ? nil : names.cameras[cameraIDs[code]].map { ($0, .camera) }
                },
            )
        case .lens:
            return try FacetCounts(facet: facet, values: named(counts(matches, lenses, size: lensIDs.count)) { code in
                code == 0 ? nil : names.lenses[lensIDs[code]].map { ($0, .lens) }
            })
        case .folder:
            let size = Int(folders.max() ?? 0) + 1
            return try FacetCounts(facet: facet, values: named(counts(matches, folders, size: size)) { id in
                names.folders[Int64(id)].map { ($0, .folder) }
            })
        case .rating:
            let counts = try counts(matches, packed, size: 8) { Int(Packed.rating($0)) }
            return FacetCounts(facet: facet, values: counts.enumerated().compactMap { rating, count in
                count == 0 ? nil : FacetValue(
                    name: String(rating), count: count,
                    filter: .filter(LibraryQuery.Filter(.rating, .equal, [.number(Double(rating))])),
                )
            })
        case .flag:
            let counts = try counts(matches, packed, size: 4) { Int(Packed.flag($0)) }
            return FacetCounts(facet: facet, values: Self.coded(counts) { code in
                code > 2 ? nil : .flag(PhotoRecord.flag(code: code))
            })
        case .label:
            return try FacetCounts(facet: facet, values: labelCounts(of: matches))
        case .kind:
            let counts = try counts(matches, kinds, size: 256)
            return FacetCounts(facet: facet, values: Self.coded(counts) { code in
                PhotoRecord.Kind(rawValue: code).flatMap { $0 == .other ? nil : .kind($0) }
            })
        case .year, .month, .day:
            return try dates(of: matches, by: facet)
        case .iso:
            return try FacetCounts(facet: facet, values: numbered(counts(matches, iso, size: 1 << 16), .iso, scale: 1))
        case .focal:
            return try FacetCounts(
                facet: facet, values: numbered(counts(matches, focal, size: 1 << 16), .focal, scale: 10),
            )
        case .aperture:
            return try FacetCounts(
                facet: facet, values: numbered(counts(matches, aperture, size: 1 << 16), .aperture, scale: 100),
            )
        case .creator:
            let names = creatorNames
            return try FacetCounts(facet: facet, values: named(counts(matches, creators, size: names.count)) { code in
                names.name(of: code).map { ($0, .creator) }
            })
        case .customLabel:
            let names = customLabelNames
            return try FacetCounts(
                facet: facet,
                values: named(counts(matches, customLabels, size: names.count)) { code in
                    names.name(of: code).map { ($0, .label) }
                },
            )
        case .city:
            return try FacetCounts(facet: facet, values: placeCounts(of: matches, .city, field: .city))
        case .country:
            return try FacetCounts(facet: facet, values: placeCounts(of: matches, .country, field: .country))
        case .orientation:
            let counts = try counts(matches, orientations, size: PhotoOrientation.allCases.count + 1)
            func value(_ orientation: PhotoOrientation?) -> FacetValue {
                FacetValue(
                    name: orientation?.rawValue, count: counts[Int(orientation?.code ?? 0)],
                    filter: .filter(LibraryQuery.Filter(.orientation, .equal, [.orientation(orientation)])),
                )
            }
            let ways: [PhotoOrientation?] = PhotoOrientation.allCases + [nil]
            return FacetCounts(facet: facet, values: ways.map(value).filter { $0.count > 0 })
        }
    }

    /// Counts by a part of the photos' places, by its name, those without one last.
    private func placeCounts(of matches: RowBits, _ part: PlaceCodes.Part, field: LibraryQuery.Field) throws
        -> [FacetValue] {
        let byPlace = try counts(matches, places, size: placeNames.count)
        let names = placeNames.parts[part.rawValue]
        var byName = [Int](repeating: 0, count: names.count)
        for (place, count) in byPlace.enumerated() where count > 0 {
            byName[Int(placeNames.code(of: part, at: place))] += count
        }
        return named(byName) { code in names.name(of: code).map { ($0, field) } }
    }

    /// Counts by colour label, then the photos without one by their custom label's name: `none` for
    /// neither, then the colours, then the custom labels by name.
    private func labelCounts(of matches: RowBits) throws -> [FacetValue] {
        var colours = [Int](repeating: 0, count: 8)
        var custom = [Int](repeating: 0, count: customLabelNames.count)
        try packed.withUnsafeBufferPointer { packed in
            try customLabels.withUnsafeBufferPointer { labels in
                try forEachRow(of: matches) { row in
                    let colour = Int(Packed.label(packed[row]))
                    if colour == 0, labels[row] != 0 {
                        custom[Int(labels[row])] += 1
                    } else {
                        colours[colour] += 1
                    }
                }
            }
        }
        var values = Self.coded(colours) { code in
            code > ColorLabel.allCases.count ? nil : .label(PhotoRecord.label(code: code))
        }
        var unnamed: FacetValue?
        if let last = values.last, last.name == nil {
            unnamed = values.removeLast()
        }
        values += named(custom) { code in customLabelNames.name(of: code).map { ($0, .label) } }
        return values + (unnamed.map { [$0] } ?? [])
    }

    /// Counts by a number's code, `scale` codes a unit, in ascending order, the photos without one last.
    private func numbered(_ counts: [Int], _ field: LibraryQuery.Field, scale: Double) -> [FacetValue] {
        var values: [FacetValue] = []
        for (code, count) in counts.enumerated().dropFirst() where count > 0 {
            let number = Double(code) / scale
            values.append(FacetValue(
                name: LibraryQuery.Value.format(number, for: field), count: count,
                filter: .filter(LibraryQuery.Filter(field, .equal, [.number(number)])),
            ))
        }
        return values + (counts[0] > 0 ? [FacetValue(name: nil, count: counts[0], filter: nil)] : [])
    }

    /// How many rows of `matches` have each value of `column`, by `index`, below `size`.
    @inline(__always)
    private func counts<T: BinaryInteger>(
        _ matches: RowBits, _ column: ContiguousArray<T>, size: Int, index: (T) -> Int = { Int($0) },
    ) throws -> [Int] {
        var counts = [Int](repeating: 0, count: max(size, 1))
        try counts.withUnsafeMutableBufferPointer { counts in
            try column.withUnsafeBufferPointer { column in
                try forEachRow(of: matches) { row in
                    let value = index(column[row])
                    if value >= 0, value < counts.count {
                        counts[value] += 1
                    }
                }
            }
        }
        return counts
    }

    /// Calls `body` with each row of `matches`, checking for cancellation as it goes.
    @inline(__always)
    private func forEachRow(of matches: RowBits, _ body: (Int) -> Void) throws {
        try matches.words.withUnsafeBufferPointer { words in
            for (index, word) in words.enumerated() {
                if index & 0xFFF == 0, Task.isCancelled {
                    throw CancellationError()
                }
                var remaining = word
                while remaining != 0 {
                    body(index << 6 | remaining.trailingZeroBitCount)
                    remaining &= remaining - 1
                }
            }
        }
    }

    /// Counts of named values, by name, and the photos without one last.
    private func named(_ counts: [Int], _ name: (Int) -> (String, LibraryQuery.Field)?) -> [FacetValue] {
        var values: [FacetValue] = []
        var unnamed = 0
        for (value, count) in counts.enumerated() where count > 0 {
            guard let (name, field) = name(value) else {
                unnamed += count
                continue
            }
            values.append(FacetValue(
                name: name, count: count, filter: .filter(LibraryQuery.Filter(field, .equal, [.text(name)])),
            ))
        }
        let sorted = values.map { (key: FinderOrder.key($0.name ?? ""), value: $0) }.sorted { lhs, rhs in
            lhs.key == rhs.key
                ? (lhs.value.name ?? "") < (rhs.value.name ?? "") : lhs.key.lexicographicallyPrecedes(rhs.key)
        }.map(\.value)
        return sorted + (unnamed > 0 ? [FacetValue(name: nil, count: unnamed, filter: nil)] : [])
    }

    /// Counts by code, each code's value writing its name and filter; codes without a value count
    /// together, last.
    private static func coded(_ counts: [Int], _ value: (Int) -> LibraryQuery.Value?) -> [FacetValue] {
        var values: [FacetValue] = []
        var others = 0
        for (code, count) in counts.enumerated() where count > 0 {
            guard let value = value(code), let field = field(of: value) else {
                others += count
                continue
            }
            values.append(FacetValue(
                name: value.text(for: field), count: count, filter: .filter(LibraryQuery.Filter(
                    field,
                    .equal,
                    [value],
                )),
            ))
        }
        return values + (others > 0 ? [FacetValue(name: nil, count: others, filter: nil)] : [])
    }

    private static func field(of value: LibraryQuery.Value) -> LibraryQuery.Field? {
        switch value {
        case .flag: .flag
        case .label: .label
        case .kind: .ext
        default: nil
        }
    }

    /// Counts by the year, the month or the day photos were taken, those without a capture time
    /// last. Days from 1800 to 2199 are counted in an array, others in a dictionary.
    private func dates(of matches: RowBits, by facet: Facet) throws -> FacetCounts {
        let firstDay = QueryCalendar.days(1800, 1, 1)
        var days = [Int](repeating: 0, count: QueryCalendar.days(2200, 1, 1) - firstDay)
        var others: [Int: Int] = [:]
        var undated = 0
        try captured.withUnsafeBufferPointer { captured in
            try days.withUnsafeMutableBufferPointer { days in
                try forEachRow(of: matches) { row in
                    let milliseconds = captured[row]
                    guard milliseconds != .min else {
                        undated += 1
                        return
                    }
                    let day = QueryCalendar.day(ofMilliseconds: milliseconds)
                    let slot = day - firstDay
                    if slot >= 0, slot < days.count {
                        days[slot] += 1
                    } else {
                        others[day, default: 0] += 1
                    }
                }
            }
        }
        var counts: [QueryDate: Int] = [:]
        func add(_ day: Int, _ count: Int) {
            let (year, month, date) = QueryCalendar.civil(day)
            let key: QueryDate = switch facet {
            case .year: .year(year)
            case .month: .month(year, month)
            default: .day(year, month, date)
            }
            counts[key, default: 0] += count
        }
        for (slot, count) in days.enumerated() where count > 0 {
            add(slot + firstDay, count)
        }
        for (day, count) in others {
            add(day, count)
        }
        var values = counts.keys.sorted { $0.interval(today: 0).lowerBound < $1.interval(today: 0).lowerBound }
            .map { date in
                FacetValue(
                    name: date.description, count: counts[date] ?? 0,
                    filter: .filter(LibraryQuery.Filter(.date, .equal, [.date(date)])),
                )
            }
        if undated > 0 {
            values.append(FacetValue(name: nil, count: undated, filter: nil))
        }
        return FacetCounts(facet: facet, values: values)
    }
}
