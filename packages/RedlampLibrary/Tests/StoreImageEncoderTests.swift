import CoreGraphics
import Foundation
import ImageIO
import RedlampDocument
import Synchronization
import Testing
@testable import RedlampLibrary

/// The store's images are each tier's size, upright, in JPEG or HEIC. With
/// `REDLAMP_STORE_CODEC_BENCH=1` (from `TEST_RUNNER_REDLAMP_STORE_CODEC_BENCH=1`), both codecs are
/// measured on the CC0 raws' previews, at each tier's default quality or at each of
/// `REDLAMP_STORE_CODEC_QUALITIES` (comma-separated, 0 to 1).
struct StoreImageEncoderTests {
    /// A dark `width` by `height` image with a white quarter-size block in its top left corner.
    static func marked(_ width: Int, _ height: Int) -> CGImage {
        let context = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue,
        )!
        context.setFillColor(red: 0.1, green: 0.1, blue: 0.1, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        context.setFillColor(red: 1, green: 1, blue: 1, alpha: 1)
        context.fill(CGRect(x: 0, y: height - height / 4, width: width / 4, height: height / 4))
        return context.makeImage()!
    }

    /// How bright the image is near each corner, as it's seen: top left, top right, bottom left,
    /// bottom right.
    static func corners(_ image: CGImage) -> [Double] {
        let (width, height) = (image.width, image.height)
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        pixels.withUnsafeMutableBytes { buffer in
            let context = CGContext(
                data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue,
            )!
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        }
        let (left, right, top, bottom) = (width / 16, width - 1 - width / 16, height / 16, height - 1 - height / 16)
        return [(left, top), (right, top), (left, bottom), (right, bottom)].map { x, y in
            Double(pixels[(y * width + x) * 4]) / 255
        }
    }

    @Test func `a size fits a tier's long edge, its short edge rounded, and is never enlarged`() {
        let fits = { (width: Int, height: Int, edge: Int) in
            let size = StoreImageEncoder.size(fitting: width, height, in: edge)
            return [size.width, size.height]
        }
        #expect(fits(6000, 4000, 384) == [384, 256])
        #expect(fits(4000, 6000, 384) == [256, 384])
        #expect(fits(3000, 2000, 2048) == [2048, 1365])
        #expect(fits(5000, 7, 384) == [384, 1])
        #expect(fits(300, 200, 384) == [300, 200])
        #expect(fits(384, 384, 384) == [384, 384])
    }

    @Test(arguments: StoreImageEncoder.Codec.allCases)
    func `each tier is encoded at its size and upright`(codec: StoreImageEncoder.Codec) throws {
        let encoder = StoreImageEncoder(codec: codec)
        for (width, height) in [(3000, 2000), (2000, 3000), (300, 200)] {
            let image = Self.marked(width, height)
            for tier in PhotoStore.Tier.allCases {
                let data = try #require(encoder.encode(image, for: tier), "\(codec) \(tier)")
                let source = try #require(CGImageSourceCreateWithData(data as CFData, nil))
                #expect((CGImageSourceGetType(source) as String?) == codec.type.identifier)
                let decoded = try #require(StoreImageEncoder.decode(data))
                let expected = StoreImageEncoder.size(fitting: width, height, in: tier.pixelSize)
                #expect(decoded.width == expected.width && decoded.height == expected.height, "\(codec) \(tier)")
                let corners = Self.corners(decoded)
                #expect(corners[0] > 0.8 && corners.dropFirst().allSatisfy { $0 < 0.3 }, "\(codec) \(tier): \(corners)")
            }
        }
    }

    @Test func `each tier has its own quality unless one is given`() throws {
        #expect(StoreImageEncoder.defaultQuality(for: .grid) == 0.5)
        #expect(StoreImageEncoder.defaultQuality(for: .preview) == 0.6)
        let image = Self.marked(3000, 2000)
        for tier in PhotoStore.Tier.allCases {
            let byDefault = try #require(StoreImageEncoder().encode(image, for: tier))
            let given = StoreImageEncoder(quality: StoreImageEncoder.defaultQuality(for: tier))
            let other = StoreImageEncoder(quality: 0.9)
            #expect(byDefault == given.encode(image, for: tier), "\(tier)")
            #expect(byDefault != other.encode(image, for: tier), "\(tier)")
        }
    }

