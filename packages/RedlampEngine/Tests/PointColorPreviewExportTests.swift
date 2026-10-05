import CoreGraphics
import Foundation
import IOSurface
import RedlampColor
import RedlampEngine
import RedlampEngineAPI
import simd
import Testing

/// Point Color in the fitted preview against an export downscaled to the same size (TON-29): a
/// mask's swatch of its own colour, measured on its own small render whatever the output's size,
/// must change the colours the same way in both. Compared as the change in OKLab a and b.
struct PointColorPreviewExportTests {
    private static let edge = 1000

    private static let decode: [Double] = (0 ..< 256).map { value in
        let c = Double(value) / 255
        return c <= 0.04045 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4)
    }

    private static let toSRGB = RGBPrimaries.displayP3.conversion(to: .sRGB)

    /// OKLab a and b of a linear Display P3 colour.
    private static func opponents(_ r: Double, _ g: Double, _ b: Double) -> SIMD2<Double> {
        let lab = OKLab.fromLinearSRGB(toSRGB * SIMD3(r, g, b))
        return SIMD2(lab.y, lab.z)
    }

    @Test(.enabled(if: EngineSmokeTests.canRender))
    func `the preview shows a mask's swatch of its own colour as the export does`() async throws {
        let url = try #require(EngineSmokeTests.fixtures.first { $0.lastPathComponent == "DSC_0750.NEF" })
        let engine = try RedlampEngine()
        _ = try await engine.open(url)
        let frames = engine.frames()
        var iterator = frames.makeAsyncIterator()
        var generation: UInt64 = 0

        func preview(_ recipe: EditRecipe) async throws -> [SIMD2<Double>] {
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
                    Self.opponents(Double(row[x * 4]), Double(row[x * 4 + 1]), Double(row[x * 4 + 2]))
                }
            }
        }

        func export(_ recipe: EditRecipe) async throws -> [SIMD2<Double>] {
            let image = try await engine.renderStill(StillRequest(
                recipe: recipe, maxLongEdge: Self.edge, colorSpace: .displayP3, purpose: .export,
            ))
            let data = try #require(image.dataProvider?.data) as Data
            let bytes = [UInt8](data)
            let bytesPerPixel = image.bitsPerPixel / 8
            return (0 ..< image.height).flatMap { y in
                (0 ..< image.width).map { x in
                    let offset = y * image.bytesPerRow + x * bytesPerPixel
                    return Self.opponents(
                        Self.decode[Int(bytes[offset])], Self.decode[Int(bytes[offset + 1])],
                        Self.decode[Int(bytes[offset + 2])],
                    )
                }
            }
        }

        var mask = MaskLayer(name: "Centre", components: [MaskComponent(shape: .radial(RadialMask(
            center: ImagePoint(x: 0.5, y: 0.5), radiusX: 0.3, radiusY: 0.3,
        )))])
        mask.pointColor = [PointColorSwatch(color: .mask, values: [
            .pointColorHueShift: 100, .pointColorSaturationShift: 50, .pointColorHueUniformity: 50,
        ])]
        var edited = EditRecipe()
        edited.masks = [mask]
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
            previewEnergy += (shown * shown).sum()
            exportEnergy += (exported * exported).sum()
            cross += (shown * exported).sum()
        }
        #expect(exportEnergy > 0, "the swatch changes the export")
        let ratio = (previewEnergy / exportEnergy).squareRoot()
        let correlation = cross / (previewEnergy * exportEnergy).squareRoot()
        #expect((0.9 ... 1.1).contains(ratio), "the preview shows \(ratio)x the export's change")
        #expect(correlation > 0.95, "correlation \(correlation)")
    }
}
