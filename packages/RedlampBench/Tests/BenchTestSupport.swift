import CoreGraphics
import Foundation
import ImageIO
import RedlampBench
import RedlampRecipes
import simd
import UniformTypeIdentifiers

/// A scratch folder for one test, removed when the test's value goes away.
final class Scratch {
    let url = FileManager.default.temporaryDirectory.appending(path: "bench-tests-\(UUID().uuidString)")

    init() {
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }

    deinit {
        try? FileManager.default.removeItem(at: url)
    }

    func file(_ name: String) -> URL {
        url.appending(path: name)
    }
}

/// Synthetic photos: each seed draws its own arrangement of shapes, so their structures differ
/// the way different photos' do.
enum TestImages {
    static func photo(seed: UInt64, width: Int = 900, height: Int = 600) -> PixelImage {
        var generator = SeededGenerator(seed: seed)
        var pixels = [SIMD3<Float>](repeating: SIMD3(0.45, 0.45, 0.45), count: width * height)
        for _ in 0 ..< 14 {
            let cx = Float.random(in: 0 ..< Float(width), using: &generator)
            let cy = Float.random(in: 0 ..< Float(height), using: &generator)
            let r = Float.random(in: 30 ..< 160, using: &generator)
            let colour = SIMD3<Float>(
                .random(in: 0.05 ... 0.95, using: &generator),
                .random(in: 0.05 ... 0.95, using: &generator),
                .random(in: 0.05 ... 0.95, using: &generator),
            )
            let square = Bool.random(using: &generator)
            for y in max(0, Int(cy - r)) ..< min(height, Int(cy + r)) {
                for x in max(0, Int(cx - r)) ..< min(width, Int(cx + r)) {
                    let dx = Float(x) - cx, dy = Float(y) - cy
                    if square || dx * dx + dy * dy < r * r {
                        pixels[y * width + x] = colour
                    }
                }
            }
        }
        return PixelImage(width: width, height: height, pixels: pixels)
    }

    /// What a filter app might do: a warm, contrasty curve.
    static func filtered(_ image: PixelImage) -> PixelImage {
        PixelImage(width: image.width, height: image.height, pixels: image.pixels.map { p in
            let warm = p * SIMD3(1.08, 1.0, 0.86)
            return simd_clamp(warm * warm * (3 - 2 * warm), .zero, SIMD3(repeating: 1))
        })
    }

    /// A local exposure change, as a mask with a strong adjustment leaves.
    static func darkenedLeft(_ image: PixelImage) -> PixelImage {
        var pixels = image.pixels
        for y in 0 ..< image.height {
            for x in 0 ..< image.width / 3 {
                pixels[y * image.width + x] *= 0.25
            }
        }
        return PixelImage(width: image.width, height: image.height, pixels: pixels)
    }

    static func resized(_ image: PixelImage, longEdge: Int) -> PixelImage {
        guard let cg = image.cgImage(), let small = PixelImage(cg, maxLongEdge: longEdge) else { return image }
        return small
    }

    @discardableResult
    static func write(_ image: PixelImage, to url: URL, jpeg: Bool = false) throws -> URL {
        guard let cg = CaptureChart.cgImage8(image),
              let destination = CGImageDestinationCreateWithURL(
                  url as CFURL, (jpeg ? UTType.jpeg : UTType.png).identifier as CFString, 1, nil,
              ) else { throw CocoaError(.fileWriteUnknown) }
        let options: [CFString: Any] = jpeg ? [kCGImageDestinationLossyCompressionQuality: 0.7] : [:]
        CGImageDestinationAddImage(destination, cg, options as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { throw CocoaError(.fileWriteUnknown) }
        return url
    }
}

/// A task with three photo assets, in the store's outbox or a scratch folder.
@discardableResult
func makeTask(
    in scratch: Scratch,
    store: BenchStore? = nil,
    id: String = "2026-10-08-sky-masks",
) throws -> BenchFolder {
    let sources = try (1 ... 3).map { n in
        try TestImages.write(TestImages.photo(seed: UInt64(n)), to: scratch.file("photo-\(n).png"))
    }
    let manifest = BenchManifest(
        id: id, title: "Sky masks in Lightroom", kind: BenchManifest.Kind.lightroomCheck,
        requestedBy: .init(workstream: "masking", tracker: "DEC-08"), app: "Lightroom mobile",
        steps: [
            .init(id: "share", title: "Share the photos to Lightroom", action: .share(assets: nil)),
            .init(id: "mask", title: "Select Sky", detail: "Masking › Select Sky, then Exposure −4.00 inside it."),
            .init(id: "back", title: "Share the exports back", action: .results(assets: nil)),
        ],
    )
    let assets = sources.map { BenchFolder.NewAsset(file: $0) }
    if let store {
        return try store.create(manifest, assets: assets)
    }
    let parent = scratch.file("tasks")
    try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
    return try BenchFolder.create(manifest, assets: assets, in: parent)
}
