import Foundation
import IOSurface
import RedlampEngineAPI
import Testing
@testable import RedlampEngine

/// The raw clipping overlay (UX-05): photosites the sensor clipped, whatever the edit did.
struct RawClippingTests {
    let detail: DetailStageTests

    init() throws {
        detail = try DetailStageTests()
    }

    @Test func `clipped photosites are painted by channel`() throws {
        // Left: every photosite at the clip level. Top right: only the red ones. Bottom right: none.
        let size = 256
        let session = try detail.makeSession(.bayer, width: size, height: size, noiseScale: 0) { x, y in
            if x < size / 2 {
                return 1
            }
            return y < size / 2 && x % 2 == 0 && y % 2 == 0 ? 1 : DetailStageTests.level
        }
        let engine = try RedlampEngine()
        var request = RenderRequest(recipe: EditRecipe(), targetSize: PixelSize(width: size, height: size))
        request.showRawClipping = true
        let marked = try pixels(engine.renderFrame(request, session: session))
        request.showRawClipping = false
        let plain = try pixels(engine.renderFrame(request, session: session))

        func at(_ image: [SIMD3<Float>], _ x: Int, _ y: Int) -> SIMD3<Float> {
            image[y * size + x]
        }
        #expect(at(marked, 64, 128) == SIMD3(0, 0, 0), "all clipped: \(at(marked, 64, 128))")
        #expect(at(marked, 192, 64) == SIMD3(1, 0, 0), "red clipped: \(at(marked, 192, 64))")
        #expect(at(marked, 192, 192) == at(plain, 192, 192), "unclipped: \(at(marked, 192, 192))")
        #expect(at(plain, 64, 128).min() > 0.5, "the overlay is off by default: \(at(plain, 64, 128))")
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
