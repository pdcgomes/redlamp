import Foundation
import RedlampDocument
import RedlampEngineAPI

public extension BenchScenarios {
    /// Adds the scenario of metadata shared with other apps (LIB-24) after the others: `writes` `.xmp`
    /// sidecars written, and a library of `photos` synced.
    static func registerXMP(writes: Int = XMPScenario.defaultWrites, photos: Int = XMPScenario.defaultPhotos) {
        register(XMPScenario(writes: writes, photos: photos))
    }
}

/// Reads, merges and writes other apps' XMP (LIB-24). The fixture is indexed (once, kept for the next
/// runs as search's index is) and every photo synced in a dry run, twice: each `.xmp` and `.redlamp`
/// read and merged, nothing written to the fixture. In a temporary folder, `photos` photos with a
/// `.redlamp` each and another app's `.xmp` beside a third of them are synced with writing on, again
/// with nothing changed, and once more after another app changed a tenth of the `.xmp`. Then `writes`
/// `.xmp` sidecars are written one at a time, each timed: half new, half another app's rewritten with
/// its fields kept. There are no budgets yet beyond the fixture's counts.
public struct XMPScenario: BenchScenario {
    public static let defaultWrites = 10000
    public static let defaultPhotos = 2000

    public let name = "xmp"
    public let writes: Int
    public let photos: Int
    let indexFolder: URL?

    public init(writes: Int = XMPScenario.defaultWrites, photos: Int = XMPScenario.defaultPhotos) {
        self.init(writes: writes, photos: photos, indexFolder: nil)
    }

    /// Keeps the fixture's index in `indexFolder` rather than in the temporary folder.
    init(writes: Int, photos: Int, indexFolder: URL?) {
        self.writes = max(writes, 2)
        self.photos = max(photos, 10)
        self.indexFolder = indexFolder
    }

    public func run(_ context: BenchContext) async throws -> [BenchResult] {
        try await merging(context) + syncing(photos: photos) + Self.writing(writes)
    }

    /// The fixture's photos synced in a dry run, twice.
    private func merging(_ context: BenchContext) async throws -> [BenchResult] {
        let url = (indexFolder ?? QueryScenario.indexFolder(for: context)).appending(path: "Index.sqlite")
        let index = try await LibraryIndex.open(at: url)
        if try await index.read({ try $0.photoCount() }) != context.manifest.totals.photos {
            for await _ in LibraryIndexer(index: index).index([context.fixture]) {}
        }
        let ids = try await index.read { reader in
            var ids: [Int64] = []
            try reader.scanHotColumns { ids.append($0.id) }
            return ids
        }
        let xmp = LibraryXMP(index: index)
        let clock = ContinuousClock()
        let started = clock.now
        let report = try await xmp.sync(ids, writing: false, dryRun: true)
        let first = clock.now - started
        let again = clock.now
        _ = try await xmp.sync(ids, writing: false, dryRun: true)
        let second = clock.now - again
        await index.close()

        let size = BenchResult.grouped(ids.count)
        let totals = context.manifest.totals
        return [
            BenchResult(
                scenario: name, id: "library-xmp-merge", name: "The fixture's \(size) photos' XMP read and merged",
                value: first.seconds * 1000, unit: "ms",
            ),
            BenchResult(
                scenario: name, id: "library-xmp-merge-again", name: "The same again", value: second.seconds * 1000,
                unit: "ms",
            ),
            BenchResult(
                scenario: name, id: "library-xmp-merge-rate", name: "Photos merged a second",
                value: Double(ids.count) / max(min(first, second).seconds, 1e-9), unit: "photos/s",
            ),
            BenchResult(
                scenario: name, id: "library-xmp-other-apps", name: "Photos with other apps' .xmp",
                value: Double(report.photos.count { $0.sidecar != nil }), unit: "photos",
                budget: .exactly(Double(totals.xmpSidecars), "photos"),
            ),
            BenchResult(
                scenario: name, id: "library-xmp-sidecars", name: "Photos with a .redlamp",
                value: Double(report.photos.count { $0.redlamp != nil }), unit: "photos",
                budget: .exactly(Double(totals.sidecars), "photos"),
            ),
        ]
    }

