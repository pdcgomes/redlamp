import Foundation
import RedlampDocument
import RedlampEngineAPI

public extension BenchScenarios {
    /// Adds the file operations scenario (LIB-26) after the others.
    static func registerFiles(photos: Int = FilesScenario.defaultPhotos) {
        register(FilesScenario(photos: photos))
    }
}

/// Renames `photos` photos and undoes it, in a temporary folder on the Mac's own disk (LIB-26): a
/// fifth of them a raw beside its JPEG, half with a `.redlamp` sidecar and a tenth with another app's
/// `.xmp`, in folders of 500, with an index holding a row for each. The rename names every photo by
/// its capture time and a sequence, moving each with its sidecar and `.xmp`, and writes its
/// original name in its sidecar, which a photo without one gets; Undo takes the names and the
/// sidecars it made away again. Each is timed against a second (on the SSD, if its disk allows),
/// beside what one rename costs the disk on its own. Then, unless `recovery` is off, a rename is
/// stopped halfway as by a forced quit, and finished on the next run; and another rolled back. After
/// each, every photo must be where its row says, with its sidecar and its `.xmp`. Nothing is read from
/// the fixture, so its volume doesn't matter, and the folder is removed at the end.
public struct FilesScenario: BenchScenario {
    public static let defaultPhotos = 10000
    static let budget = 1000.0
    static let folderSize = 500

    public let name = "files"
    public let photos: Int
    public let recovery: Bool

    public init(photos: Int = FilesScenario.defaultPhotos, recovery: Bool = true) {
        self.photos = max(photos, 2)
        self.recovery = recovery
    }

    public func run(_: BenchContext) async throws -> [BenchResult] {
        try await measure()
    }

    /// A photo of the scenario: its path below the root, and what goes with it.
    struct Shot {
        var path: String
        var captured: Date
        var sidecar: Bool
        var xmp: Bool
    }

