import CoreGraphics
import Foundation
import Metal
import RedlampEngineAPI
import RedlampServices
import simd
import Testing
@testable import RedlampEngine

/// Camera profiles' looks baked into Base Looks (TON-09).
struct EmbeddedLookTests {
    static let canRender = MTLCreateSystemDefaultDevice() != nil

    static func fixture(_ prefix: String) -> URL? {
        EngineSmokeTests.fixtures.first { $0.lastPathComponent.hasPrefix(prefix) }
    }

    static func profile(curve: [SIMD2<Float>]?, lookTable: DNGProfile.HSVMap? = nil) -> DNGProfile {
        DNGProfile(
            name: "Test", copyright: nil, embedPolicy: 0, cameraModel: nil, hueSatMaps: [], lookTable: lookTable,
            toneCurve: curve, baselineExposureOffset: 0,
        )
    }

    static func srgbEncode(_ x: Float) -> Float {
        x <= 0.0031308 ? 12.92 * x : 1.055 * pow(x, 1 / 2.4) - 0.055
    }

    @Test func `the spline passes through its points and is the identity on a straight line`() {
        let line = ToneSpline([SIMD2(0, 0), SIMD2(0.5, 0.5), SIMD2(1, 1)])
        for x: Float in [0, 0.1, 0.33, 0.5, 0.9, 1] {
            #expect(abs(line.evaluate(x) - x) < 1e-6)
        }
        let points: [SIMD2<Float>] = [SIMD2(0, 0), SIMD2(0.2, 0.3), SIMD2(0.5, 0.65), SIMD2(1, 1)]
        let curve = ToneSpline(points)
        for point in points {
            #expect(abs(curve.evaluate(point.x) - point.y) < 1e-6)
        }
        let samples = stride(from: Float(0), through: 1, by: 0.01).map(curve.evaluate)
        #expect(zip(samples, samples.dropFirst()).allSatisfy { $0 <= $1 }, "a rising curve stays monotonic")
    }

    @Test func `the RGB tone method keeps the middle channel's place between the others`() {
        let curve = ToneSpline([SIMD2(0, 0), SIMD2(0.25, 0.5), SIMD2(1, 1)])
        let color = SIMD3<Float>(0.4, 0.1, 0.2)
        let toned = curve.rgbTone(color)
        #expect(abs(toned.x - curve.evaluate(0.4)) < 1e-6 && abs(toned.y - curve.evaluate(0.1)) < 1e-6)
        #expect(abs((toned.z - toned.y) / (toned.x - toned.y) - (0.2 - 0.1) / (0.4 - 0.1)) < 1e-5)
        let grey = curve.rgbTone(SIMD3(repeating: 0.3))
        #expect(abs(grey.x - curve.evaluate(0.3)) < 1e-6 && grey.x == grey.y && grey.y == grey.z)
    }

    @Test func `a tone curve alone bakes to that curve on greys`() throws {
        let points = (0 ... 16).map { i in SIMD2(Float(i) / 16, (Float(i) / 16).squareRoot()) }
        let look = try #require(EmbeddedLook.definition(for: Self.profile(curve: points)))
        let table = try #require(look.table)
        #expect(table.space == .sceneLog && look.reference.isEmbedded)
        let curve = ToneSpline(points)
        let size = table.size
        for i in stride(from: 0, to: size, by: 4) {
            let encoded = Float(i) / Float(size - 1)
            let scene = SceneLogEncoding.decode(encoded)
            let index = ((i * size + i) * size + i) * 3
            let baked = SIMD3(
                Float(table.values[index]),
                Float(table.values[index + 1]),
                Float(table.values[index + 2]),
            )
            let expected = Self.srgbEncode(curve.evaluate(min(scene, 1)))
            #expect(abs(baked - SIMD3(repeating: expected)).max() < 4e-3, "grey \(scene): \(baked) vs \(expected)")
        }
    }

    @Test func `the same profile bakes to the same look, and an empty one to none`() throws {
        let points: [SIMD2<Float>] = [SIMD2(0, 0), SIMD2(0.5, 0.6), SIMD2(1, 1)]
        let a = try #require(EmbeddedLook.definition(for: Self.profile(curve: points)))
        let b = try #require(EmbeddedLook.definition(for: Self.profile(curve: points)))
        #expect(a.reference == b.reference)
        #expect(EmbeddedLook.definition(for: Self.profile(curve: nil)) == nil)
    }

    @Test(.enabled(if: canRender && fixture("PXL_") != nil))
    func `the Pixel opens with its Adobe Standard look on offer, which renders and mixes`() async throws {
        let url = try #require(Self.fixture("PXL_"))
        let engine = try RedlampEngine()
        let info = try await engine.open(url)
        let embedded = try #require(info.embeddedBaseLook)
        #expect(embedded.name == "Adobe Standard" && embedded.isEmbedded)
        #expect(engine.canRender(embedded))
        #expect(engine.embeddedBaseLook()?.reference == embedded)

        let request = { (recipe: EditRecipe) in StillRequest(recipe: recipe, maxLongEdge: 400) }
        let plain = try await engine.renderStill(request(EditRecipe()))
        var recipe = EditRecipe()
        recipe.baseLook = embedded
        let looked = try await engine.renderStill(request(recipe))
        #expect(BaseLookTests.maxDifference(plain, looked) > 10, "the look should show")
        recipe.baseLook = embedded.withAmount(0)
        let off = try await engine.renderStill(request(recipe))
        #expect(BaseLookTests.maxDifference(plain, off) <= 2, "Amount 0 is no look")
    }

    /// ProRAW's tone curve follows its gain table map, so its look is offered for process 5 edits.
    @Test(.enabled(if: canRender && fixture("IMG_1361") != nil))
    func `an iPhone's tone curve becomes its embedded look, for edits that apply the gain table map`() async throws {
        let url = try #require(Self.fixture("IMG_1361"))
        let engine = try RedlampEngine()
        let info = try await engine.open(url)
        let embedded = try #require(info.embeddedBaseLook)
        #expect(embedded.name == "Apple Embedded Color Profile" && engine.canRender(embedded))
        #expect(info.embeddedBaseLookProcess == 5)
    }
}
