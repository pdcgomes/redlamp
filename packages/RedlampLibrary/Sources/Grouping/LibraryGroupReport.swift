import Foundation

/// Groups as `redlamp library groups` prints them (LIB-41): the photos a query finds, or a
/// collection's, grouped by a key, each group with its count, picks and filter; the moments without a
/// pick; and the photos' summary, as lines of text or as JSON.
public struct LibraryGroupReport: Sendable {
    public let query: LibraryQuery
    /// The collection, set or smart collection grouped; nil for the whole library.
    public let collection: CollectionPath?
    public let sort: QuerySort
    public let groups: PhotoGroups
    /// The list's moments, for the moments without a pick.
    public let moments: PhotoGroups
    public let coverage: MomentCoverage
    public let summary: SourceSummary
    /// How long grouping took, finding the moments for their coverage, and the summary.
    public let grouped: Duration
    public let covered: Duration
    public let summarised: Duration
    /// How long the column store took to build, and the stacks to be found.
    public let loaded: Duration
    public let stacked: Duration

    /// Groups the photos `query` finds in `index`, or those of `collection` it finds, in `sort`'s order,
    /// by `key`, moments as `setting` finds them, the query's `is:unpicked-moment` too.
    public static func run(
        _ query: LibraryQuery, in collection: CollectionPath? = nil, by key: GroupKey = .moment,
        setting: MomentSetting = MomentSetting(), sort: QuerySort = QuerySort(), index: LibraryIndex,
    ) async throws -> LibraryGroupReport {
        let engine = QueryEngine(index: index)
        let clock = ContinuousClock()
        var started = clock.now
        try await engine.load()
        let loaded = clock.now - started
        let source = collection.map(PhotoSource.collection) ?? .allPhotographs
        let list = try await engine.list(source, matching: query, sort: sort, moments: setting)
        started = clock.now
        let stacks = try await StackFinder.find(in: index, store: engine.store ?? ColumnStore())
        let stacked = clock.now - started
        let grouping = try await engine.grouping(stacks: stacks)
        started = clock.now
        let groups = grouping.groups(of: list, by: key, setting: setting)
        let grouped = clock.now - started
        started = clock.now
        let moments = key == .moment ? groups : grouping.moments(of: list, setting: setting)
        let coverage = MomentCoverage(moments)
        let covered = clock.now - started
        started = clock.now
        let summary = try grouping.summary(of: list)
        let summarised = clock.now - started
        return LibraryGroupReport(
            query: query, collection: collection, sort: sort, groups: groups, moments: moments, coverage: coverage,
            summary: summary, grouped: grouped, covered: covered, summarised: summarised, loaded: loaded,
            stacked: stacked,
        )
    }

    /// Each group with its counts and filter; the moments without a pick; the summary; then what was
    /// grouped, how, and how long it took.
    public func lines() -> [String] {
        var lines = groups.map { group in
            "\(group.name): \(Self.counted(group.count, "photo")), \(Self.counted(group.picks, "pick"))"
                + (group.filter.map { " (\($0))" } ?? "")
        }
        let unpicked = coverage.unpicked.map { moments[$0] }
        lines.append(unpicked.isEmpty
            ? coverage.moments == 0 ? "No moments." : "Every moment has a pick."
            : "Moments without a pick: \(Self.grouped(unpicked.count)) of \(Self.grouped(coverage.moments)), "
            + Self.counted(coverage.photos.count, "photo"))
        lines += unpicked.map { "  \($0.name): \(Self.counted($0.count, "photo"))" }
        lines += summaryLines
        let setting = groups.setting
        lines.append(
            "\(Self.counted(groups.count, "group")) by \(groups.key.rawValue) of \(Self.counted(groups.list.count, "photo"))"
                + " for \(query.description.isEmpty ? "everything" : query.description)"
                + (collection.map { " in “\($0.displayName)”" } ?? "")
                + ", sorted by \(sort.key.rawValue)\(sort.ascending ? "" : ", descending"); a moment at a pause over "
                + "\(Self.number(setting.floor)) s and \(Self.number(setting.multiple)) times the pace around it "
                + "(looseness \(setting.looseness)); in "
                + String(
                    format: "%.1f ms (moments for their picks in %.1f ms, summary in %.1f ms; column store built in "
                        + "%.0f ms, stacks found in %.0f ms)",
                    Self.milliseconds(grouped), Self.milliseconds(covered), Self.milliseconds(summarised),
                    Self.milliseconds(loaded), Self.milliseconds(stacked),
                ),
        )
        return lines
    }

    private var summaryLines: [String] {
        var days = "no capture times"
        if let first = summary.firstDay, let last = summary.lastDay {
            days = summary.days == 1 ? "on \(Self.name(of: first))"
                : "over \(Self.counted(summary.days, "day")) from \(Self.name(of: first)) to \(Self.name(of: last))"
        }
        var lines = [
            "Summary: \(Self.counted(summary.photos, "photo")), \(Self.counted(summary.picks, "pick")), \(days)"
                + (summary.undated > 0 && summary.firstDay != nil
                    ? ", \(Self.grouped(summary.undated)) without a capture time" : ""),
        ]
        for (title, values, none) in [("Cameras", summary.cameras, "no camera"), ("Lenses", summary.lenses, "no lens")]
            where !values.isEmpty {
            lines.append("  \(title): " + values.map { "\($0.name ?? none) (\(Self.grouped($0.count)))" }
                .joined(separator: ", "))
        }
        let ranges = [
            summary.iso.map { "ISO " + Self.range($0) { Self.number($0) } },
            summary.shutter.map { Self.range($0) { LibraryQuery.Value.format($0, for: .shutter) + " s" } },
            summary.aperture.map { Self.range($0) { "f/" + LibraryQuery.Value.format($0, for: .aperture) } },
        ].compactMap(\.self)
        if !ranges.isEmpty {
            lines.append("  " + ranges.joined(separator: ", "))
        }
        let stacks = [
            (Stack.Kind.pair, "raw and JPEG pair"), (.burst, "burst"), (.manual, "manual stack"),
            (.focus, "focus-stack suggestion"),
        ].compactMap { kind, name in summary.stacks[kind].map { Self.counted($0, name) } }
        lines.append("  Stacks: " + (stacks.isEmpty ? "none" : stacks.joined(separator: ", ")))
        return lines
    }

