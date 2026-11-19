import CoreGraphics
import Foundation
import ImageIO
import RedlampDocument
import RedlampEngineAPI
import Testing

/// `redlamp export` (EDT-16), run as a person runs it, on sample raws from tests/fixtures/raw: several photos
/// exported at once, each with its own edit, named by a template, one that fails named with why while the others
/// export. One at a time, since each run renders full-size raws.
@Suite(.serialized)
struct ExportCommandTests {
    private final class Bundled {}

    /// The tool, built beside this test bundle.
    private static let redlamp = Bundle(for: Bundled.self).bundleURL.deletingLastPathComponent()
        .appending(path: "redlamp")
    private static let fixtures = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .appending(path: "tests/fixtures/raw")
    private static let photos = ["_DSC0009.ARW", "PXL_20201121_100251397.dng"].map { fixtures.appending(path: $0) }

    /// What a run printed, line by line, and how it exited.
    private struct Run {
        var status: Int32
        var output: [String]
        var errors: [String]

        /// The photos it didn't export, each a line with its path and why: Metal's validation layer writes to
        /// standard error too.
        var failures: [String] {
            errors.filter { $0.hasPrefix("/") }
        }
    }

    /// A folder of the test's own, which the exports go in, beside what the runs print.
    private static func scratch() throws -> URL {
        let folder = FileManager.default.temporaryDirectory.appending(path: "redlamp-export-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }

    private static func run(_ arguments: [String], in scratch: URL) async throws -> Run {
        try #require(FileManager.default.isExecutableFile(atPath: redlamp.path), "redlamp isn't built beside the tests")
        let output = scratch.appending(path: "output.txt"), errors = scratch.appending(path: "errors.txt")
        FileManager.default.createFile(atPath: output.path, contents: nil)
        FileManager.default.createFile(atPath: errors.path, contents: nil)
        let process = Process()
        process.executableURL = redlamp
        process.arguments = ["export"] + arguments
        process.standardOutput = try FileHandle(forWritingTo: output)
        process.standardError = try FileHandle(forWritingTo: errors)
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
            process.terminationHandler = { _ in continuation.resume() }
            do {
                try process.run()
            } catch {
                continuation.resume(throwing: error)
            }
        }
        func lines(_ url: URL) throws -> [String] {
            try String(contentsOf: url, encoding: .utf8).split(separator: "\n").map(String.init)
        }
        return try Run(status: process.terminationStatus, output: lines(output), errors: lines(errors))
    }

    private static func image(_ url: URL) throws -> CGImage {
        let source = try #require(CGImageSourceCreateWithURL(url as CFURL, nil), "\(url.lastPathComponent) isn't there")
        return try #require(CGImageSourceCreateImageAtIndex(source, 0, nil), "\(url.lastPathComponent) doesn't decode")
    }

    /// The widest a pixel's channels are apart, the image drawn at 32 × 32: 0 for black and white.
    private static func spread(_ image: CGImage) throws -> Int {
        let side = 32
        var pixels = [UInt8](repeating: 0, count: side * side * 4)
        let space = try #require(CGColorSpace(name: CGColorSpace.sRGB))
        let drawn = pixels.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(
                data: buffer.baseAddress, width: side, height: side, bitsPerComponent: 8, bytesPerRow: side * 4,
                space: space, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue,
            ) else { return false }
            context.draw(image, in: CGRect(x: 0, y: 0, width: side, height: side))
            return true
        }
        try #require(drawn)
        return stride(from: 0, to: pixels.count, by: 4).map { index in
            let channels = pixels[index ..< index + 3]
            return Int(channels.max() ?? 0) - Int(channels.min() ?? 0)
        }.max() ?? 0
    }

