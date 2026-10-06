import Foundation

public extension BenchScenarios {
    /// Adds the groups' scenario (LIB-41) after the others, at `photos` synthetic photos.
    static func registerGroups(photos: Int = GroupScenario.defaultPhotos) {
        register(GroupScenario(photos: photos))
    }
}

/// Moments and grouping (LIB-41) at a million synthetic photos held in memory, as the column store and
/// the index's names hold them: sessions of known cadences (events every few seconds, some from two
/// bodies at once; walks every few minutes; sports in bursts), with pauses between them that always
/// start a moment and none within them that does. All Photographs' moments must be the generator's
/// sessions, each starting at its session's first photo, its moments by camera and its days the
/// generator's, its moments without a pick those of the sessions without one, looser never finding more
/// moments than tighter, and a card of its first photos grouped as the index groups them. Each Group By
/// key, the moments without a pick and the summary are timed off the main thread against LIB-28's
/// budget of a second, their medians held to it and their slowest reported beside them. Nothing is read
/// from the fixture, so its volume doesn't matter.
public struct GroupScenario: BenchScenario {
    public static let defaultPhotos = 1_000_000
    static let budget = 1000.0
    static let runs = 5
    /// The photos the card is made of.
    static let cardPhotos = 20000

    public let name = "groups"
    public let photos: Int

    public init(photos: Int = GroupScenario.defaultPhotos) {
        self.photos = max(photos, 1000)
    }

    public func run(_ context: BenchContext) async throws -> [BenchResult] {
        try await measure(seed: context.manifest.spec.seed)
    }

    public func measure(seed: UInt64 = 1) async throws -> [BenchResult] {
        let library = SyntheticSessionLibrary(photos: photos, seed: seed)
        let store = library.store()
        let grouping = await Task.detached(priority: .userInitiated) {
            LibraryGrouping(
                store: store, names: library.names(),
                stacks: StackFinder.find(in: store, names: library.stackNames(), choices: StackChoices()),
                orientations: library.orientations(),
            )
        }.value
        let list = PhotoList(source: .allPhotographs, sort: QuerySort(), ids: store.ids(sortedBy: QuerySort()))
        let measured = try await Task.detached(priority: .userInitiated) {
            try Self.measure(grouping, list: list, library: library)
        }.value

        let size = BenchResult.grouped(photos)
        var results: [BenchResult] = []
        for key in GroupKey.allCases {
            results += timed(
                measured.timings[key] ?? ListScenario.Timings(), id: "library-groups-\(key.rawValue)",
                name: "\(size) photos grouped by \(key.rawValue), off the main thread", budget: .below(
                    Self.budget,
                    "ms",
                ),
            )
        }
        results += timed(
            measured.coverage, id: "library-groups-coverage", name: "The moments without a pick among \(size) photos",
            budget: .below(Self.budget, "ms"),
        )
        results += timed(
            measured.summary, id: "library-groups-summary", name: "The summary of \(size) photos",
            budget: .below(Self.budget, "ms"),
        )
        results += timed(
            measured.card, id: "library-groups-card",
            name: "A card of \(BenchResult.grouped(measured.cardPhotos)) photos in moments, before copying",
            budget: .below(Self.budget, "ms"),
        )
        let expected = library.expected
        for (id, label, value, wanted, unit) in [
            ("moments", "Moments found", measured.moments, expected.moments, "moments"),
            ("moment-starts", "Moments not starting at their session's first photo", measured.misplaced, 0, "moments"),
            ("moment-cameras", "Moments' groups by camera", measured.momentCameras, expected.momentCameras, "groups"),
            ("days", "Days", measured.days, expected.days, "days"),
            ("unpicked", "Moments without a pick", measured.unpicked, expected.unpicked, "moments"),
            ("pairs", "Raw and JPEG pairs in the summary", measured.pairs, expected.pairs, "pairs"),
            ("bursts", "Bursts in the summary", measured.bursts, expected.bursts, "bursts"),
            ("looser", "Steps looser finding more moments than the step before", measured.looser, 0, "steps"),
            ("card-mismatched", "A card's moments other than the index's", measured.cardMismatched, 0, "moments"),
        ] {
            results.append(BenchResult(
                scenario: name, id: "library-groups-\(id)", name: label, value: Double(value), unit: unit,
                budget: .exactly(Double(wanted), unit),
            ))
        }
        results.append(BenchResult(
            scenario: name, id: "library-groups-tightest", name: "Moments at the tightest step",
            value: Double(measured.steps.first ?? 0), unit: "moments",
        ))
        results.append(BenchResult(
            scenario: name, id: "library-groups-loosest", name: "Moments at the loosest step",
            value: Double(measured.steps.last ?? 0), unit: "moments",
        ))
        return results
    }

