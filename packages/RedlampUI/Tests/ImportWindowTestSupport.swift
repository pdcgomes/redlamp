import AppKit
import CoreGraphics
import Foundation
import ImageIO
import RedlampDocument
import Testing
import UniformTypeIdentifiers
@testable import RedlampLibrary
@_spi(Harness) @testable import RedlampUI

/// A library (index, store, indexer), folders and cards of photos to import from, and a destination and
/// a backup to import into, in a folder of their own: on this Mac's scratch volume when it has one, else
/// in the temporary folder. The photos are small JPEGs taken on 5 October 2026 from 09:00, a second
/// apart; photo `n` has the same bytes wherever it's written, so the library recognises it.
@MainActor
final class ImportWindowFixture {
    static let scratch: URL = {
        let ssd = URL(fileURLWithPath: "/Volumes/SSD/redlamp-tmp", isDirectory: true)
        return FileManager.default.fileExists(atPath: ssd.path) ? ssd : FileManager.default.temporaryDirectory
    }()

    let base: URL
    let suite = "import-window-tests-\(UUID().uuidString)"
    let defaults: UserDefaults
    let preferences: ImportPreferences
    let paths: LibraryPaths
    let index: LibraryIndex
    let store: PhotoStore
    let library: ImportLibrary

    var destination: URL {
        base.appending(path: "Pictures", directoryHint: .isDirectory)
    }

    var backup: URL {
        base.appending(path: "Backup", directoryHint: .isDirectory)
    }

    private init(base: URL, index: LibraryIndex, paths: LibraryPaths) {
        self.base = base
        self.index = index
        self.paths = paths
        defaults = UserDefaults(suiteName: suite)!
        preferences = ImportPreferences(defaults: defaults)
        store = PhotoStore(root: paths.store)
        library = ImportLibrary(
            paths: paths, index: index, store: store,
            indexer: LibraryIndexer(index: index, thumbnails: StoreThumbnailMaker(store: store).thumbnails),
        )
    }

    static func make() async throws -> ImportWindowFixture {
        let base = scratch.appending(path: "import-window-\(UUID().uuidString)", directoryHint: .isDirectory)
            .standardizedFileURL
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        let paths = LibraryPaths(root: base.appending(path: "Library", directoryHint: .isDirectory))
        let index = try await LibraryIndex.open(at: paths.index, readers: 2)
        return ImportWindowFixture(base: base, index: index, paths: paths)
    }

    func remove() {
        store.close()
        let index = index
        let closed = DispatchSemaphore(value: 0)
        DispatchQueue.global(qos: .userInitiated).async {
            index.closeAndWait()
            closed.signal()
        }
        closed.wait()
        try? FileManager.default.removeItem(at: base)
        UserDefaults().removePersistentDomain(forName: suite)
    }

    /// A window's model on this fixture's library and preferences, hearing of no volume.
    func model(
        cards: ImportCards = ImportCards { _ in nil }, fileSystem: any LibraryFileSystem = LocalFileSystem(),
    ) -> ImportWindowModel {
        ImportWindowModel(library: library, preferences: preferences, cards: cards, fileSystem: fileSystem)
    }

    /// A folder named `name` holding photos `from` to `from + count - 1`, each `padding` bytes larger
    /// than its JPEG, newer by its number.
    @discardableResult
    func folder(_ name: String, count: Int, from first: Int = 0, padding: Int = 0) throws -> URL {
        let folder = base.appending(path: name, directoryHint: .isDirectory)
        try write(count: count, from: first, padding: padding, in: folder)
        return folder
    }

    /// A card named `name`, its photos in `DCIM/100CANON`.
    func card(_ name: String, count: Int, from first: Int = 0) throws -> URL {
        let root = base.appending(path: "Cards/" + name, directoryHint: .isDirectory)
        try write(count: count, from: first, padding: 0, in: root.appending(path: "DCIM/100CANON"))
        return root
    }