    @Test func `photos export one at a time, named by the template, each a file ImageIO reads`() async throws {
        let scratch = try Self.scratch()
        defer { try? FileManager.default.removeItem(at: scratch) }
        let exports = scratch.appending(path: "Exports")
        let run = try await Self.run(
            Self.photos.map(\.path) + ["--to", exports.path, "--name", "Trip {sequence:2}", "--long-edge", "640"],
            in: scratch,
        )

        #expect(run.status == 0, "\(run.errors)")
        #expect(run.failures.isEmpty)
        let files = ["Trip 01.jpg", "Trip 02.jpg"].map { exports.appending(path: $0) }
        #expect(try FileManager.default.contentsOfDirectory(atPath: exports.path).sorted() == [
            "Trip 01.jpg",
            "Trip 02.jpg",
        ])
        #expect(run.output == [
            "\(Self.photos[0].path) → \(files[0].path)",
            "\(Self.photos[1].path) → \(files[1].path)",
            "Exported 2 photos to \(exports.path)",
        ])
        for file in files {
            let image = try Self.image(file)
            #expect(max(image.width, image.height) == 640)
        }
    }

    @Test func `--sharpen sharpens a reduced photo and asks for a size`() async throws {
        let scratch = try Self.scratch()
        defer { try? FileManager.default.removeItem(at: scratch) }
        let exports = scratch.appending(path: "Exports")
        let photo = Self.photos[0].path
        let plain = try await Self.run(
            [photo, "--to", exports.path, "--long-edge", "640", "--name", "plain"],
            in: scratch,
        )
        let sharp = try await Self.run(
            [photo, "--to", exports.path, "--long-edge", "640", "--name", "sharp", "--sharpen", "high"], in: scratch,
        )
        #expect(plain.status == 0 && sharp.status == 0, "\(plain.errors) \(sharp.errors)")
        let files = ["plain.jpg", "sharp.jpg"].map { exports.appending(path: $0) }
        let sizes = try files.map { try FileManager.default.attributesOfItem(atPath: $0.path)[.size] as? Int ?? 0 }
        #expect(sizes[1] > sizes[0], "a sharpened JPEG holds more detail: \(sizes)")

        let unsized = try await Self.run([photo, "--to", exports.path, "--sharpen", "standard"], in: scratch)
        #expect(unsized.status != 0)
        #expect(unsized.errors.contains { $0.contains("--sharpen") }, "\(unsized.errors)")
        let unknown = try await Self.run(
            [photo, "--to", exports.path, "--long-edge", "640", "--sharpen", "glossy"],
            in: scratch,
        )
        #expect(
            unknown.errors.contains { $0.contains("--sharpen takes off, low, standard, high") },
            "\(unknown.errors)",
        )
    }

    @Test func `each photo exports with its own edit, and a folder gives its photos in name order`() async throws {
        let scratch = try Self.scratch()
        defer { try? FileManager.default.removeItem(at: scratch) }
        let folder = scratch.appending(path: "Photos")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let plain = folder.appending(path: "IMG_1.dng"), edited = folder.appending(path: "IMG_2.dng")
        try FileManager.default.copyItem(at: Self.photos[1], to: edited)
        try FileManager.default.copyItem(at: Self.photos[1], to: plain)
        var recipe = EditRecipe()
        recipe.treatment = .blackAndWhite
        try SidecarStore().save(Sidecar(recipe: recipe), for: edited)
        let exports = scratch.appending(path: "Exports")
        let run = try await Self.run([folder.path, "--to", exports.path, "--long-edge", "256"], in: scratch)

        #expect(run.status == 0, "\(run.errors)")
        let files = ["IMG_1-redlamp.jpg", "IMG_2-redlamp.jpg"].map { exports.appending(path: $0) }
        #expect(run.output == [
            "\(plain.path) → \(files[0].path)",
            "\(edited.path) → \(files[1].path)",
            "Exported 2 photos to \(exports.path)",
        ])
        #expect(try Self.spread(Self.image(files[0])) > 20, "the photo without an edit is in colour")
        #expect(try Self.spread(Self.image(files[1])) <= 3, "the photo whose edit is black and white is")
    }

    @Test func `a photo that isn't there or doesn't open fails with why, and the others export`() async throws {
        let scratch = try Self.scratch()
        defer { try? FileManager.default.removeItem(at: scratch) }
        let missing = scratch.appending(path: "IMG_0001.ARW")
        let damaged = scratch.appending(path: "IMG_0002.ARW")
        try Data("Not a raw file.".utf8).write(to: damaged)
        let exports = scratch.appending(path: "Exports")
        let run = try await Self.run(
            [missing.path, damaged.path, Self.photos[1].path]
                + ["--to", exports.path, "--name", "Trip {sequence:2}", "--long-edge", "320"],
            in: scratch,
        )

        #expect(run.status == 1, "\(run.errors)")
        #expect(try FileManager.default.contentsOfDirectory(atPath: exports.path) == ["Trip 02.jpg"])
        #expect(run.failures.count == 2)
        #expect(run.failures.first == "\(missing.path): There's no file or folder there.")
        #expect(run.failures.last?.hasPrefix("\(damaged.path): ") == true)
        #expect(run.output == [
            "\(Self.photos[1].path) → \(exports.appending(path: "Trip 02.jpg").path)",
            "Exported 1 of 3 photos to \(exports.path)",
        ])
        _ = try Self.image(exports.appending(path: "Trip 02.jpg"))
    }
}