    // MARK: - Measuring the codecs

    private struct Measurement {
        var encode: [Double] = []
        var decode: [Double] = []
        var bytes: [Int] = []
    }

    private static func milliseconds(_ body: () -> Void) -> Double {
        let clock = ContinuousClock()
        let start = clock.now
        body()
        return (clock.now - start) / .milliseconds(1)
    }

    private static func median(_ values: [Double]) -> Double {
        let sorted = values.sorted()
        return sorted.isEmpty ? 0 : sorted[sorted.count / 2]
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["REDLAMP_STORE_CODEC_BENCH"] == "1"))
    func `JPEG and HEIC at both tiers, on the CC0 raws' previews`() throws {
        let raws = PhotoMetadataReaderTests.raws
        try #require(!raws.isEmpty)
        let qualities: [Double?] = ProcessInfo.processInfo.environment["REDLAMP_STORE_CODEC_QUALITIES"]
            .map { $0.split(separator: ",").compactMap { Double($0.trimmingCharacters(in: .whitespaces)) } }
            ?? [nil]
        for tier in PhotoStore.Tier.allCases {
            var sources: [CGImage] = []
            var thumbnails: [Double] = []
            for raw in raws {
                var image: CGImage?
                thumbnails.append(Self.milliseconds { image = StoreThumbnailMaker.imageIO(raw, nil, tier.pixelSize) })
                if let image {
                    sources.append(image)
                    print("STORE-CODEC \(tier) \(raw.lastPathComponent): \(image.width) x \(image.height)")
                } else {
                    print("STORE-CODEC \(tier) \(raw.lastPathComponent): ImageIO made no thumbnail")
                }
            }
            print(String(
                format: "STORE-CODEC %@: %ld previews, made by ImageIO from the raws in a median %.1f ms (max %.1f)",
                "\(tier)", sources.count, Self.median(thumbnails), thumbnails.max() ?? 0,
            ))
            for codec in StoreImageEncoder.Codec.allCases {
                for quality in qualities {
                    try measure(
                        StoreImageEncoder(codec: codec, quality: quality), tier: tier, sources: sources,
                        label: quality.map { "\(codec.rawValue) at \($0)" } ?? codec.rawValue,
                    )
                }
            }
        }
    }

    private func measure(
        _ encoder: StoreImageEncoder, tier: PhotoStore.Tier, sources: [CGImage], label: String,
    ) throws {
        var measured = Measurement()
        var payloads: [Data] = []
        for source in sources {
            var data: Data?
            measured.encode.append(Self.median((0 ..< 3).map { _ in
                Self.milliseconds { data = encoder.encode(source, for: tier) }
            }))
            let payload = try #require(data)
            payloads.append(payload)
            measured.bytes.append(payload.count)
            measured.decode.append(Self.median((0 ..< 5).map { _ in
                Self.milliseconds { _ = StoreImageEncoder.decode(payload) }
            }))
        }
        let decodes = Atomic(0)
        let rounds = tier == .grid ? 40 : 4
        let encoded = payloads
        let parallel = Self.milliseconds {
            DispatchQueue.concurrentPerform(iterations: CoreCounts.performance) { worker in
                for round in 0 ..< rounds {
                    _ = StoreImageEncoder.decode(encoded[(worker + round) % encoded.count])
                    decodes.add(1, ordering: .relaxed)
                }
            }
        }
        let bytes = measured.bytes.sorted()
        print(String(
            format: "STORE-CODEC %@ %@: encode median %.2f ms (max %.2f), decode median %.2f ms (max %.2f), "
                + "%.0f decodes/s on %ld cores, size median %.1f KB (mean %.1f, max %.1f)",
            "\(tier)", label, Self.median(measured.encode), measured.encode.max() ?? 0,
            Self.median(measured.decode), measured.decode.max() ?? 0,
            Double(decodes.load(ordering: .relaxed)) / (parallel / 1000), CoreCounts.performance,
            Double(bytes[bytes.count / 2]) / 1024,
            Double(bytes.reduce(0, +)) / Double(bytes.count) / 1024, Double(bytes.last ?? 0) / 1024,
        ))
    }
}
