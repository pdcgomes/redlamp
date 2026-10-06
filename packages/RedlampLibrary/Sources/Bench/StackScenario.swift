import Foundation

public extension BenchScenarios {
    /// Adds the stacks' scenario (LIB-28) after the others, at `photos` synthetic photos.
    static func registerStacks(photos: Int = StackScenario.defaultPhotos) {
        register(StackScenario(photos: photos))
    }
}

/// Stacks (LIB-28) at a million synthetic photos held in memory, as the column store and the index's
/// names hold them: shoots of photos alone, bursts and focus brackets in folders of 50 to 2,000, a
/// fifth of the shots a raw beside its JPEG, and manual stacks across folders. Every stack is found
/// off the main thread, within the design's budget of a second, and the stacks found must be the
/// generator's. Then All Photographs, in capture order, is shown with its stacks closed and with
/// them all open (under 50 ms each), and single stacks are opened and closed as the main thread
/// does (under 2 ms each); every diff checked turns the cells before into those after. Each step's
/// median is held to its budget, and its slowest reported beside it, since the Macs this runs on are
/// often busy with other builds. Nothing is read from the fixture, so its volume doesn't matter.
public struct StackScenario: BenchScenario {
    public static let defaultPhotos = 1_000_000
    static let findBudget = 1000.0
    static let listBudget = 50.0
    /// Microseconds.
    static let stackBudget = 2000.0
    static let runs = 5
    /// Stacks opened and closed one at a time, and how many of their diffs are checked.
    static let singles = 400
    static let checked = 8

    public let name = "stacks"
    public let photos: Int

    public init(photos: Int = StackScenario.defaultPhotos) {
        self.photos = max(photos, 100)
    }

    public func run(_ context: BenchContext) async throws -> [BenchResult] {
        try await measure(seed: context.manifest.spec.seed)
    }

    public func measure(seed: UInt64 = 1) async throws -> [BenchResult] {
        let photos = photos
        let library = SyntheticStackLibrary(photos: photos, seed: seed)
        let store = library.store()
        let names = library.names()
        let clock = ContinuousClock()
        let (finding, stacks) = await Task.detached(priority: .userInitiated) {
            var timings = ListScenario.Timings()
            var stacks = Stacks()
            for _ in 0 ..< Self.runs {
                let started = clock.now
                stacks = StackFinder.find(in: store, names: names, choices: library.choices)
                timings.add(clock.now - started)
            }
            return (timings, stacks)
        }.value

        let size = BenchResult.grouped(photos)
        var results = timed(
            finding, id: "library-stacks-find", name: "Every stack of \(size) photos found, off the main thread",
            budget: .below(Self.findBudget, "ms"),
        )
        for (kind, expected, label) in [
            (Stack.Kind.pair, library.pairs, "Raw and JPEG pairs found"),
            (.burst, library.bursts, "Bursts found"), (.focus, library.brackets, "Focus suggestions found"),
            (.manual, library.manual, "Manual stacks found"),
        ] {
            results.append(BenchResult(
                scenario: name, id: "library-stacks-\(kind.rawValue)", name: label,
                value: Double(stacks.count(of: kind)), unit: "stacks", budget: .exactly(Double(expected), "stacks"),
            ))
        }
        results.append(BenchResult(
            scenario: name, id: "library-stacks-memory", name: "The stacks' memory, a photo",
            value: Double(stacks.memoryFootprint) / Double(photos), unit: "bytes",
        ))
        return results + listing(store: store, stacks: stacks)
    }

