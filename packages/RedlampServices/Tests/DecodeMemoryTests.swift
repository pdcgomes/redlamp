import CoreGraphics
import Darwin
import Foundation
import ImageIO
import RedlampEngineAPI
import Synchronization
import Testing
import UniformTypeIdentifiers
@testable import RedlampServices

/// A decode holds the samples it hands over and what it decodes from, not copies of them: each
/// copy of a large photo's samples is hundreds of megabytes.
@Suite(.serialized)
struct DecodeMemoryTests {
    final class Sampler: Sendable {
        let state: Mutex<(peak: Int, running: Bool)>

        init(from start: Int) {
            state = Mutex((start, true))
        }
    }

    /// The heap's allocations.
    private static func heap() -> Int {
        var stats = malloc_statistics_t()
        malloc_zone_statistics(nil, &stats)
        return Int(stats.size_in_use)
    }

    /// What macOS charges the process for, which includes the bitmaps CoreGraphics allocates
    /// outside the heap.
    private static func footprint() -> Int {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        return result == KERN_SUCCESS ? Int(info.phys_footprint) : 0
    }

    /// The most `measure` rose above its level before `body`, in bytes: the least of a few runs, so
    /// what other tests allocate meanwhile doesn't count.
    private static func peak(
        of measure: @escaping @Sendable () -> Int, _ body: () throws -> Void,
    ) rethrows -> Int {
        var least = Int.max
        for _ in 0 ..< 3 {
            let start = measure()
            let sampler = Sampler(from: start)
            Thread.detachNewThread {
                while sampler.state.withLock({ $0.running }) {
                    let now = measure()
                    sampler.state.withLock { $0.peak = max($0.peak, now) }
                    usleep(200)
                }
            }
            try body()
            let peak = sampler.state.withLock { $0.running = false; return $0.peak }
            least = min(least, max(peak, measure()) - start)
        }
        return least
    }

    @Test func `unarchiving copies the samples once, straight from the reply`() throws {
        let (width, height) = (4000, 3000)
        let image = DecodedImage(
            width: width, height: height, layout: .linearSRGBHalf,
            samples: [UInt16](repeating: 0x3C00, count: width * height * 4), blackLevels: [0, 0, 0], whiteLevel: 1,
            asShotMultipliers: SIMD3(1, 1, 1), cameraToSRGB: [1, 0, 0, 0, 1, 0, 0, 0, 1], xyzToCamera: nil,
            orientation: 0, baselineExposure: 0,
            info: ImageInfo(
                url: URL(fileURLWithPath: "/large.png"), pixelSize: PixelSize(width: width, height: height),
                isRaw: false, sensorDescription: "PNG",
            ),
        )
        let archive = try image.archived()
        let bytes = image.samples.count * 2
        let held = try Self.peak(of: Self.heap) { _ = try DecodedImage(archive: archive) }
        withKnownIssue("the reply's body is copied before the samples are") {
            #expect(held < bytes * 3 / 2, "held \(held >> 20) MB for \(bytes >> 20) MB of samples")
        }
    }

    /// A grey JPEG, so the decoded file itself (a byte a pixel) is small beside the samples.
    @Test func `a bitmap is drawn straight into its samples`() throws {
        let (width, height) = (4000, 3000)
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).jpg")
        defer { try? FileManager.default.removeItem(at: url) }
        let space = try #require(CGColorSpace(name: CGColorSpace.genericGrayGamma2_2))
        let context = try #require(CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width, space: space,
            bitmapInfo: CGImageAlphaInfo.none.rawValue,
        ))
        context.setFillColor(gray: 0.6, alpha: 1)
        context.fillEllipse(in: CGRect(x: 500, y: 500, width: 2000, height: 1500))
        let picture = try #require(context.makeImage())
        let destination = try #require(CGImageDestinationCreateWithURL(
            url as CFURL, UTType.jpeg.identifier as CFString, 1, nil,
        ))
        CGImageDestinationAddImage(destination, picture, nil)
        #expect(CGImageDestinationFinalize(destination))
        let bytes = width * height * 8
        let held = try Self.peak(of: Self.footprint) { _ = try BitmapDecoder.decode(url) }
        withKnownIssue("the bitmap is drawn into a context, then copied") {
            #expect(held < bytes * 3 / 2, "held \(held >> 20) MB for \(bytes >> 20) MB of samples")
        }
    }
}
