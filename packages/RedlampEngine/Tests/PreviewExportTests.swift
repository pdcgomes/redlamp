import CoreGraphics
import Foundation
import IOSurface
import RedlampEngine
import RedlampEngineAPI
import Testing

/// The fitted preview must show each spatial filter as strongly as an export at the same size
/// shows it (ARC-04): the preview renders from a coarser pyramid level, the export at full
/// resolution and then downscaled. Compared as each filter's change in linear luminance.
///
/// Not gated yet: sharpening at small radii (invisible at fit in the preview, faintly present
/// in a downscaled export, as in Lightroom), noise reduction (its effect has averaged away at
/// this scale) and grain (drawn at display pixels, so about 4x stronger in the preview; TON-19).
struct PreviewExportTests {
    private static let edge = 1000

    private static let decode: [Double] = (0 ..< 256).map { value in
        let c = Double(value) / 255
        return c <= 0.04045 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4)
    }

    /// Display P3 luminance weights: the preview is linear Display P3, the export is asked for it.
    private static func luminance(_ r: Double, _ g: Double, _ b: Double) -> Double {
        0.2290 * r + 0.6917 * g + 0.0793 * b
    }

    @Test(.enabled(if: EngineSmokeTests.canRender), arguments: [
        ("Texture", ParameterID.texture, 60.0), ("Texture", .texture, -60), ("Clarity", .clarity, 60),
        ("Dehaze", .dehaze, 50),
    ])
    func `the preview shows a filter as the export does`(
        name: String,
        parameter: ParameterID,
        value: Double,
    ) async throws {
        let url = try #require(EngineSmokeTests.fixtures.first { $0.lastPathComponent == "DSC_0750.NEF" })
        let engine = try RedlampEngine()
        _ = try await engine.open(url)
        let frames = engine.frames()
        var iterator = frames.makeAsyncIterator()
        var generation: UInt64 = 0

        func preview(_ recipe: EditRecipe) async throws -> [Double] {
            generation += 1
            let size = PixelSize(width: Self.edge, height: Self.edge)
            engine.render(RenderRequest(recipe: recipe, targetSize: size, generation: generation))
            var frame = try #require(await iterator.next())
            while frame.generation != generation {
                frame = try #require(await iterator.next())
            }
            let surface = frame.surface
            IOSurfaceLock(surface, .readOnly, nil)
            defer { IOSurfaceUnlock(surface, .readOnly, nil) }
            let base = IOSurfaceGetBaseAddress(surface)
            let bytesPerRow = IOSurfaceGetBytesPerRow(surface)
            return (0 ..< frame.size.height).flatMap { y in
                let row = (base + y * bytesPerRow).assumingMemoryBound(to: Float16.self)
                return (0 ..< frame.size.width).map { x in
                    Self.luminance(Double(row[x * 4]), Double(row[x * 4 + 1]), Double(row[x * 4 + 2]))
                }
            }
        }

        func export(_ recipe: EditRecipe) async throws -> [Double] {
            let image = try await engine.renderStill(StillRequest(
                recipe: recipe, maxLongEdge: Self.edge, colorSpace: .displayP3, purpose: .export,
            ))
            let data = try #require(image.dataProvider?.data) as Data
            let bytes = [UInt8](data)
            let bytesPerPixel = image.bitsPerPixel / 8
            return (0 ..< image.height).flatMap { y in
                (0 ..< image.width).map { x in
                    let offset = y * image.bytesPerRow + x * bytesPerPixel
                    return Self.luminance(
                        Self.decode[Int(bytes[offset])], Self.decode[Int(bytes[offset + 1])],
                        Self.decode[Int(bytes[offset + 2])],
                    )
                }
            }
        }

        var edited = EditRecipe()
        edited[parameter] = value
        let previewBase = try await preview(EditRecipe())
        let previewEdited = try await preview(edited)
        let exportBase = try await export(EditRecipe())
        let exportEdited = try await export(edited)
        try #require(previewBase.count == exportBase.count)

        var previewEnergy = 0.0
        var exportEnergy = 0.0
        var cross = 0.0
        for index in previewBase.indices {
            let shown = previewEdited[index] - previewBase[index]
            let exported = exportEdited[index] - exportBase[index]
            previewEnergy += shown * shown
            exportEnergy += exported * exported
            cross += shown * exported
        }
        let ratio = (previewEnergy / exportEnergy).squareRoot()
        let correlation = cross / (previewEnergy * exportEnergy).squareRoot()
        #expect((0.8 ... 1.25).contains(ratio), "\(name) \(value): preview shows \(ratio)x the export's effect")
        #expect(correlation > 0.85, "\(name) \(value): correlation \(correlation)")
    }
}
