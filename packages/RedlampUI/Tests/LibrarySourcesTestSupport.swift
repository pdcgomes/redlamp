import AppKit
import CoreGraphics
import Foundation
import ImageIO
import RedlampDocument
import RedlampLibrary
import Testing
import UniformTypeIdentifiers
@_spi(Harness) @testable import RedlampUI

/// A library of small JPEGs on the external disk's scratch folder, indexed, in an editor, for the left panel's
/// Library and Collections sections (LIB-23); removed with what it made.
@MainActor
final class SourcesSandbox {
    let base = URL(fileURLWithPath: "/Volumes/SSD/redlamp-tmp", isDirectory: true)
        .appending(path: "collections-\(UUID().uuidString)", directoryHint: .isDirectory)
    private(set) var model: EditorModel?
    private(set) var service: LibraryService?

    var root: URL {
        base.appending(path: "Photos", directoryHint: .isDirectory)
    }

    func photo(_ path: String) -> URL {
        root.appending(path: path, directoryHint: .notDirectory)
    }

    func folder(_ path: String) -> URL {
        root.appending(path: path, directoryHint: .isDirectory)
    }

    /// Small JPEGs at `paths` below the root (or below `under`), each its own colour, so each has its own
    /// content key.
    func photos(_ paths: [String], under: URL? = nil, from first: Int = 0) throws {
        for (offset, path) in paths.enumerated() {
            let url = (under ?? root).appending(path: path, directoryHint: .notDirectory)
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true,
            )
            try Self.jpeg(number: first + offset).write(to: url)
        }
    }

    static func jpeg(number: Int) throws -> Data {
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
        try CGImageDestinationAddImage(destination, #require(context.makeImage()), nil)
        #expect(CGImageDestinationFinalize(destination))
        return data as Data
    }

    /// The editor, its library following the root, once the library has indexed it and caught up with the disk.
    func open() async throws -> EditorModel {
        let library = FolderLibrary()
        library.add([root])
        let service = LibraryService(
            paths: LibraryPaths(root: base.appending(path: "Library", directoryHint: .isDirectory)),
            sidecars: library.sidecars,
        ) { url, size in StoreThumbnailMaker.imageIO(url, nil, size) }
        library.attach(service)
        for _ in 0 ..< 2000 where await !service.canShow(root, includingSubfolders: true) {
            try await Task.sleep(for: .milliseconds(10))
        }
        try #require(await service.canShow(root, includingSubfolders: true), "the library caught up with the root")
        let model = EditorModel(engine: StubEngine(), library: library)
        model.showModule(.library)
        self.model = model
        self.service = service
        return model
    }

    func remove() {
        service?.close()
        try? FileManager.default.removeItem(at: base)
    }

    /// Waits up to `seconds` for `condition`.
    func eventually(seconds: Double = 10, _ condition: () -> Bool) async throws {
        for _ in 0 ..< Int(seconds * 200) where !condition() {
            try await Task.sleep(for: .milliseconds(5))
        }
    }

    /// Counts the library again, and again, until `condition` holds, for up to `seconds`: what changed reaches
    /// the query engine a moment after its batch.
    func counts(seconds: Double = 20, until condition: (LibrarySources) -> Bool) async throws {
        let sources = try #require(model?.librarySources)
        let deadline = ContinuousClock.now + .seconds(seconds)
        while ContinuousClock.now < deadline {
            await service?.settled()
            sources.recount()
            await sources.counted()
            if condition(sources) {
                return
            }
            try await Task.sleep(for: .milliseconds(50))
        }
    }

    /// Culls `photos` as one change from Library, and returns once it's written and the library has it.
    func cull(_ action: ShortcutAction, _ photos: [URL]) async throws {
        let model = try #require(model)
        try #require(!photos.isEmpty)
        model.select(photos[0])
        for photo in photos.dropFirst() {
            model.click(photo, toggling: true)
        }
        #expect(model.perform(action))
        try await eventually { !model.isWritingCulling }
        await service?.settled()
    }
}
