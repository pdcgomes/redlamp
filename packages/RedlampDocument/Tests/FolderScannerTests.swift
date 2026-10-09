import Foundation
import RedlampDocument
import RedlampEngineAPI
import Testing

struct FolderScannerTests {
    private let root = FileManager.default.temporaryDirectory.appending(path: "scanner-\(UUID().uuidString)")

    private func touch(_ path: String, bytes: Int = 4) throws {
        let url = root.appending(path: path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(repeating: 1, count: bytes).write(to: url)
    }

    private func folder(_ path: String) throws {
        try FileManager.default.createDirectory(at: root.appending(path: path), withIntermediateDirectories: true)
    }

    @Test func `a listing finds photos, their sidecars and subfolders without reading any file`() throws {
        defer { try? FileManager.default.removeItem(at: root) }
        try touch("IMG_10.ARW", bytes: 10)
        try touch("IMG_9.ARW")
        try touch("img_2.jpg")
        try touch("notes.txt")
        try touch(".hidden.ARW")
        try folder("IMG_9.ARW.redlamp")
        try touch("IMG_9.ARW.redlamp/edit.json")
        try touch("img_2.jpg.redlamp")
        try folder("Selects")
        try folder(".cache")
        try folder("Library.photoslibrary")
        try touch("Library.photoslibrary/Contents/x")

        let listing = try FolderScanner.list(root)
        #expect(listing.photos.map(\.name) == ["img_2.jpg", "IMG_9.ARW", "IMG_10.ARW"])
        #expect(listing.photos.map(\.hasSidecar) == [true, true, false])
        #expect(listing.photos.last?.size == 10)
        #expect(listing.photos.allSatisfy { $0.isLocal && $0.sidecarIsLocal })
        #expect(listing.subfolders.map(\.lastPathComponent).contains("Selects"))
        #expect(!listing.subfolders.map(\.lastPathComponent).contains(".cache"))
    }

    @Test func `a walk yields every folder depth first in Finder's order`() async throws {
        defer { try? FileManager.default.removeItem(at: root) }
        try touch("a.ARW")
        try touch("Day 10/c.ARW")
        try touch("Day 2/b.ARW")
        try touch("Day 2/Picks/b2.ARW")
        try folder("Day 3")

        var names: [String] = []
        var photos: [String] = []
        for await listing in FolderScanner.walk(root) {
            names.append(listing.folder.lastPathComponent)
            photos += listing.photos.map(\.name)
        }
        #expect(names == [root.lastPathComponent, "Day 2", "Picks", "Day 3", "Day 10"])
        #expect(photos == ["a.ARW", "b.ARW", "b2.ARW", "c.ARW"])
    }

    @Test func `names sort as Finder sorts them`() {
        let names = ["IMG_10.ARW", "img_9.arw", "IMG_009b.ARW", "DSC0001.NEF", "Ölberg.jpg", "a.jpg", "IMG_9.ARW"]
        let sorted = names.sorted(by: FileOrder.precedes)
        let finder = names.sorted { $0.localizedStandardCompare($1) == .orderedAscending }
        #expect(sorted.map { $0.lowercased() } == finder.map { $0.lowercased() })
        #expect(FileOrder.precedes("IMG_2.ARW", "IMG_10.ARW"))
        #expect(!FileOrder.precedes("IMG_10.ARW", "IMG_2.ARW"))
    }

    @Test func `digits come after a space, a hyphen and a full stop and before an underscore, and a name all ASCII before one that folds the same`() {
        let ordered = [
            "cafe", "Café", "Cafe 2", "Café 10", "DSC 2", "DSC-2", "DSC.2", "DSC05507", "DSC_5513", "DSCF0001", "Ete",
            "Été 2", "Etude", "Zoë", "東京",
        ]
        for seed in 0 ..< 20 {
            var random = Xorshift(seed: UInt64(seed + 1))
            #expect(ordered.shuffled(using: &random).sorted(by: FileOrder.precedes) == ordered, "seed \(seed)")
        }
        for (first, second) in [("img_0001.jpg", "IMG_1.JPG"), ("Café", "café"), ("Caf\u{E9}", "Cafe\u{301}")] {
            #expect(FileOrder.compare(first, second) == .orderedSame, "\(first) and \(second)")
        }
    }

    @Test func `names sort as their keys do, whatever their digits, punctuation, case and accents`() {
        let pieces = [
            "a", "B", "z", "img", "_", "-", " ", ".", "~", "(", ":", "0", "1", "9", "007", "10", "é", "É", "e\u{301}",
            "\u{301}", "ß", "Ａ", "１", "–", "東",
        ]
        for seed in 1 ... 3 {
            var random = Xorshift(seed: UInt64(seed))
            let names = (0 ..< 300).map { _ in
                (0 ..< Int.random(in: 1 ... 6, using: &random)).map { _ in pieces.randomElement(using: &random) ?? "" }
                    .joined()
            }
            let keys = names.map(FileOrder.key)
            for (left, name) in names.enumerated() {
                for (right, other) in names.enumerated() {
                    let keyed: ComparisonResult = keys[left] == keys[right] ? .orderedSame
                        : keys[left].lexicographicallyPrecedes(keys[right]) ? .orderedAscending : .orderedDescending
                    #expect(FileOrder.compare(name, other) == keyed, "\(name) and \(other)")
                }
            }
        }
    }

    @Test func `the order holds across names beyond ASCII, as localizedStandardCompare's didn't`() {
        // That one put a0 before a_é and a_é before a–, but a– before a0.
        let names = ["a0", "a_é", "a–"]
        for order in [[0, 1, 2], [0, 2, 1], [1, 0, 2], [1, 2, 0], [2, 0, 1], [2, 1, 0]] {
            #expect(order.map { names[$0] }.sorted(by: FileOrder.precedes) == names)
        }
    }

    @Test func `the sidecar probe reads badges from edit.json alone`() throws {
        defer { try? FileManager.default.removeItem(at: root) }
        try folder("")
        let photo = root.appending(path: "IMG_1.ARW")
        try Data([1]).write(to: photo)
        var recipe = EditRecipe()
        recipe[.exposure] = 0.5
        try SidecarStore().save(Sidecar(recipe: recipe, metadata: PhotoMetadata(rating: 3, flag: .pick)), for: photo)

        let summary = try #require(SidecarStore().summary(for: photo))
        #expect(summary.hasEdits)
        #expect(summary.metadata == PhotoMetadata(rating: 3, flag: .pick))
        #expect(SidecarStore().summary(for: root.appending(path: "IMG_2.ARW")) == nil)
    }
}

/// The same numbers for the same seed, so a failure can be run again.
private struct Xorshift: RandomNumberGenerator {
    private var state: UInt64

    init(seed: UInt64) {
        state = seed
    }

    mutating func next() -> UInt64 {
        state ^= state << 13
        state ^= state >> 7
        state ^= state << 17
        return state
    }
}