    /// What the scenario measures and counts.
    struct Measured: Sendable {
        var timings: [GroupKey: ListScenario.Timings] = [:]
        var coverage = ListScenario.Timings()
        var summary = ListScenario.Timings()
        var card = ListScenario.Timings()
        var cardPhotos = 0
        var moments = 0
        var misplaced = 0
        var momentCameras = 0
        var days = 0
        var unpicked = 0
        var pairs = 0
        var bursts = 0
        var looser = 0
        var steps: [Int] = []
        var cardMismatched = 0
    }

    private static func measure(
        _ grouping: LibraryGrouping, list: PhotoList, library: SyntheticSessionLibrary,
    ) throws -> Measured {
        let clock = ContinuousClock()
        var measured = Measured()
        var groups: [GroupKey: PhotoGroups] = [:]
        for key in GroupKey.allCases {
            var timings = ListScenario.Timings()
            for _ in 0 ..< runs {
                let started = clock.now
                groups[key] = grouping.groups(of: list, by: key)
                timings.add(clock.now - started)
            }
            measured.timings[key] = timings
        }
        let moments = groups[.moment] ?? grouping.moments(of: list)
        measured.moments = moments.count
        let starts = library.expected.starts
        measured.misplaced = max(moments.count, starts.count) - zip(moments, starts).count { moment, start in
            moment.photos.first == start || start < 0 && moment.value == .moment(nil)
        }
        measured.momentCameras = groups[.momentCamera]?.count ?? 0
        measured.days = groups[.day]?.count { $0.value != .day(nil) } ?? 0

        var coverage = MomentCoverage(moments)
        for _ in 0 ..< runs {
            let started = clock.now
            coverage = grouping.coverage(of: list)
            measured.coverage.add(clock.now - started)
        }
        measured.unpicked = coverage.unpicked.count
        var summary = try grouping.summary(of: list)
        for _ in 0 ..< runs {
            let started = clock.now
            summary = try grouping.summary(of: list)
            measured.summary.add(clock.now - started)
        }
        measured.pairs = summary.stacks[.pair] ?? 0
        measured.bursts = summary.stacks[.burst] ?? 0

        for looseness in MomentSetting.tightest ... MomentSetting.loosest {
            measured.steps.append(grouping.moments(of: list, setting: MomentSetting(looseness: looseness)).count)
        }
        measured.looser = zip(measured.steps, measured.steps.dropFirst()).count { $1 > $0 }

        let card = Array(list.ids.prefix(cardPhotos))
        let (captured, names) = library.card(card)
        var found: [CardMoment] = []
        for _ in 0 ..< runs {
            let started = clock.now
            found = MomentFinder.moments(captured: captured, names: names)
            measured.card.add(clock.now - started)
        }
        let indexed = grouping.moments(of: PhotoList(source: .allPhotographs, ids: ContiguousArray(card)))
        let fromCard = found.map { Set($0.places.map { card[$0] }) }
        measured.cardMismatched = max(fromCard.count, indexed.count)
            - zip(fromCard, indexed).count { $0 == Set($1.photos) }
        measured.cardPhotos = card.count
        return measured
    }

    /// A step's median, under `budget`, and its slowest, in milliseconds.
    private func timed(
        _ timings: ListScenario.Timings, id: String, name: String, budget: BenchBudget,
    ) -> [BenchResult] {
        [
            BenchResult(
                scenario: self.name, id: id, name: "\(name), median of \(timings.samples.count)",
                value: ListScenario.milliseconds(timings.median), unit: "ms", budget: budget,
            ),
            BenchResult(
                scenario: self.name, id: id + "-slowest", name: "\(name), slowest",
                value: ListScenario.milliseconds(timings.slowest), unit: "ms",
            ),
        ]
    }
}