    /// The card at `root`, as the Mac would describe a card in a reader.
    func cardSource(_ root: URL) throws -> ImportSource {
        try ImportSource.at(root, medium: .card(at: root))
    }

    private func write(count: Int, from first: Int, padding: Int, in folder: URL) throws {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        for number in first ..< first + count {
            let url = folder.appending(path: Self.name(number))
            try Self.jpeg(number, padding: padding).write(to: url)
            try FileManager.default.setAttributes(
                [.modificationDate: Self.taken(number)], ofItemAtPath: url.path,
            )
        }
    }

    static func name(_ number: Int) -> String {
        String(format: "IMG_%04d.JPG", number)
    }

    /// 5 October 2026 at 09:00, and `number` seconds after, by the camera's clock.
    static func taken(_ number: Int) -> Date {
        Date(timeIntervalSince1970: 1_791_190_800 + Double(number))
    }

    /// A 64 × 48 JPEG with its EXIF capture time, and its number after its end, where decoders don't look.
    static func jpeg(_ number: Int, padding: Int) throws -> Data {
        let space = try #require(CGColorSpace(name: CGColorSpace.sRGB))
        let context = try #require(CGContext(
            data: nil, width: 64, height: 48, bitsPerComponent: 8, bytesPerRow: 0, space: space,
            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue,
        ))
        context.setFillColor(
            red: CGFloat(number % 7) / 7, green: CGFloat(number % 5) / 5, blue: CGFloat(number % 3) / 3, alpha: 1,
        )
        context.fill(CGRect(x: 0, y: 0, width: 64, height: 48))
        let data = NSMutableData()
        let destination = try #require(CGImageDestinationCreateWithData(
            data,
            UTType.jpeg.identifier as CFString,
            1,
            nil,
        ))
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "yyyy:MM:dd HH:mm:ss"
        let properties: [CFString: Any] = [
            kCGImagePropertyExifDictionary: [
                kCGImagePropertyExifDateTimeOriginal: formatter.string(from: taken(number)),
            ],
            kCGImagePropertyTIFFDictionary: [
                kCGImagePropertyTIFFMake: "Canon",
                kCGImagePropertyTIFFModel: "Canon EOS R6",
            ],
        ]
        try CGImageDestinationAddImage(destination, #require(context.makeImage()), properties as CFDictionary)
        #expect(CGImageDestinationFinalize(destination))
        var bytes = data as Data
        bytes.append(contentsOf: Array("redlamp-\(number)".utf8))
        bytes.append(Data(count: padding))
        return bytes
    }

    /// Indexes `folder` into the library, as though its photos had been imported before.
    func index(_ folder: URL) async throws {
        let indexer = try #require(library.indexer)
        for await _ in indexer.index([folder]) {}
    }

    /// Every file below `root` but hidden ones, by its path below it.
    static func files(in root: URL) -> Set<String> {
        Set((FileManager.default.subpaths(atPath: root.path) ?? []).filter { path in
            var isDirectory: ObjCBool = false
            return !path.split(separator: "/").contains { $0.hasPrefix(".") }
                && FileManager.default.fileExists(atPath: root.appending(path: path).path, isDirectory: &isDirectory)
                && !isDirectory.boolValue
        })
    }

    /// What's hidden below `root`: what a copy cut short would leave.
    static func leftovers(in root: URL) -> [String] {
        (FileManager.default.subpaths(atPath: root.path) ?? []).filter { path in
            path.split(separator: "/").contains { $0.hasPrefix(".") }
        }
    }
}

/// Waits until `condition` holds, checking every 10 ms; fails after `seconds`.
@MainActor
func waitUntil(
    _ what: String, seconds: Double = 20, _ condition: @MainActor () -> Bool,
) async throws {
    let deadline = ContinuousClock.now + .seconds(seconds)
    while !condition() {
        guard ContinuousClock.now < deadline else {
            Issue.record("Timed out waiting for \(what)")
            throw CancellationError()
        }
        try await Task.sleep(for: .milliseconds(10))
    }
}
