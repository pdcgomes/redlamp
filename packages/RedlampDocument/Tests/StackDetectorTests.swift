import Foundation
import RedlampEngineAPI
import Testing
@testable import RedlampDocument

struct StackDetectorTests {
    private let start = Date(timeIntervalSince1970: 1_800_000_000)

    private func frames(
        _ count: Int,
        every step: TimeInterval = 0.5,
        from offset: TimeInterval = 0,
        exposure: (Int) -> Double = { _ in 0.01 },
    ) -> [(URL, StackDetector.Capture)] {
        (0 ..< count).map { index in
            let capture = StackDetector.Capture(
                model: "Body", lens: "Macro", focalLength: 100, aperture: 4, iso: 200,
                exposureTime: exposure(index), date: start.addingTimeInterval(offset + Double(index) * step),
            )
            return (URL(fileURLWithPath: "/shoot/\(Int(offset))-\(index).raw"), capture)
        }
    }

    @Test func `runs follow identical settings and even timing`() {
        #expect(StackDetector.runs(frames(8)).map(\.count) == [8])
        // Two stacks a minute apart, then a pair too short to suggest.
        let two = frames(5) + frames(6, from: 60) + frames(2, from: 120)
        #expect(StackDetector.runs(two).map(\.count) == [5, 6])
        // An exposure bracket changes the shutter speed every frame.
        #expect(StackDetector.runs(frames(9) { [0.01, 0.04, 0.0025][$0 % 3] }).isEmpty)
        // A pause much longer than the rhythm so far starts a new run.
        let paused = frames(4, every: 0.5) + frames(4, every: 0.5, from: 10)
        #expect(StackDetector.runs(paused).map(\.count) == [4, 4])
    }