/// Photos in sessions, from a seed, as the column store and the index's names hold them: a folder for
/// each session, from one or two of 25 cameras with 40 lenses. Two sessions in five are events, a
/// shot every 2 to 8 s from each body, a third of them from two bodies at once, with a burst of 3 to
/// 8 frames a tenth of a second apart in one shot in ten; two in five are walks of 30 to 150 shots
/// every 75 to 280 s, the longest less than four times the shortest; and one in five is sport, bursts
/// of 5 to 15 frames every 5 to 20 s. Sessions are 2 hours to 3 days apart, longer than any pause
/// that might not start a moment. A fifth of the shots are a raw beside its JPEG, most photos are
/// landscape, photos are picked in four sessions in five, and every tenth session is followed by a
/// scan without a capture time, in a folder of its own, never picked.
struct SyntheticSessionLibrary: Sendable {
    struct Expected: Sendable {
        var moments = 0
        /// Each moment's first photo, -1 for the photos without a capture time.
        var starts: [Int64] = []
        var momentCameras = 0
        var days = 0
        var unpicked = 0
        var pairs = 0
        var bursts = 0
    }

    let photos: Int
    private(set) var rows: [ColumnStore.Row] = []
    private var sizes: [(width: Int, height: Int)] = []
    private var folders: [Int64: String] = [:]
    private(set) var expected = Expected()

    init(photos: Int, seed: UInt64) {
        self.photos = photos
        var random = SeededRandom(seed: seed, stream: 41)
        rows.reserveCapacity(photos)
        sizes.reserveCapacity(photos)
        let scans = Int64(1_000_000)
        folders[scans] = "/Volumes/Photos/Scans"
        var time: Int64 = 1_600_000_000_000
        var days = Set<Int>()
        var session: Int64 = 0
        while rows.count < photos {
            session += 1
            let roll = random.int(below: 5)
            let camera = Int64(1 + random.int(below: 25))
            let second = roll < 2 && random.int(below: 3) == 0 ? Int64(1 + (camera + 1) % 25) : nil
            let lenses = (0 ..< 1 + random.int(below: 3)).map { _ in Int64(1 + random.int(below: 40)) }
            let picks = random.int(below: 5) > 0
            folders[session] = "/Volumes/Photos/\(2020 + session % 6)/Session \(session)"
            var shots: [Shot] = []
            switch roll {
            case 0, 1:
                for (body, model) in [(0, camera), (1, second)] {
                    guard let model else { continue }
                    var at = time + Int64(body) * 1500
                    for _ in 0 ..< random.int(in: 100 ... 1000) {
                        let frames = random.int(below: 10) == 0 ? random.int(in: 3 ... 8) : 1
                        shots.append(Shot(time: at, camera: model, body: body, frames: frames, step: 100))
                        at += Int64(frames) * 100 + Int64(random.int(in: 2000 ... 8000))
                    }
                }
            case 2, 3:
                var at = time
                for _ in 0 ..< random.int(in: 30 ... 150) {
                    shots.append(Shot(time: at, camera: camera, body: 0, frames: 1, step: 100))
                    at += Int64(random.int(in: 75000 ... 280_000))
                }
            default:
                var at = time
                for _ in 0 ..< random.int(in: 30 ... 300) {
                    let frames = random.int(in: 5 ... 15)
                    shots.append(Shot(time: at, camera: camera, body: 0, frames: frames, step: 100))
                    at += Int64(frames) * 100 + Int64(random.int(in: 5000 ... 20000))
                }
            }
            shots.sort { ($0.time, $0.body) < ($1.time, $1.body) }
            var first: Int64?
            var picked = false
            var cameras = Set<Int64>()
            var last = time
            var numbers = [0, 0]
            for shot in shots where rows.count < photos {
                let paired = random.int(below: 5) == 0
                let shutter = [1.0 / 2000, 1.0 / 500, 1.0 / 125][random.int(below: 3)]
                let lens = lenses[random.int(below: lenses.count)]
                let turned = random.int(below: 100)
                let size = turned < 70 ? (6000, 4000) : turned < 95 ? (4000, 6000) : (4000, 4000)
                var added = 0
                for frame in 0 ..< shot.frames where rows.count < photos {
                    numbers[shot.body] += 1
                    let base = (shot.body == 0 ? "A_" : "B_") + String(1_000_000 + numbers[shot.body]).dropFirst()
                    let at = shot.time + Int64(frame) * shot.step
                    let pick = picks && (random.int(below: 20) == 0 || !picked && frame == 0 && shot.frames == 1
                        && random.int(below: 4) == 0)
                    let id = add(
                        base + ".ARW", folder: session, at: at, camera: shot.camera, lens: lens, shutter: shutter,
                        pick: pick, size: size, iso: Double(100 << random.int(below: 6)),
                    )
                    first = first ?? id
                    picked = picked || pick
                    added += 1
                    days.insert(QueryCalendar.day(ofMilliseconds: at))
                    last = max(last, at)
                    if paired, rows.count < photos {
                        add(
                            base + ".JPG", folder: session, at: at, camera: shot.camera, lens: lens, shutter: shutter,
                            pick: false, size: size, iso: 100,
                        )
                        expected.pairs += 1
                    }
                }
                if added > 1 {
                    expected.bursts += 1
                }
                if added > 0 {
                    cameras.insert(shot.camera)
                }
            }
            if let first {
                expected.moments += 1
                expected.starts.append(first)
                expected.momentCameras += cameras.count
                expected.unpicked += picked ? 0 : 1
            }
            if rows.count < photos, session % 10 == 0 {
                add(
                    "SCAN_\(rows.count).TIF", folder: scans, at: nil, camera: nil, lens: nil, shutter: nil, pick: false,
                    size: (3000, 2000), iso: nil,
                )
            }
            time = last + Int64(random.int(in: 7_200_000 ... 259_200_000))
        }
        if rows.contains(where: { $0.hot.captured == nil }) {
            expected.moments += 1
            expected.starts.append(-1)
            expected.momentCameras += 1
            expected.unpicked += 1
        }
        expected.days = days.count
    }