    /// Shows All Photographs with `stacks`, every stack closed, then open, then closed again; opens
    /// and closes single stacks; and selects across the cells.
    private func listing(store: ColumnStore, stacks: Stacks) -> [BenchResult] {
        let clock = ContinuousClock()
        let list = PhotoList(source: .allPhotographs, sort: QuerySort(), ids: store.ids(sortedBy: QuerySort()))
        var (closing, opening, reclosing) = (ListScenario.Timings(), ListScenario.Timings(), ListScenario.Timings())
        var made = ListScenario.Timings()
        var mismatched = 0
        var stacked = StackedList(list, stacks: stacks)
        var selection = StackSelection()
        for run in 0 ..< Self.runs {
            var started = clock.now
            let expanded = StackedList(list, stacks: stacks, open: true)
            made.add(clock.now - started)
            if run == 0 {
                mismatched += Self.mismatches(Array(expanded).sorted(), list.ids.sorted())
            }
            started = clock.now
            stacked = StackedList(list, stacks: stacks)
            closing.add(clock.now - started)
            let closed = run == 0 ? Array(stacked) : []
            started = clock.now
            let opened = stacked.openAll(selection: &selection)
            opening.add(clock.now - started)
            let open = run == 0 ? Array(stacked) : []
            if run == 0 {
                mismatched += Self.mismatches(Self.applying(opened, to: closed, from: stacked), open)
            }
            started = clock.now
            let reclosed = stacked.closeAll(selection: &selection)
            reclosing.add(clock.now - started)
            if run == 0 {
                mismatched += Self.mismatches(Self.applying(reclosed, to: open, from: stacked), closed)
            }
        }
        let cells = stacked.count

        var heads: [Int64] = []
        for cell in stacked where stacked.isStacked(cell) {
            heads.append(cell)
        }
        var random = SeededRandom(seed: 28)
        var (openingOne, closingOne) = (ListScenario.Timings(), ListScenario.Timings())
        for single in 0 ..< (heads.isEmpty ? 0 : Self.singles) {
            let cell = heads[random.int(below: heads.count)]
            let checking = single < Self.checked
            let before = checking ? Array(stacked) : []
            var started = clock.now
            let opened = stacked.open(cell, selection: &selection)
            openingOne.add(clock.now - started)
            let open = checking ? Array(stacked) : []
            if checking {
                mismatched += Self.mismatches(Self.applying(opened, to: before, from: stacked), open)
            }
            started = clock.now
            let closed = stacked.close(cell, selection: &selection)
            closingOne.add(clock.now - started)
            if checking {
                mismatched += Self.mismatches(Self.applying(closed, to: open, from: stacked), before)
            }
        }

        var (extending, all, listed) = (ListScenario.Timings(), ListScenario.Timings(), ListScenario.Timings())
        var photosSelected = 0
        for _ in 0 ..< Self.runs where cells > 3 {
            selection.select(stacked[cells / 4], in: stacked)
            var started = clock.now
            selection.extend(to: stacked[cells * 3 / 4], in: stacked)
            extending.add(clock.now - started)
            started = clock.now
            selection.selectAll(in: stacked)
            all.add(clock.now - started)
            started = clock.now
            photosSelected = selection.photos(in: stacked).count
            listed.add(clock.now - started)
        }

        let size = BenchResult.grouped(list.count)
        let half = BenchResult.grouped(cells * 3 / 4 - cells / 4 + 1)
        return timed(
            closing, id: "library-stacks-closed",
            name: "All Photographs of \(size) shown with its stacks closed (\(BenchResult.grouped(cells)) cells)",
            budget: .below(Self.listBudget, "ms"),
        )
            + timed(
                made, id: "library-stacks-open", name: "All Photographs of \(size) shown with its stacks open",
                budget: .below(Self.listBudget, "ms"),
            )
            + timed(
                opening, id: "library-stacks-open-all", name: "Every stack opened, with the diff",
                budget: .below(Self.listBudget, "ms"),
            )
            + timed(
                reclosing, id: "library-stacks-close-all", name: "Every stack closed, with the diff",
                budget: .below(Self.listBudget, "ms"),
            )
            + timed(
                openingOne, id: "library-stacks-open-one", name: "A stack opened, with the diff", inMicroseconds: true,
                budget: .below(Self.stackBudget, "µs"),
            )
            + timed(
                closingOne, id: "library-stacks-close-one", name: "A stack closed, with the diff", inMicroseconds: true,
                budget: .below(Self.stackBudget, "µs"),
            )
            + [BenchResult(
                scenario: name, id: "library-stacks-diff-mismatched", name: "Cells a diff didn't put in place",
                value: Double(mismatched), unit: "cells", budget: .exactly(0, "cells"),
            )]
            + timed(
                extending, id: "library-stacks-extend", name: "A selection extended across \(half) cells",
                inMicroseconds: true,
            )
            + timed(all, id: "library-stacks-select-all", name: "Every cell selected", inMicroseconds: true)
            + timed(
                listed, id: "library-stacks-selected-photos",
                name: "Every photo of the selection, \(BenchResult.grouped(photosSelected)), in order",
            )
    }

    /// Places where `cells` differs from `expected`, every one of them when their counts differ.
    private static func mismatches(_ cells: [Int64], _ expected: [Int64]) -> Int {
        cells.count == expected.count ? zip(cells, expected).count { $0 != $1 } : max(cells.count, expected.count)
    }

    /// `diff` applied to `cells`, the cells it inserts taken from `stacked`, the list after it.
    private static func applying(_ diff: PhotoListDiff, to cells: [Int64], from stacked: StackedList) -> [Int64] {
        var cells = cells
        diff.apply(to: &cells) { stacked[$0] }
        return cells
    }