    /// A library of `photos` synced with writing on, then with nothing changed, then after another
    /// app changed a tenth of the `.xmp`.
    private func syncing(photos: Int) async throws -> [BenchResult] {
        let folder = FileManager.default.temporaryDirectory
            .appending(path: "redlamp-bench-xmp-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: folder) }
        let root = folder.appending(path: "Photos", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let store = SidecarStore()
        var others: [URL] = []
        for number in 0 ..< photos {
            let photo = root.appending(path: String(format: "IMG_%05d.ARW", number))
            try Data("photo \(number)".utf8).write(to: photo)
            let metadata = PhotoMetadata(
                rating: number % 6, flag: number % 7 == 0 ? .pick : nil,
                label: number % 4 == 0 ? ColorLabel.allCases[number % 5] : nil,
            )
            try store.save(Sidecar(recipe: EditRecipe(), metadata: metadata), for: photo)
            if number % 3 == 0 {
                let other = root.appending(path: String(format: "IMG_%05d.xmp", number))
                try Data(Self.otherApp(rating: (number + 2) % 6, label: "Red").utf8).write(to: other)
                others.append(other)
            }
        }
        let index = try await LibraryIndex.open(at: folder.appending(path: "Library/Index.sqlite"))
        for await _ in LibraryIndexer(index: index).index([root]) {}
        let ids = try await index.read { reader in
            var ids: [Int64] = []
            try reader.scanHotColumns { ids.append($0.id) }
            return ids
        }
        let xmp = LibraryXMP(index: index)
        let clock = ContinuousClock()
        var started = clock.now
        let written = try await xmp.sync(ids, writing: true)
        let writing = clock.now - started
        started = clock.now
        let unchanged = try await xmp.sync(ids, writing: true)
        let again = clock.now - started
        let later = Date(timeIntervalSinceNow: 60)
        for other in others.enumerated().filter({ $0.offset % 10 == 0 }).map(\.element) {
            try Data(Self.otherApp(rating: -1, label: "Approved").utf8).write(to: other)
            try FileManager.default.setAttributes([.modificationDate: later], ofItemAtPath: other.path)
        }
        started = clock.now
        let changed = try await xmp.sync(ids, writing: true)
        let taking = clock.now - started
        await index.close()

        let size = BenchResult.grouped(photos)
        return [
            BenchResult(
                scenario: name, id: "library-xmp-sync-write",
                name: "\(size) photos synced, their .xmp written: \(BenchResult.grouped(written.xmpWritten.count))",
                value: writing.seconds * 1000, unit: "ms",
            ),
            BenchResult(
                scenario: name, id: "library-xmp-sync-unchanged", name: "\(size) photos synced again, nothing changed",
                value: again.seconds * 1000, unit: "ms",
            ),
            BenchResult(
                scenario: name, id: "library-xmp-sync-unchanged-photos", name: "Photos found unchanged",
                value: Double(unchanged.photos.count(where: \.unchanged)), unit: "photos",
                budget: .exactly(Double(photos), "photos"),
            ),
            BenchResult(
                scenario: name, id: "library-xmp-sync-take",
                name: "\(size) photos synced after another app changed \(BenchResult.grouped(changed.merged.count))",
                value: taking.seconds * 1000, unit: "ms",
            ),
            BenchResult(
                scenario: name, id: "library-xmp-sync-taken", name: "Photos that took the other app's changes",
                value: Double(changed.merged.count), unit: "photos",
                budget: .exactly(Double((others.count + 9) / 10), "photos"),
            ),
        ]
    }

    /// `count` `.xmp` sidecars written one at a time in a temporary folder: half new, half another
    /// app's rewritten keeping its fields; each write's time, from reading what's there to the rename.
    static func writing(_ count: Int) throws -> [BenchResult] {
        let folder = FileManager.default.temporaryDirectory
            .appending(path: "redlamp-bench-xmp-writes-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let targets = (0 ..< count).map { folder.appending(path: String(format: "IMG_%05d.xmp", $0)) }
        for (number, target) in targets.enumerated() where number % 2 == 1 {
            try Data(otherApp(rating: number % 6, label: "Green").utf8).write(to: target)
        }
        let conventions = XMPConventions()
        let clock = ContinuousClock()
        var times: [Duration] = []
        times.reserveCapacity(count)
        var failed = 0
        let started = clock.now
        for (number, target) in targets.enumerated() {
            let begun = clock.now
            let existing = try? [UInt8](Data(contentsOf: target))
            let packet = existing.flatMap { XMPPacket(bytes: $0) }
            let fields = XMPFields(
                rating: number % 5 + 1, flag: number % 9 == 0 ? .reject : nil, label: ColorLabel.allCases[number % 5],
            )
            let written: Set<XMPField> = [.rating, .flag, .label]
            let changes = fields.changes(written, to: packet, conventions: conventions, now: Date())
            guard let bytes = fields.written(into: packet, changes, fields: written, conventions: conventions),
                  (try? XMPSidecarWriter.write(bytes, to: target, replacing: existing)) != nil
            else {
                failed += 1
                continue
            }
            times.append(clock.now - begun)
        }
        let total = clock.now - started
        let size = BenchResult.grouped(count)
        return [
            BenchResult(
                scenario: "xmp", id: "library-xmp-write-p50",
                name: "\(size) .xmp written one at a time, half rewriting another app's: p50 a write",
                value: QueryScenario.percentile(times, 0.5), unit: "ms",
            ),
            BenchResult(
                scenario: "xmp", id: "library-xmp-write-p95", name: "p95 a write",
                value: QueryScenario.percentile(times, 0.95), unit: "ms",
            ),
            BenchResult(
                scenario: "xmp", id: "library-xmp-write-p99", name: "p99 a write",
                value: QueryScenario.percentile(times, 0.99), unit: "ms",
            ),
            BenchResult(
                scenario: "xmp", id: "library-xmp-write-rate", name: "Written a second",
                value: Double(times.count) / max(total.seconds, 1e-9), unit: "files/s",
            ),
            BenchResult(
                scenario: "xmp", id: "library-xmp-write-failed", name: ".xmp not written", value: Double(failed),
                unit: "files", budget: .exactly(0, "files"),
            ),
        ]
    }

    /// Another app's `.xmp`, as Lightroom Classic writes one, with develop settings Redlamp keeps.
    static func otherApp(rating: Int, label: String) -> String {
        """
        <x:xmpmeta xmlns:x="adobe:ns:meta/" x:xmptk="Adobe XMP Core 7.0-c000 1.000000, 0000/00/00-00:00:00        ">
         <rdf:RDF xmlns:rdf="http://www.w3.org/1999/02/22-rdf-syntax-ns#">
          <rdf:Description rdf:about=""
            xmlns:xmp="http://ns.adobe.com/xap/1.0/"
            xmlns:crs="http://ns.adobe.com/camera-raw-settings/1.0/"
            xmlns:dc="http://purl.org/dc/elements/1.1/"
           xmp:Rating="\(rating)"
           xmp:Label="\(label)"
           crs:Version="17.0"
           crs:Exposure2012="+0.35"
           crs:Contrast2012="+12">
           <dc:subject>
            <rdf:Bag>
             <rdf:li>Lisbon</rdf:li>
             <rdf:li>Tagus</rdf:li>
            </rdf:Bag>
           </dc:subject>
           <crs:ToneCurvePV2012>
            <rdf:Seq>
             <rdf:li>0, 0</rdf:li>
             <rdf:li>255, 255</rdf:li>
            </rdf:Seq>
           </crs:ToneCurvePV2012>
          </rdf:Description>
         </rdf:RDF>
        </x:xmpmeta>

        """
    }
}
