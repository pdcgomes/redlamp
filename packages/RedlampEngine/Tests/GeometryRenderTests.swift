import Foundation
import IOSurface
import RedlampEngineAPI
import simd
import Testing
@testable import RedlampEngine

/// Crop, straighten and orientation in the renderer (LNS-05): one map from the developed frame
/// back to the photo, with masks staying on the photo's content.
struct GeometryRenderTests {
    static let sample = EngineSmokeTests.fixtures.first { $0.lastPathComponent == "DSC_0750.NEF" }
        ?? EngineSmokeTests.fixtures.first

    private struct Frame {
        var width: Int
        var height: Int
        var pixels: [SIMD3<Float>]

        func at(_ x: Int, _ y: Int) -> SIMD3<Float> {
            pixels[y * width + x]
        }

        /// Bilinear, at normalised coordinates.
        func sample(_ u: Double, _ v: Double) -> SIMD3<Float> {
            let fx = u * Double(width) - 0.5, fy = v * Double(height) - 0.5
            let x0 = min(max(Int(fx.rounded(.down)), 0), width - 2), y0 = min(
                max(Int(fy.rounded(.down)), 0),
                height - 2,
            )
            let tx = Float(fx - Double(x0)), ty = Float(fy - Double(y0))
            let top = at(x0, y0) * (1 - tx) + at(x0 + 1, y0) * tx
            let bottom = at(x0, y0 + 1) * (1 - tx) + at(x0 + 1, y0 + 1) * tx
            return top * (1 - ty) + bottom * ty
        }
    }

    private func render(_ engine: RedlampEngine, _ recipe: EditRecipe, longEdge: Int) throws -> Frame {
        let session = try #require(engine.currentSession())
        let frame = try engine.renderFrame(
            RenderRequest(recipe: recipe, targetSize: PixelSize(width: longEdge, height: longEdge)), session: session,
        )
        let surface = frame.surface
        IOSurfaceLock(surface, .readOnly, nil)
        defer { IOSurfaceUnlock(surface, .readOnly, nil) }
        let base = IOSurfaceGetBaseAddress(surface)
        let bytesPerRow = IOSurfaceGetBytesPerRow(surface)
        let pixels = (0 ..< frame.size.height).flatMap { y in
            let row = (base + y * bytesPerRow).assumingMemoryBound(to: Float16.self)
            return (0 ..< frame.size.width).map { x in
                SIMD3(Float(row[x * 4]), Float(row[x * 4 + 1]), Float(row[x * 4 + 2]))
            }
        }
        return Frame(width: frame.size.width, height: frame.size.height, pixels: pixels)
    }

    private func openEngine() async throws -> RedlampEngine {
        let engine = try RedlampEngine()
        _ = try await engine.open(#require(Self.sample))
        return engine
    }

    /// No spatial filters, so pixels compare exactly between frames of different extents.
    private var plain: EditRecipe {
        var recipe = EditRecipe()
        recipe[.sharpenAmount] = 0
        recipe[.noiseColor] = 0
        return recipe
    }

    @Test(.enabled(if: EngineSmokeTests.canRender))
    func `a crop renders that part of the photo`() async throws {
        let engine = try await openEngine()
        let full = try render(engine, plain, longEdge: 1200)
        var cropped = plain
        cropped.crop = CropRect(left: 0.25, top: 0.3, right: 0.75, bottom: 0.8)
        let part = try render(engine, cropped, longEdge: 600)
        #expect(abs(part.width - full.width / 2) <= 1 && abs(part.height - full.height / 2) <= 1)
        var total: Float = 0
        var count: Float = 0
        for y in stride(from: 2, to: part.height - 2, by: 5) {
            for x in stride(from: 2, to: part.width - 2, by: 5) {
                let u = 0.25 + (Double(x) + 0.5) / Double(part.width) * 0.5
                let v = 0.3 + (Double(y) + 0.5) / Double(part.height) * 0.5
                total += simd_abs(part.at(x, y) - full.sample(u, v)).max()
                count += 1
            }
        }
        #expect(total / count < 0.004, "mean difference \(total / count)")
    }

    @Test(.enabled(if: EngineSmokeTests.canRender))
    func `a quarter turn turns the frame`() async throws {
        let engine = try await openEngine()
        let upright = try render(engine, plain, longEdge: 900)
        var turned = plain
        turned.orientation = ImageOrientation().rotatedClockwise
        let side = try render(engine, turned, longEdge: 900)
        #expect(side.width == upright.height && side.height == upright.width)
        var worst: Float = 0
        for y in stride(from: 1, to: side.height - 1, by: 9) {
            for x in stride(from: 1, to: side.width - 1, by: 9) {
                // Turned clockwise: the output's (x, y) shows the upright frame's (y, height-1-x).
                worst = max(worst, simd_abs(side.at(x, y) - upright.at(y, upright.height - 1 - x)).max())
            }
        }
        #expect(worst < 0.02, "largest difference \(worst)")
    }

    @Test(.enabled(if: EngineSmokeTests.canRender))
    func `straightening leaves white corners unless constrained`() async throws {
        let engine = try await openEngine()
        var tilted = plain
        tilted[.cropAngle] = 12
        let loose = try render(engine, tilted, longEdge: 600)
        #expect(loose.at(0, 0).min() > 0.99 && loose.at(loose.width - 1, loose.height - 1).min() > 0.99)
        let session = try #require(engine.currentSession())
        tilted.crop = GeometryMap.constrained(
            .full, imageSize: session.orientedSize, orientation: .identity, angle: 12, transform: Transform(),
        )
        let tight = try render(engine, tilted, longEdge: 600)
        let corners = [tight.at(1, 1), tight.at(tight.width - 2, 1), tight.at(1, tight.height - 2)]
        #expect(corners.allSatisfy { $0.min() < 0.99 }, "\(corners)")
    }

    @Test(.enabled(if: EngineSmokeTests.canRender))
    func `a mask stays on the photo's content when the crop moves it`() async throws {
        let engine = try await openEngine()
        var recipe = plain
        var spot = MaskLayer(name: "Spot", components: [
            MaskComponent(shape: .radial(RadialMask(
                center: ImagePoint(x: 0.6, y: 0.55),
                radiusX: 0.05,
                radiusY: 0.05,
            ))),
        ])
        spot[.localExposure] = 2
        recipe.masks = [spot]
        recipe.crop = CropRect(left: 0.4, top: 0.3, right: 0.9, bottom: 0.8)
        let masked = try render(engine, recipe, longEdge: 600)
        recipe.masks = []
        let unmasked = try render(engine, recipe, longEdge: 600)
        // The spot's centre (0.6, 0.55) is at (0.4, 0.5) of this crop.
        let (x, y) = (Int(0.4 * Double(masked.width)), Int(0.5 * Double(masked.height)))
        let gain = masked.at(x, y).sum() / max(unmasked.at(x, y).sum(), 1e-4)
        #expect(gain > 1.5, "the spot brightens its own content: \(gain)")
        let far = masked.at(masked.width - 5, 5).sum() / max(unmasked.at(masked.width - 5, 5).sum(), 1e-4)
        #expect(abs(far - 1) < 0.02, "and nothing far from it: \(far)")
    }
}