    /// A step's median, under `budget`, and its slowest, in milliseconds or microseconds.
    private func timed(
        _ timings: ListScenario.Timings, id: String, name: String, inMicroseconds: Bool = false,
        budget: BenchBudget? = nil,
    ) -> [BenchResult] {
        let (unit, value) = inMicroseconds ? ("µs", ListScenario.microseconds) : ("ms", ListScenario.milliseconds)
        return [
            BenchResult(
                scenario: self.name, id: id, name: "\(name), median of \(timings.samples.count)",
                value: value(timings.median), unit: unit, budget: budget,
            ),
            BenchResult(
                scenario: self.name, id: id + "-slowest", name: "\(name), slowest", value: value(timings.slowest),
                unit: unit,
            ),
        ]
    }
}

/// Photos in shoots, from a seed, as the column store and the index's names hold them: folders of 50
/// to 2,000 photos, each from one camera, of shots more than 30 s apart. Seven shots in ten are a
/// photo alone, a fifth are bursts of 2 to 12 frames a tenth of a second apart with ISO changing from
/// frame to frame, and the rest focus brackets of 4 to 15 frames 2 s apart with nothing changing; a
/// fifth of the shots are a raw beside its JPEG. A photo alone in one shoot in 400 joins a manual
/// stack with others from any folder.
struct SyntheticStackLibrary: Sendable {
    let photos: Int
    let seed: UInt64
    private(set) var rows: [ColumnStore.Row] = []
    private(set) var pairs = 0
    private(set) var bursts = 0
    private(set) var brackets = 0
    private(set) var manual = 0
    private(set) var choices = StackChoices()

    init(photos: Int, seed: UInt64) {
        self.photos = photos
        self.seed = seed
        var random = SeededRandom(seed: seed, stream: 28)
        rows.reserveCapacity(photos)
        var folder: Int64 = 0
        var alone: [Int64] = []
        while rows.count < photos {
            folder += 1
            let size = random.int(in: 50 ... 2000)
            let camera = Int64(1 + random.int(below: 25))
            var time = 1_300_000_000_000 + folder * 100_000_000
            var number = 0
            while number < size, rows.count < photos {
                let roll = random.int(below: 100)
                let paired = random.int(below: 5) == 0
                let frames = roll < 70 ? 1 : roll < 90 ? random.int(in: 2 ... 12) : random.int(in: 4 ... 15)
                let step: Int64 = roll < 90 ? 100 : 2000
                let shutter = [1.0 / 1000, 1.0 / 250, 1.0 / 60][random.int(below: 3)]
                let iso = Double(100 << random.int(below: 5))
                var shot: [Int64] = []
                for frame in 0 ..< frames where rows.count < photos {
                    number += 1
                    let base = "IMG_" + String(number + 100_000).dropFirst()
                    let captured = Double(time + Int64(frame) * step) / 1000
                    let frameISO = roll >= 70 && roll < 90 ? iso * Double(1 + frame % 3) : iso
                    let id = add(base + ".ARW", folder, captured, camera, frameISO, shutter)
                    shot.append(id)
                    if paired, rows.count < photos {
                        add(base + ".JPG", folder, captured, camera, frameISO, shutter)
                        pairs += 1
                    }
                }
                if roll >= 70, shot.count > 1, roll < 90 || shot.count >= 3 {
                    if roll < 90 {
                        bursts += 1
                    } else {
                        brackets += 1
                    }
                } else if shot.count == 1, random.int(below: 400) == 0 {
                    alone.append(shot[0])
                }
                time += Int64(frames) * step + 31000 + Int64(random.int(below: 300_000))
            }
        }
        var chosen: [Int64: StackChoices.Choice] = [:]
        var start = 0
        while start + 1 < alone.count {
            let count = min(2 + random.int(below: 3), alone.count - start)
            var choice = StackChoices.Choice(id: UUID(), top: true)
            for photo in alone[start ..< start + count] {
                chosen[photo] = choice
                choice.top = false
            }
            manual += 1
            start += count
        }
        choices = StackChoices(chosen)
    }

    @discardableResult
    private mutating func add(
        _ name: String, _ folder: Int64, _ captured: Double, _ camera: Int64, _ iso: Double, _ shutter: Double,
    ) -> Int64 {
        let id = Int64(rows.count + 1)
        rows.append(ColumnStore.Row(HotColumns(
            id: id, folder: folder, captured: captured, camera: camera, lens: camera, rating: 0, flag: 0, label: 0,
            marked: false, edited: false, iso: iso, aperture: 4, focal: 50,
            kind: PhotoRecord.Kind(pathExtension: (name as NSString).pathExtension).rawValue, name: name,
        ), shutter: shutter))
        return id
    }

    func store() -> ColumnStore {
        ColumnStore(rows: rows)
    }

    func names() -> StackNames {
        var names = StackNames()
        names.reserveCapacity(rows.count + 1)
        for row in rows {
            names[row.hot.id] = row.hot.name
        }
        return names
    }
}
