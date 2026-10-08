import CoreGraphics
import Foundation
import ImageIO
import RedlampBench

/// What the app and its share extension share: the library in the App Group container, and
/// filing results into a folder.
enum BenchShared {
    /// The App Group container both targets can see; the app's own Application Support when
    /// the build has no App Group (an unsigned simulator build).
    static var root: URL {
        let group = Bundle.main.object(forInfoDictionaryKey: "BenchAppGroup") as? String
        if let group, let container = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: group) {
            return container.appending(path: "Bench", directoryHint: .isDirectory)
        }
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return support.appending(path: "Bench", directoryHint: .isDirectory)
    }

    static var library: BenchLibrary {
        BenchLibrary(root: root)
    }

    /// The hub the phone paired with, if any.
    static func client(_ library: BenchLibrary) -> BenchClient? {
        let settings = library.settings
        guard let hub = settings.hub, let token = settings.token else { return nil }
        return BenchClient(base: hub, token: token)
    }

    /// Files each file into the folder, pairing it, and queues the folder once it's complete.
    /// Returns the results in the order given.
    static func file(
        _ files: [(url: URL, name: String)],
        into id: String,
        library: BenchLibrary,
    ) throws -> (BenchFolder, [BenchResult]) {
        guard var folder = library.folder(id) else { throw BenchError.notFound("task \(id)") }
        let pairer = BenchPairer(folder: folder)
        var results: [BenchResult] = []
        for file in files {
            try results.append(folder.addResult(copying: file.url, originalName: file.name, pairer: pairer))
        }
        library.markUsed(id)
        library.enqueueIfComplete(folder)
        return (folder, results)
    }

    /// A small image for a list or grid, from any file ImageIO reads (raws through their previews).
    static func thumbnail(_ url: URL, maxPixels: Int = 480) -> CGImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixels,
        ]
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
    }
}