    public func measure(in parent: URL = FileManager.default.temporaryDirectory) async throws -> [BenchResult] {
        let folder = parent.appending(path: "redlamp-files-bench-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: folder) }
        let root = folder.appending(path: "Photos", directoryHint: .isDirectory)
        let paths = LibraryPaths(root: folder.appending(path: "Library", directoryHint: .isDirectory))
        let shots = Self.shots(photos)
        let (index, ids) = try await Self.write(shots, root: root, paths: paths)
        defer { index.closeAndWait() }
        let floor = try await LibraryIndex.offCaller { try Self.renameCost(root: root, shots: shots) }
        let template = try NamingTemplate(parsing: "{date:yyyyMMdd-HHmmss}-{sequence:5}")
        let clock = ContinuousClock()
        var checks = (lost: 0, apart: 0, rows: 0)
        func check() async throws {
            let found = try await Self.check(shots, ids: ids, index: index, root: root)
            checks.lost += found.lost
            checks.apart += found.apart
            checks.rows += found.rows == shots.count ? 0 : 1
        }

        let operations = FileOperations(index: index, paths: paths)
        var started = clock.now
        let preview = try await operations.renamePreview(template, photos: ids)
        let batch = try await operations.planRename(preview)
        let planned = clock.now - started
        started = clock.now
        let renamed = try await operations.run(batch)
        let renaming = clock.now - started
        try await check()
        started = clock.now
        let undone = try await operations.undo()
        let undoing = clock.now - started
        try await check()

        // Halfway through, as a forced quit would leave it; then partway through one photo's files.
        var recovered: (finishing: Duration, rollingBack: Duration, settled: Bool)?
        if recovery {
            let half = batch.steps.count / 2
            let interrupted = FileOperations(index: index, paths: paths)
            interrupted.interruption.withLock { $0 = .afterStep(half) }
            _ = try? await interrupted.run(interrupted.planRename(interrupted.renamePreview(template, photos: ids)))
            let launch = FileOperations(index: index, paths: paths)
            started = clock.now
            let finished = try await launch.recover(.finish)
            let finishing = clock.now - started
            try await check()
            try await launch.undo()
            try await check()
            let within = batch.steps.indices.dropFirst(half).first { batch.steps[$0].items.count > 1 } ?? half
            let stopped = FileOperations(index: index, paths: paths)
            stopped.interruption.withLock { $0 = .withinStep(within, items: 1) }
            _ = try? await stopped.run(stopped.planRename(stopped.renamePreview(template, photos: ids)))
            started = clock.now
            let rolledBack = try await FileOperations(index: index, paths: paths).recover(.rollBack)
            let rollingBack = clock.now - started
            try await check()
            recovered = (
                finishing, rollingBack, finished.first?.state == .finished && rolledBack.first?.state == .rolledBack,
            )
        }
        let settled = renamed.state == .finished && recovered?.settled != false

        let label = BenchResult.grouped(shots.count)
        let files = batch.steps.reduce(0) { $0 + $1.items.count }
        let recoveries = recovered.map { recovered in
            [
                BenchResult(
                    scenario: name, id: "library-files-recover-finish",
                    name: "A rename a forced quit stopped halfway, finished on the next run",
                    value: recovered.finishing.seconds * 1000, unit: "ms",
                ),
                BenchResult(
                    scenario: name, id: "library-files-recover-roll-back",
                    name: "A rename a forced quit stopped halfway, rolled back on the next run",
                    value: recovered.rollingBack.seconds * 1000, unit: "ms",
                ),
            ]
        } ?? []
        return [
            BenchResult(
                scenario: name, id: "library-files-rename-plan",
                name: "\(label) photos: the rename's preview and steps planned", value: planned.seconds * 1000,
                unit: "ms",
            ),
            BenchResult(
                scenario: name, id: "library-files-rename",
                name: "\(label) photos renamed, \(BenchResult.grouped(files)) files, original names recorded",
                value: renaming.seconds * 1000, unit: "ms", budget: .below(Self.budget, "ms"),
            ),
            BenchResult(
                scenario: name, id: "library-files-rename-names", name: "Of it, the original names written in sidecars",
                value: renamed.originalNamesTime.seconds * 1000, unit: "ms",
            ),
            BenchResult(
                scenario: name, id: "library-files-undo", name: "\(label) photos: the rename undone",
                value: undoing.seconds * 1000, unit: "ms", budget: .below(Self.budget, "ms"),
            ),
            BenchResult(
                scenario: name, id: "library-files-undo-names", name: "Of it, the original names taken out of sidecars",
                value: undone.originalNamesTime.seconds * 1000, unit: "ms",
            ),
            BenchResult(
                scenario: name, id: "library-files-rename-cost",
                name: "One rename on this disk, on its own (renamex_np, mean of 2,000)", value: floor * 1_000_000,
                unit: "µs",
            ),
            BenchResult(
                scenario: name, id: "library-files-original-names",
                name: "Original names written in sidecars by the rename",
                value: Double(renamed.originalNamesRecorded), unit: "photos",
            ),
        ] + recoveries + [
            BenchResult(
                scenario: name, id: "library-files-settled", name: "Batches that ended as asked",
                value: settled ? 1 : 0, unit: "runs", budget: .exactly(1, "runs"),
            ),
            BenchResult(
                scenario: name, id: "library-files-lost", name: "Photos not where their rows say, after each",
                value: Double(checks.lost + checks.rows), unit: "photos", budget: .exactly(0, "photos"),
            ),
            BenchResult(
                scenario: name, id: "library-files-apart", name: "Photos apart from their sidecar or xmp, after each",
                value: Double(checks.apart), unit: "photos", budget: .exactly(0, "photos"),
            ),
        ]
    }

    /// `count` photos in folders of 500: every fifth shot a raw and its JPEG, half the photos with a
    /// sidecar, a tenth with an `.xmp`, taken a second apart.
    static func shots(_ count: Int) -> [Shot] {
        var shots: [Shot] = []
        var number = 0
        while shots.count < count {
            let folder = String(format: "Day %03d", shots.count / folderSize + 1)
            let base = String(format: "IMG_%05d", number)
            let captured = Date(timeIntervalSince1970: 1_709_294_400 + Double(number))
            let names = number % 5 == 0 && shots.count + 1 < count ? [base + ".ARW", base + ".JPG"] : [base + ".JPG"]
            for name in names {
                let index = shots.count
                shots.append(Shot(
                    path: folder + "/" + name, captured: captured, sidecar: index % 2 == 0, xmp: index % 10 == 5,
                ))
            }
            number += 1
        }
        return shots
    }

    /// Writes the shots, their sidecars and `.xmp`, and an index of them; returns it with the photos'
    /// IDs in the shots' order.
    static func write(_ shots: [Shot], root: URL, paths: LibraryPaths) async throws -> (LibraryIndex, [Int64]) {
        let sidecar = try Self.sidecarJSON()
        try await LibraryIndex.offCaller {
            for folder in Set(shots.map { FilePlanner.split($0.path).folder }) {
                try FileManager.default.createDirectory(
                    at: root.appending(path: folder),
                    withIntermediateDirectories: true,
                )
            }
            DispatchQueue.concurrentPerform(iterations: shots.count) { number in
                let shot = shots[number]
                let url = root.appending(path: shot.path)
                try? Data("photo \(number)".utf8).write(to: url)
                if shot.sidecar {
                    let package = url.appendingPathExtension("redlamp")
                    try? FileManager.default.createDirectory(at: package, withIntermediateDirectories: false)
                    try? sidecar.write(to: package.appending(path: SidecarStore.editFile))
                }
                if shot.xmp {
                    try? Data("<x:xmpmeta/>".utf8).write(to: url.appendingPathExtension("xmp"))
                }
            }
        }
        let index = try await LibraryIndex.open(at: paths.index)
        let rootPath = LibraryIndexer.path(root)
        let listed = try await LibraryIndex.offCaller {
            try Set(shots.map { FilePlanner.split($0.path).folder }).reduce(into: [String: [String: FileEntry]]()) {
                listed, folder in
                let entries = try LocalFileSystem().contentsOfDirectory(at: root.appending(path: folder))
                listed[folder] = Dictionary(entries.map { ($0.name, $0) }) { first, _ in first }
            }
        }
        let ids = try await index.write { writer -> [Int64] in
            let volume = try writer.upsertVolume(VolumeRecord(uuid: "BENCH-VOLUME", name: "Bench", kind: .ssd))
            _ = try writer.upsertRoot(RootRecord(volume: volume, path: rootPath))
            var records: [PhotoRecord] = []
            for shot in shots {
                let (folder, name) = FilePlanner.split(shot.path)
                guard let folderID = try writer.folderID(forPath: rootPath + "/" + folder),
                      let entry = listed[folder]?[name]
                else { continue }
                records.append(PhotoRecord(
                    folder: folderID, name: name, size: entry.size, modified: entry.modified,
                    fileID: entry.fileIdentifier, captured: shot.captured, indexed: 1,
                ))
            }
            return try writer.upsertPhotos(records)
        }
        return (index, ids)
    }

    /// A sidecar with a rating, as `SidecarStore` writes it.
    private static func sidecarJSON() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        return try encoder.encode(Sidecar(
            recipe: EditRecipe(), metadata: PhotoMetadata(rating: 3),
            modified: Date(timeIntervalSince1970: 1_790_000_000),
        ))
    }

