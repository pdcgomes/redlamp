import Foundation
import RedlampEngineAPI
import Testing
@testable import RedlampEngine

/// Auto Settings (`ImageAnalysis.autoTone`): the exposure the midtones ask for, held back where
/// Highlights couldn't keep the brightest tones from clipping (#325).
struct AutoToneTests {
    /// A shaded foreground under a blue sky, whose blue channel is twice its luminance.
    @Test func `a sky the midtones would push past white keeps its detail`() throws {
        let values = ImageAnalysis.autoTone(
            luminances: Array(repeating: 0.03, count: 85) + Array(repeating: 0.4, count: 15),
            peaks: Array(repeating: 0.04, count: 85) + Array(repeating: 0.8, count: 15),
        )
        let exposure = try #require(values[.exposure])
        let highlights = try #require(values[.highlights])
        // The midtones alone ask for +1.48 EV, which takes the sky's blue to 2.2: past white.
        #expect(exposure < 1.48)
        #expect(highlights == -80)
        let blue = 0.8 * pow(2, exposure + 1.25 * highlights / 100)
        #expect(blue <= 1.01, "the sky's blue reaches \(blue)")
    }

    @Test func `lights in a dark scene don't keep it dark`() throws {
        let values = ImageAnalysis.autoTone(
            luminances: Array(repeating: 0.004, count: 98) + Array(repeating: 3, count: 2),
            peaks: Array(repeating: 0.005, count: 98) + Array(repeating: 4, count: 2),
        )
        // The midtones ask for the most Auto gives, +3 EV; the lights take 1 EV of it back.
        #expect(try #require(values[.exposure]) == 2)
    }

    @Test func `with nothing bright the exposure is the midtones' own`() throws {
        let values = ImageAnalysis.autoTone(
            luminances: Array(repeating: 0.05, count: 100),
            peaks: Array(repeating: 0.07, count: 100),
        )
        #expect(try #require(values[.exposure]) == 1.34)
        #expect(try #require(values[.highlights]) == 0)
    }

    /// The samples' skies clipped after Auto: the X-T5 (the X-T50's sensor, as in #325) 1.6% of
    /// the photo, the Z 8 9.8%, where the camera's exposure clipped none.
    static let skies = ["Fujifilm_X-T5.RAF", "Nikon_Z-8.NEF"]
        .map { CameraGoldenTests.root.appending(path: "tests/fixtures/cameras/\($0)") }
        .filter { FileManager.default.fileExists(atPath: $0.path) }

    @Test(.enabled(if: EngineSmokeTests.canRender && !skies.isEmpty), .serialized, arguments: skies)
    func `Auto Settings doesn't blow out a bright sky`(sample: URL) async throws {
        let engine = try RedlampEngine()
        _ = try await engine.open(sample)
        var auto = EditRecipe()
        for (parameter, value) in await engine.autoTone(for: auto) {
            auto[parameter] = value
        }
        let before = try await Self.clippedShare(engine, EditRecipe())
        let after = try await Self.clippedShare(engine, auto)
        #expect(
            after <= before + 0.001,
            "\(sample.lastPathComponent): \(after * 100)% clipped, \(before * 100)% before",
        )
    }

    /// The share of the photo the clipping warning marks: a channel at 0.998 or more, in Display P3.
    static func clippedShare(_ engine: RedlampEngine, _ recipe: EditRecipe) async throws -> Double {
        let image = try await engine.renderStill(StillRequest(
            recipe: recipe, maxLongEdge: 512, colorSpace: .displayP3, bitsPerComponent: 16,
        ))
        let data = try #require(image.dataProvider?.data as Data?)
        let count = image.width * image.height
        let clipped = data.withUnsafeBytes { bytes in
            let channels = bytes.assumingMemoryBound(to: UInt16.self)
            return (0 ..< count).count { index in
                max(channels[index * 4], channels[index * 4 + 1], channels[index * 4 + 2]) >= UInt16(0.998 * 65535)
            }
        }
        return Double(clipped) / Double(count)
    }
}