    @Test func `a suggestion is saved beside its frames under a free name`() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let frames = (1 ... 4).map { folder.appendingPathComponent("IMG_010\($0).CR3") }
        let suggestion = StackSuggestion(frames: frames)
        let url = suggestion.documentURL()
        #expect(url.lastPathComponent == "IMG_0101-IMG_0104.redlampstack")
        try suggestion.save(to: url)
        #expect(suggestion.documentURL().lastPathComponent == "IMG_0101-IMG_0104 2.redlampstack")
        let document = try FocusStackDocument.read(url)
        #expect(document.frames == frames.map(\.lastPathComponent))
    }

    @Test func `the focus signature separates a focus sweep from bursts and pans`() {
        let (width, height) = (192, 128)
        let texture = Self.texture(width: width + 64, height: height)
        // Focus moves from left to right: in frame i, columns near i / 4 of the width are sharp.
        let sweep = (0 ..< 5).map { frame in
            Self.blurred(texture, width: width + 64, height: height, crop: width) { x in
                abs(Float(x) / Float(width) - Float(frame) / 4) * 12
            }
        }
        #expect(StackDetector.isFocusSweep(sweep))
        let burst = (0 ..< 5).map { _ in
            Self.blurred(texture, width: width + 64, height: height, crop: width) { _ in 1 }
        }
        #expect(!StackDetector.isFocusSweep(burst))
        let pan = (0 ..< 5).map { frame in
            Self.blurred(texture, width: width + 64, height: height, crop: width, offset: frame * 16) { x in
                abs(Float(x) / Float(width) - Float(frame) / 4) * 12
            }
        }
        #expect(!StackDetector.isFocusSweep(pan))
    }

    @Test func `the focus signature stops at the first frame that doesn't match`() {
        let (width, height) = (192, 128)
        let texture = Self.texture(width: width + 64, height: height)
        let frame = Self.blurred(texture, width: width + 64, height: height, crop: width) { _ in 1 }
        let flat = StackDetector.Thumbnail(
            width: width, height: height, pixels: [Float](repeating: 0.5, count: width * height),
        )
        var sweep = StackDetector.FocusSweep()
        let added = [frame, frame, flat, frame].map { sweep.add($0) }
        #expect(added == [true, true, false, false], "another scene, and the run stays rejected")
        #expect(!sweep.isFocusSweep)

        var sizes = StackDetector.FocusSweep()
        let small = StackDetector.Thumbnail(width: 2, height: 2, pixels: [0, 1, 1, 0])
        let sized = [frame, small].map { sizes.add($0) }
        #expect(sized == [true, false], "another size")
    }

    /// Answers from tables, recording each batch it is asked for.
    final class RecordedFiles: FileInspecting, @unchecked Sendable {
        let captures: [URL: StackDetector.Capture]
        let thumbnails: [URL: StackDetector.Thumbnail]
        private let lock = NSLock()
        private var asked: [(thumbnails: Bool, urls: [URL])] = []

        init(captures: [URL: StackDetector.Capture], thumbnails: [URL: StackDetector.Thumbnail]) {
            self.captures = captures
            self.thumbnails = thumbnails
        }

        var calls: [(thumbnails: Bool, urls: [URL])] {
            lock.withLock { asked }
        }

        func captures(of urls: [URL], concurrently _: Bool) -> [CaptureSettings?] {
            lock.withLock { asked.append((false, urls)) }
            return urls.map { captures[$0] }
        }

        func focusThumbnails(of urls: [URL], concurrently _: Bool) -> [GreyThumbnail?] {
            lock.withLock { asked.append((true, urls)) }
            return urls.map { thumbnails[$0] }
        }

        func imageProperties(of urls: [URL]) -> [ImageProperties?] {
            urls.map { _ in nil }
        }
    }

    @Test(arguments: [false, true])
    func `a folder's captures are read in one call, and thumbnails only for its candidate runs`(
        concurrently: Bool,
    ) {
        let (width, height) = (192, 128)
        let texture = Self.texture(width: width + 64, height: height)
        let run = frames(5)
        let others = [
            (URL(fileURLWithPath: "/shoot/9-a.raw"), StackDetector.Capture(model: "Other", date: start)),
            (URL(fileURLWithPath: "/shoot/9-b.raw"), StackDetector.Capture(model: "Body")),
        ]
        let thumbnails = Dictionary(uniqueKeysWithValues: run.enumerated().map { frame, photo in
            (photo.0, Self.blurred(texture, width: width + 64, height: height, crop: width) { x in
                abs(Float(x) / Float(width) - Float(frame) / 4) * 12
            })
        })
        let files = RecordedFiles(
            captures: Dictionary(uniqueKeysWithValues: run + others), thumbnails: thumbnails,
        )
        let urls = (run + others).map(\.0)

        let found = StackDetector.suggestions(in: urls, reading: files, concurrently: concurrently)
        #expect(found == [StackSuggestion(frames: run.map(\.0))])
        #expect(files.calls.filter { !$0.thumbnails }.map(\.urls) == [urls], "every capture in one call")
        #expect(files.calls.filter(\.thumbnails).flatMap(\.urls) == run.map(\.0), "the run's frames, once each")
    }

    /// Deterministic blobs and fine texture.
    static func texture(width: Int, height: Int) -> [Float] {
        var state: UInt64 = 7
        func next() -> Float {
            state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            return Float(state >> 40) / Float(1 << 24)
        }
        let blobs = (0 ..< 40)
            .map { _ in (next() * Float(width), next() * Float(height), 4 + 20 * next(), next() - 0.4) }
        return (0 ..< width * height).map { index in
            let (x, y) = (Float(index % width), Float(index / width))
            var value = 0.5 + 0.15 * sin(1.7 * x + 0.9 * y) * cos(1.1 * y - 0.6 * x)
            for (bx, by, sigma, amplitude) in blobs {
                value += amplitude * exp(-((x - bx) * (x - bx) + (y - by) * (y - by)) / (2 * sigma * sigma))
            }
            return min(max(value, 0), 1)
        }
    }

    /// A `crop`-wide window of `image` starting at `offset`, box-blurred by a radius that
    /// depends on the column.
    static func blurred(
        _ image: [Float], width: Int, height: Int, crop: Int, offset: Int = 0, radius: (Int) -> Float,
    ) -> StackDetector.Thumbnail {
        // Separable: the radius depends only on the column.
        let radii = (0 ..< crop).map { Int(radius($0).rounded()) }
        var rows = [Float](repeating: 0, count: crop * height)
        for y in 0 ..< height {
            for x in 0 ..< crop {
                let r = radii[x]
                var sum: Float = 0
                for dx in -r ... r {
                    sum += image[y * width + min(max(x + offset + dx, 0), width - 1)]
                }
                rows[y * crop + x] = sum / Float(2 * r + 1)
            }
        }
        var pixels = rows
        for y in 0 ..< height {
            for x in 0 ..< crop {
                let r = radii[x]
                var sum: Float = 0
                for dy in -r ... r {
                    sum += rows[min(max(y + dy, 0), height - 1) * crop + x]
                }
                pixels[y * crop + x] = sum / Float(2 * r + 1)
            }
        }
        return StackDetector.Thumbnail(width: crop, height: height, pixels: pixels)
    }
}