    /// What one rename costs the disk: a photo of each folder renamed away and back, 2,000 times in all.
    static func renameCost(root: URL, shots: [Shot]) throws -> Double {
        let photos = shots.prefix(1000).map { root.appending(path: $0.path).path }
        let clock = ContinuousClock()
        let started = clock.now
        var renames = 0
        for photo in photos {
            let away = photo + ".renaming"
            guard renamex_np(photo, away, UInt32(RENAME_EXCL)) == 0 else { throw POSIXError.current }
            guard renamex_np(away, photo, UInt32(RENAME_EXCL)) == 0 else { throw POSIXError.current }
            renames += 2
        }
        return (clock.now - started).seconds / Double(max(renames, 1))
    }

    /// Photos whose file isn't where their row says, and those whose sidecar or `.xmp` isn't beside
    /// them; and how many rows there are.
    static func check(_ shots: [Shot], ids: [Int64], index: LibraryIndex, root: URL) async throws
        -> (lost: Int, apart: Int, rows: Int) {
        let rows = try await index.read { reader in try reader.photosWithPaths(ids) }
        let byID = Dictionary(zip(ids, shots)) { first, _ in first }
        return try await LibraryIndex.offCaller {
            var found = (lost: 0, apart: 0, rows: rows.count)
            var listings: [String: Set<String>] = [:]
            for (photo, folder) in rows {
                if listings[folder] == nil {
                    listings[folder] = try Set(FileManager.default.contentsOfDirectory(atPath: folder))
                }
                let names = listings[folder] ?? []
                guard names.contains(photo.name) else {
                    found.lost += 1
                    continue
                }
                guard let shot = byID[photo.id] else { continue }
                if shot.sidecar && !names.contains(photo.name + ".redlamp")
                    || shot.xmp && !names.contains(photo.name + ".xmp") {
                    found.apart += 1
                }
            }
            let paths = FileManager.default.subpaths(atPath: root.path) ?? []
            if paths.contains(where: { $0.contains("/.") || $0.hasPrefix(".") }) {
                found.apart += 1
            }
            return found
        }
    }
}
