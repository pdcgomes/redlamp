import Foundation
import RedlampDocument

/// A source's summary (LIB-41), from the column store: the days its photos were taken on, its cameras
/// and lenses, its ISO, aperture and shutter ranges, and its pairs and stacks as `StackFinder` found
/// them. Its picks' summary is Katami's list for the edit.
public struct SourceSummary: Sendable, Hashable {
    public let photos: Int
    public let picks: Int
    /// The first and the last day its photos were taken on, by the camera's clock as `date:` counts
    /// days, and how many days have photos.
    public let firstDay: QueryDate?
    public let lastDay: QueryDate?
    public let days: Int
    /// Photos without a capture time.
    public let undated: Int
    /// Its cameras and lenses as facets count them: by name in the Finder's order, the photos without
    /// one last. Cameras are models: the index doesn't tell two bodies of one model apart.
    public let cameras: [FacetValue]
    public let lenses: [FacetValue]
    /// The settings it spans, as the column store keeps them: whole ISO, f-numbers to a hundredth, and
    /// exposure lengths in seconds to the microsecond; nil when none of its photos has one.
    public let iso: ClosedRange<Double>?
    public let aperture: ClosedRange<Double>?
    public let shutter: ClosedRange<Double>?
    /// The stacks it has two or more photos of, by kind: raw and JPEG pairs by their photos, and
    /// bursts, manual stacks and focus-stack suggestions by their frames, a raw and its JPEG counting
    /// once.
    public let stacks: [Stack.Kind: Int]
}

public extension LibraryGrouping {
    /// `list`'s summary. Throws `CancellationError` when the task running it is cancelled partway.
    func summary(of list: PhotoList) throws -> SourceSummary {
        let rows = rows(of: list)
        var matches = RowBits(rows: store.rowCount)
        for row in rows where row >= 0 {
            matches.insert(Int(row))
        }
        let days = try store.counts(by: .day, of: matches, names: names).values
        let dated = days.filter { $0.name != nil }
        let cameras = try store.counts(by: .camera, of: matches, names: names).values
        let lenses = try store.counts(by: .lens, of: matches, names: names).values
        var (iso, aperture, shutter) = (Spread<UInt16>(), Spread<UInt16>(), Spread<UInt32>())
        var picks = 0
        let pick = UInt16(PhotoRecord.code(for: .pick))
        store.iso.withUnsafeBufferPointer { isoColumn in
            store.aperture.withUnsafeBufferPointer { apertureColumn in
                store.shutter.withUnsafeBufferPointer { shutterColumn in
                    store.packed.withUnsafeBufferPointer { packed in
                        for row in rows where row >= 0 {
                            iso.add(isoColumn[Int(row)])
                            aperture.add(apertureColumn[Int(row)])
                            shutter.add(shutterColumn[Int(row)])
                            if Packed.flag(packed[Int(row)]) == pick {
                                picks += 1
                            }
                        }
                    }
                }
            }
        }
        return SourceSummary(
            photos: list.count, picks: picks, firstDay: dated.first.flatMap(Self.date),
            lastDay: dated.last.flatMap(Self.date), days: dated.count,
            undated: (days.last { $0.name == nil }?.count ?? 0) + rows.count { $0 < 0 },
            cameras: cameras, lenses: lenses, iso: iso.range(scale: 1), aperture: aperture.range(scale: 100),
            shutter: shutter.range(scale: 1_000_000), stacks: stackCounts(in: list),
        )
    }
}

extension LibraryGrouping {
    /// The day a day facet's value finds.
    static func date(_ value: FacetValue) -> QueryDate? {
        guard case let .filter(filter)? = value.filter, case let .date(date)? = filter.values.first else { return nil }
        return date
    }

    /// The stacks of each kind `list` has two or more photos of: a pair's photos, or another stack's
    /// frames.
    func stackCounts(in list: PhotoList) -> [Stack.Kind: Int] {
        var counts: [Stack.Kind: Int] = [:]
        for stack in stacks.indices {
            let kind = stacks.kinds[stack]
            let shown = if kind == .pair {
                stacks.members(of: stack).count { list.contains($0) }
            } else {
                stacks.members(of: stack).count { top in
                    stacks.pairIndex(of: top).map { stacks.members(of: $0).contains { list.contains($0) } }
                        ?? list.contains(top)
                }
            }
            if shown > 1 {
                counts[kind, default: 0] += 1
            }
        }
        return counts
    }
}

/// The least and the most of a column's codes, 0 being none.
private struct Spread<Code: FixedWidthInteger & UnsignedInteger> {
    private var lowest = Code.max
    private var highest = Code.zero

    mutating func add(_ code: Code) {
        guard code != 0 else { return }
        lowest = min(lowest, code)
        highest = max(highest, code)
    }

    /// The codes as numbers, `scale` codes a unit.
    func range(scale: Double) -> ClosedRange<Double>? {
        highest == 0 ? nil : Double(lowest) / scale ... Double(highest) / scale
    }
}
