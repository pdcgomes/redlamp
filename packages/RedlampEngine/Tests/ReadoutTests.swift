import Foundation
import IOSurface
import RedlampEngineAPI
import simd
import Testing
@testable import RedlampEngine

/// The histogram's readout (UX-32): what the canvas shows under the pointer, without its overlays.
struct ReadoutTests {
    let detail: DetailStageTests
    let size = 128

    init() throws {
        detail = try DetailStageTests()
    }

    /// Left: photosites at the clip level. Right: a ramp from dark to bright, top to bottom.
    private func session() throws -> ImageSession {
        let size = size
        return try detail.makeSession(.bayer, width: size, height: size, noiseScale: 0) { x, y in
            x < size / 4 ? 1 : 0.01 + 0.4 * Float(y) / Float(size)
        }
    }

    /// The readout of the 5 × 5 frame pixels whose top-left one is (`x`, `y`).
    private func expected(_ frame: [SIMD3<Float>], x: Int, y: Int) -> PixelReadout {
        var sum = SIMD3<Double>.zero
        for dy in 0 ..< 5 {
            for dx in 0 ..< 5 {
                sum += SIMD3<Double>(frame[(y + dy) * size + x + dx])
            }
        }
        return RedlampEngine.readout(linearDisplayP3: sum / 25)
    }

    private func point(x: Int, y: Int) -> CGPoint {
        CGPoint(x: (Double(x) + 2.5) / Double(size), y: (Double(y) + 2.5) / Double(size))
    }

    private var area: CGSize {
        CGSize(width: 5 / Double(size), height: 5 / Double(size))
    }

    @Test func `reads what the canvas shows`() throws {
        let session = try session()
        let engine = try RedlampEngine()
        let recipe = EditRecipe()
        let frame = try pixels(engine.renderFrame(
            RenderRequest(recipe: recipe, targetSize: PixelSize(width: size, height: size)), session: session,
        ))
        for (x, y) in [(70, 20), (90, 60), (100, 110)] {
            let readout = try engine.readout(at: point(x: x, y: y), area: area, recipe: recipe, session: session)
            let shown = expected(frame, x: x, y: y)
            #expect(simd_length(readout.rgb - shown.rgb) < 0.3, "at \(x), \(y): \(readout.rgb) against \(shown.rgb)")
            #expect(simd_length(readout.lab - shown.lab) < 0.3, "at \(x), \(y): \(readout.lab) against \(shown.lab)")
            #expect(abs(readout.lab.y) < 0.5 && abs(readout.lab.z) < 0.5, "a grey reads neutral: \(readout.lab)")
        }
    }

    @Test func `clipping warnings never reach it`() throws {
        let session = try session()
        let engine = try RedlampEngine()
        var recipe = EditRecipe()
        recipe[.exposure] = 2
        var request = RenderRequest(recipe: recipe, targetSize: PixelSize(width: size, height: size))
        request.showClipping = true
        let warned = try pixels(engine.renderFrame(request, session: session))
        #expect(warned[64 * size + 10].y < 0.2, "the warning paints the clipped side: \(warned[64 * size + 10])")
        let readout = try engine.readout(at: point(x: 8, y: 62), area: area, recipe: recipe, session: session)
        #expect(readout.rgb.min() > 99, "the clipped side reads white: \(readout.rgb)")
        #expect(readout.lab.x > 99, "\(readout.lab)")
    }

    @Test func `follows the edit`() throws {
        let session = try session()
        let engine = try RedlampEngine()
        var recipe = EditRecipe()
        let before = try engine.readout(at: point(x: 90, y: 60), area: area, recipe: recipe, session: session)
        recipe[.exposure] = 1
        let after = try engine.readout(at: point(x: 90, y: 60), area: area, recipe: recipe, session: session)
        #expect(after.lab.x > before.lab.x + 5, "\(before.lab.x) to \(after.lab.x)")
    }

    private func pixels(_ frame: RenderedFrame) -> [SIMD3<Float>] {
        let surface = frame.surface
        IOSurfaceLock(surface, .readOnly, nil)
        defer { IOSurfaceUnlock(surface, .readOnly, nil) }
        let base = IOSurfaceGetBaseAddress(surface)
        let bytesPerRow = IOSurfaceGetBytesPerRow(surface)
        return (0 ..< frame.size.height).flatMap { y in
            let row = (base + y * bytesPerRow).assumingMemoryBound(to: Float16.self)
            return (0 ..< frame.size.width).map { x in
                SIMD3(Float(row[x * 4]), Float(row[x * 4 + 1]), Float(row[x * 4 + 2]))
            }
        }
    }
}