    public func json() throws -> Data {
        struct Group: Encodable {
            let name: String
            let count: Int
            let picks: Int
            let filter: String?
            /// The first and last capture times, by the camera's clock.
            let first: String?
            let last: String?
        }
        struct Named: Encodable {
            let name: String?
            let count: Int
            let filter: String?
        }
        struct Limits: Encodable {
            let lowest: Double
            let highest: Double
        }
        struct Summary: Encodable {
            let photos: Int
            let picks: Int
            let firstDay: String?
            let lastDay: String?
            let days: Int
            let undated: Int
            let cameras: [Named]
            let lenses: [Named]
            let iso: Limits?
            let shutter: Limits?
            let aperture: Limits?
            let stacks: [String: Int]
        }
        struct Coverage: Encodable {
            let moments: Int
            let photos: Int
            let unpicked: [Group]
        }
        struct Setting: Encodable {
            let looseness: Int
            let floorSeconds: Double
            let multiple: Double
            let ceilingSeconds: Double
        }
        struct Output: Encodable {
            let query: String
            let collection: String?
            let sort: String
            let ascending: Bool
            let by: String
            let setting: Setting
            let photos: Int
            let groups: [Group]
            let momentsWithoutPick: Coverage
            let summary: Summary
            let milliseconds: Double
            let coverageMilliseconds: Double
            let summaryMilliseconds: Double
            let loadMilliseconds: Double
            let stacksMilliseconds: Double
        }
        func group(_ groups: PhotoGroups, _ index: Int) -> Group {
            let group = groups[index]
            let span = groups.details[index].span
            return Group(
                name: group.name, count: group.count, picks: group.picks, filter: group.filter?.description,
                first: span.map { GroupNames.timestamp($0.lowerBound) },
                last: span.map { GroupNames.timestamp($0.upperBound) },
            )
        }
        let named = { (values: [FacetValue]) in
            values.map { Named(name: $0.name, count: $0.count, filter: $0.filter?.description) }
        }
        let limits = { (range: ClosedRange<Double>?) in
            range.map { Limits(lowest: $0.lowerBound, highest: $0.upperBound) }
        }
        let setting = groups.setting
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(Output(
            query: query.description, collection: collection?.text, sort: sort.key.rawValue, ascending: sort.ascending,
            by: groups.key.rawValue,
            setting: Setting(
                looseness: setting.looseness, floorSeconds: setting.floor, multiple: setting.multiple,
                ceilingSeconds: setting.ceiling,
            ),
            photos: groups.list.count, groups: groups.indices.map { group(groups, $0) },
            momentsWithoutPick: Coverage(
                moments: coverage.moments, photos: coverage.photos.count,
                unpicked: coverage.unpicked.map { group(moments, $0) },
            ),
            summary: Summary(
                photos: summary.photos, picks: summary.picks, firstDay: summary.firstDay?.description,
                lastDay: summary.lastDay?.description, days: summary.days, undated: summary.undated,
                cameras: named(summary.cameras), lenses: named(summary.lenses), iso: limits(summary.iso),
                shutter: limits(summary.shutter), aperture: limits(summary.aperture),
                stacks: Dictionary(uniqueKeysWithValues: summary.stacks.map { ($0.key.rawValue, $0.value) }),
            ),
            milliseconds: Self.milliseconds(grouped), coverageMilliseconds: Self.milliseconds(covered),
            summaryMilliseconds: Self.milliseconds(summarised), loadMilliseconds: Self.milliseconds(loaded),
            stacksMilliseconds: Self.milliseconds(stacked),
        ))
    }

    /// `14 June 2025`.
    private static func name(of date: QueryDate) -> String {
        guard case let .day(year, month, day) = date else { return date.description }
        return GroupNames.day(QueryCalendar.days(year, month, day))
    }

    /// `1 photo`, `20,000 photos`, `no picks`.
    private static func counted(_ count: Int, _ noun: String) -> String {
        count == 0 ? "no \(noun)s" : count == 1 ? "1 \(noun)" : "\(grouped(count)) \(noun)s"
    }

    /// `low to high`, or one of them when they're the same.
    private static func range(_ range: ClosedRange<Double>, _ text: (Double) -> String) -> String {
        range.lowerBound == range.upperBound ? text(range.lowerBound)
            : "\(text(range.lowerBound)) to \(text(range.upperBound))"
    }

    /// Whole numbers without a point, others to a tenth.
    private static func number(_ number: Double) -> String {
        number == number.rounded() ? String(Int(number)) : String(format: "%.1f", number)
    }

    /// `20,000`, whatever the locale.
    private static func grouped(_ value: Int) -> String {
        value.formatted(.number.locale(Locale(identifier: "en_US")))
    }

    private static func milliseconds(_ duration: Duration) -> Double {
        duration / .milliseconds(1)
    }
}
