import Foundation
import RedlampDocument
@testable import RedlampLibrary

/// An index in a folder of its own, with a volume and a root at `rootPath`.
struct IndexSandbox {
    static let rootPath = "/Volumes/Test/Photos"

    let directory: URL
    let index: LibraryIndex
    let volume: Int64
    let root: Int64

    var url: URL {
        index.url
    }

    var snapshots: URL {
        directory.appending(path: "Snapshots", directoryHint: .isDirectory)
    }

    /// `textMerges` says how the text index is merged after writes (`IndexTextMerges`).
    static func make(readers: Int = 2, textMerges: IndexTextMerges.Limits = .init()) async throws -> IndexSandbox {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "redlamp-index-\(UUID().uuidString)", directoryHint: .isDirectory)
        let url = directory.appending(path: "Index.sqlite")
        let index = try await LibraryIndex.offCaller {
            try LibraryIndex(url: url, readers: readers, migrations: LibraryIndex.migrations, textMerges: textMerges)
        }
        let (volume, root) = try await index.write { writer in
            let volume = try writer.upsertVolume(VolumeRecord(uuid: "TEST-VOLUME", name: "Test", kind: .ssd))
            return try (volume, writer.upsertRoot(RootRecord(volume: volume, path: rootPath)))
        }
        return IndexSandbox(directory: directory, index: index, volume: volume, root: root)
    }

    /// Adds folders under the root by relative path, each after its parent, and returns their IDs
    /// by those paths.
    @discardableResult
    func addFolders(_ paths: [String]) async throws -> [String: Int64] {
        let root = root
        return try await index.write { writer in
            var ids: [String: Int64] = [:]
            for path in paths.sorted() {
                let parent = path.split(separator: "/").dropLast().joined(separator: "/")
                ids[path] = try writer.upsertFolder(FolderRecord(
                    root: root, parent: ids[parent], path: Self.rootPath + "/" + path,
                ))
            }
            return ids
        }
    }

    @discardableResult
    func upsert(_ photos: [PhotoRecord]) async throws -> [Int64] {
        try await index.write { try $0.upsertPhotos(photos) }
    }

    /// Closes the index and removes its folder.
    func remove() {
        index.closeAndWait()
        try? FileManager.default.removeItem(at: directory)
    }
}

/// Photos like a library's, from a seed: names by camera maker, captured over 20 years, about a
/// sixth rated or flagged, and captions on a fifth.
struct SyntheticIndexPhotos {
    static let cameras = [
        "Canon EOS R5", "Canon EOS R6 Mark II", "Canon EOS 5D Mark IV", "Nikon Z 8", "Nikon Z 6II", "Nikon D850",
        "Sony ILCE-7RM5", "Sony ILCE-7M4", "Sony ILCE-1", "Fujifilm X-T5", "Fujifilm X-H2", "Fujifilm GFX 100S",
        "OM System OM-1", "Panasonic DC-S5M2", "Panasonic DC-GH6", "Leica Q3", "Leica M11", "Ricoh GR III",
        "Hasselblad X2D 100C", "Apple iPhone 15 Pro", "Apple iPhone 14", "Google Pixel 8 Pro", "DJI Mavic 3",
        "Pentax K-3 Mark III", "Sigma fp L",
    ]
    static let lenses = (0 ..< 40).map { index in
        let focal = [14, 16, 20, 24, 28, 35, 50, 85, 105, 135][index % 10]
        let aperture = ["1.4", "1.8", "2.8", "4"][index / 10]
        return "\(focal)mm F\(aperture) \(["DG", "GM", "S", "WR"][index % 4])"
    }

    private static let prefixes = ["IMG_", "IMG_", "IMG_", "DSC_", "DSC_", "DSC_", "_DSC", "_DSC", "_DSC", "DSCF"]
    private static let extensions = [".CR3", ".CR3", ".CR2", ".NEF", ".NEF", ".NEF", ".ARW", ".ARW", ".ARW", ".RAF"]
    private static let words = [
        "tram", "harbour", "market", "wedding", "portrait", "sunset", "alfama", "bridge", "river", "festival",
        "studio", "garden", "street", "night", "beach", "mountain", "cathedral", "concert", "family", "birds",
    ]

    /// SplitMix64, so a seed makes the same photos every time.
    private struct Random {
        var state: UInt64

        mutating func next() -> UInt64 {
            state &+= 0x9E37_79B9_7F4A_7C15
            var z = state
            z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
            z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
            return z ^ (z >> 31)
        }

        mutating func pick<T>(_ values: [T]) -> T {
            values[Int(next() % UInt64(values.count))]
        }
    }

    private var random: Random
    let cameraIDs: [Int64]
    let lensIDs: [Int64]

    init(seed: UInt64, cameraIDs: [Int64], lensIDs: [Int64]) {
        random = Random(state: seed)
        self.cameraIDs = cameraIDs
        self.lensIDs = lensIDs
    }

    /// The name of photo `number`, as its camera would have it.
    static func name(_ number: Int, camera: Int) -> String {
        let digits = String(number)
        return prefixes[camera % 10] + String(repeating: "0", count: max(0, 6 - digits.count)) + digits
            + extensions[camera % 10]
    }

    /// Photo `number`, unique across the library, in `folder`.
    mutating func photo(_ number: Int, in folder: Int64) -> PhotoRecord {
        let camera = Int(random.next() % UInt64(cameraIDs.count))
        let captured = Date(timeIntervalSince1970: 1_104_537_600 + Double(random.next() % 631_152_000))
        let roll = random.next() % 100
        var photo = PhotoRecord(
            folder: folder, name: Self.name(number, camera: camera),
            size: 20_000_000 + Int64(random.next() % 40_000_000),
            modified: captured.addingTimeInterval(3600), fileID: UInt64(1_000_000 + number),
            contentKey: withUnsafeBytes(of: (random.next(), random.next())) { Data($0) }, captured: captured,
            capturedOffset: 3600, camera: cameraIDs[camera], lens: random.pick(lensIDs),
            iso: random.pick([100, 200, 400, 800, 1600, 3200, 6400]), aperture: random.pick([
                1.4,
                2,
                2.8,
                4,
                5.6,
                8,
                11,
            ]),
            shutter: 1 / Double(30 + random.next() % 4000), focal: random.pick([16, 23, 35, 50, 85, 135, 200]),
            width: 6000, height: 4000, orientation: 1, rating: roll < 15 ? Int(1 + random.next() % 5) : 0,
            flag: roll < 5 ? .pick : roll < 7 ? .reject : nil, label: roll % 20 == 0 ? .red : nil, indexed: 1,
        )
        if roll % 3 == 0 {
            photo.latitude = 38.7 + Double(random.next() % 1000) / 1000
            photo.longitude = -9.1 - Double(random.next() % 1000) / 1000
        }
        if roll % 5 == 1 {
            photo.caption = (0 ..< 4).map { _ in random.pick(Self.words) }.joined(separator: " ")
        }
        return photo
    }
}

/// A gate a closure on another thread waits at, so a test decides when it goes on.
final class IndexGate: Sendable {
    private let semaphore = DispatchSemaphore(value: 0)

    func wait() {
        semaphore.wait()
    }

    func open() {
        semaphore.signal()
    }
}