    /// One press of the shutter: a frame, or a burst of `frames`, `step` milliseconds apart.
    private struct Shot {
        var time: Int64
        var camera: Int64
        var body: Int
        var frames: Int
        var step: Int64
    }

    @discardableResult
    private mutating func add(
        _ name: String, folder: Int64, at milliseconds: Int64?, camera: Int64?, lens: Int64?, shutter: Double?,
        pick: Bool, size: (Int, Int), iso: Double?,
    ) -> Int64 {
        let id = Int64(rows.count + 1)
        rows.append(ColumnStore.Row(
            HotColumns(
                id: id, folder: folder, captured: milliseconds.map { Double($0) / 1000 }, camera: camera, lens: lens,
                rating: 0, flag: pick ? PhotoRecord.code(for: .pick) : 0, label: 0, marked: false, edited: false,
                iso: iso, aperture: 4, focal: 50,
                kind: PhotoRecord.Kind(pathExtension: (name as NSString).pathExtension).rawValue, name: name,
            ),
            shutter: shutter, width: size.0, height: size.1,
        ))
        sizes.append(size)
        return id
    }

    func store() -> ColumnStore {
        ColumnStore(rows: rows)
    }

    func names() -> QueryNames {
        var cameras: [Int64: String] = [:]
        for camera in 1 ... 25 {
            cameras[Int64(camera)] = "Camera \(camera)"
        }
        var lenses: [Int64: String] = [:]
        for lens in 1 ... 40 {
            lenses[Int64(lens)] = "Lens \(lens)"
        }
        return QueryNames(folders: folders, cameras: cameras, lenses: lenses)
    }

    func stackNames() -> StackNames {
        var names = StackNames()
        names.reserveCapacity(rows.count + 1)
        for row in rows {
            names[row.hot.id] = row.hot.name
        }
        return names
    }

    func orientations() -> PhotoOrientations {
        var orientations = PhotoOrientations()
        for (place, size) in sizes.enumerated().reversed() {
            orientations[Int64(place + 1)] = PhotoOrientation(width: size.width, height: size.height)
        }
        return orientations
    }

    /// Photos `ids` as a card holds them before they're copied: their capture times and names.
    func card(_ ids: [Int64]) -> (captured: [Date?], names: [String]) {
        (
            ids.map { id in rows[Int(id) - 1].hot.captured.map(Date.init(timeIntervalSince1970:)) },
            ids.map { rows[Int($0) - 1].hot.name },
        )
    }
}
