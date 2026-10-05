import Foundation
import RedlampDocument

/// What the photos a query finds can be counted by.
public enum Facet: String, Sendable, Hashable, CaseIterable {
    case camera, lens, rating, flag, label, year, month, folder, kind
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
                let matches = try await matches(
                    for: query.searchable, in: store, vocabulary: vocabulary, generation: generation,
                )
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
            let counts = try counts(matches, packed, size: 8) { Int(Packed.label($0)) }
            return FacetCounts(facet: facet, values: Self.coded(counts) { code in
                code > ColorLabel.allCases.count ? nil : .label(PhotoRecord.label(code: code))
            })
        case .kind:
            let counts = try counts(matches, kinds, size: 256)
            return FacetCounts(facet: facet, values: Self.coded(counts) { code in
                PhotoRecord.Kind(rawValue: code).flatMap { $0 == .other ? nil : .kind($0) }
            })
        case .year, .month:
            return try dates(of: matches, byMonth: facet == .month)
        }
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

    /// Counts by the year or the month photos were taken, those without a capture time last. Months
    /// from 1800 to 2199 are counted in an array, others in a dictionary.
    private func dates(of matches: RowBits, byMonth: Bool) throws -> FacetCounts {
        let firstMonth = 1800 * 12
        var months = [Int](repeating: 0, count: 400 * 12)
        var others: [Int: Int] = [:]
        var undated = 0
        var lastDay = Int.min
        var lastMonth = 0
        try captured.withUnsafeBufferPointer { captured in
            try months.withUnsafeMutableBufferPointer { months in
                try forEachRow(of: matches) { row in
                    let milliseconds = captured[row]
                    guard milliseconds != .min else {
                        undated += 1
                        return
                    }
                    let day = QueryCalendar.day(ofMilliseconds: milliseconds)
                    if day != lastDay {
                        let (year, month, _) = QueryCalendar.civil(day)
                        lastDay = day
                        lastMonth = year * 12 + month - 1
                    }
                    let slot = lastMonth - firstMonth
                    if slot >= 0, slot < months.count {
                        months[slot] += 1
                    } else {
                        others[lastMonth, default: 0] += 1
                    }
                }
            }
        }
        var counts = others
        for (slot, count) in months.enumerated() where count > 0 {
            counts[slot + firstMonth] = count
        }
        if !byMonth {
            counts = counts.reduce(into: [:]) { years, month in
                years[month.key >= 0 ? month.key / 12 : (month.key - 11) / 12, default: 0] += month.value
            }
        }
        var values = counts.keys.sorted().map { key in
            let date: QueryDate = byMonth ? .month(key / 12, key % 12 + 1) : .year(key)
            return FacetValue(
                name: date.description, count: counts[key] ?? 0,
                filter: .filter(LibraryQuery.Filter(.date, .equal, [.date(date)])),
            )
        }
        if undated > 0 {
            values.append(FacetValue(name: nil, count: undated, filter: nil))
        }
        return FacetCounts(facet: byMonth ? .month : .year, values: values)
    }
}
