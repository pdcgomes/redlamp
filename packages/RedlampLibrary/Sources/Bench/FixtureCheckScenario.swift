import Foundation
import RedlampDocument
import RedlampEngineAPI
import Synchronization

/// Counts the fixture's files again, straight from the disk, and compares them with its
/// manifest: photos of each kind, sidecars, other apps' `.xmp`, folders, and each folder's
/// photos. Every query count in the manifest depends on these.
public struct FixtureCheckScenario: BenchScenario {
    public let name = "fixture-check"

    public init() {}

    public func run(_ context: BenchContext) async throws -> [BenchResult] {
        struct Found {
            var raws = 0
            var jpegs = 0
            var heics = 0
            var sidecars = 0
            var xmp = 0
            var folders: [String: Int] = [:]
        }
        let found = Mutex(Found())
        let disk = LocalFileSystem()
        try await FolderWalk.walk(context.fixture, fileSystem: disk, width: CoreCounts.performance) { path, entries in
            var counted = Found()
            for entry in entries {
                switch (entry.isDirectory, (entry.name as NSString).pathExtension.lowercased()) {
                case (true, "redlamp"): counted.sidecars += 1
                case (false, "xmp"): counted.xmp += 1
                case (false, "jpg"), (false, "jpeg"): counted.jpegs += 1
                case (false, "heic"): counted.heics += 1
                case let (false, ext) where SupportedFormats.rawExtensions.contains(ext): counted.raws += 1
                default: break
                }
            }
            found.withLock { found in
                found.raws += counted.raws
                found.jpegs += counted.jpegs
                found.heics += counted.heics
                found.sidecars += counted.sidecars
                found.xmp += counted.xmp
                if !path.isEmpty {
                    found.folders[path] = counted.raws + counted.jpegs + counted.heics
                }
            }
        }
        let counted = found.withLock { $0 }
        let manifest = context.manifest
        let expected = Dictionary(manifest.folders.map { ($0.path, $0.photos) }) { first, _ in first }
        let differing = Set(expected.keys).union(counted.folders.keys)
            .count(where: { expected[$0] != counted.folders[$0] })
        func check(_ id: String, _ label: String, _ value: Int, _ target: Int, _ unit: String) -> BenchResult {
            BenchResult(
                scenario: name, id: "library-fixture-\(id)", name: label, value: Double(value), unit: unit,
                budget: .exactly(Double(target), unit),
            )
        }
        let totals = manifest.totals
        return [
            check("photos", "Photos", counted.raws + counted.jpegs + counted.heics, totals.photos, "photos"),
            check("raws", "Raws", counted.raws, totals.raws, "photos"),
            check("jpegs", "JPEGs", counted.jpegs, totals.jpegs, "photos"),
            check("heics", "HEICs", counted.heics, totals.heics, "photos"),
            check("sidecars", ".redlamp sidecars", counted.sidecars, totals.sidecars, "sidecars"),
            check("xmp", "Other apps' .xmp", counted.xmp, totals.xmpSidecars, "files"),
            check("folders", "Folders", counted.folders.count, totals.folders, "folders"),
            check("differing", "Folders whose photos differ from the manifest", differing, 0, "folders"),
        ]
    }
}
