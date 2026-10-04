import CoreGraphics
import Foundation
import IOSurface
import RedlampEngine
import RedlampEngineAPI
import Testing

/// Process 10: the fitted preview shows Texture and Clarity as strongly as an export at the same
/// size does (ARC-04), at sizes that render from different pyramid levels. Measured as in
/// `PreviewExportTests`: each filter's change in linear luminance.
///
/// At 700 px the preview renders from level 3, which has lost the 2 to 8 px texture the export's
/// Texture works on before downscaling, so the two agree in strength but not in where (a
/// correlation of about 0.8, as at process 9); only the strength is held there.
struct DetailPreviewTests {
    private static let decode: [Double] = (0 ..< 256).map { value in
        let c = Double(value) / 255
        return c <= 0.04045 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4)
    }

    private static func luminance(_ r: Double, _ g: Double, _ b: Double) -> Double {
        0.2290 * r + 0.6917 * g + 0.0793 * b
    }

    @Test(.enabled(if: EngineSmokeTests.canRender), arguments: [(700, false), (1000, true), (2000, true)])
    func `the preview shows texture and clarity as the export does`(edge: Int, textureCorrelates: Bool) async throws {
        let url = try #require(EngineSmokeTests.fixtures.first { $0.lastPathComponent == "DSC_0750.NEF" })
        let engine = try RedlampEngine()
        _ = try await engine.open(url)
        let frames = engine.frames()
        var iterator = frames.makeAsyncIterator()
        var generation: UInt64 = 0

        func preview(_ recipe: EditRecipe) async throws -> [Double] {
            generation += 1
            let size = PixelSize(width: edge, height: edge)
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
                recipe: recipe, maxLongEdge: edge, colorSpace: .displayP3, purpose: .export,
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

        var unedited = EditRecipe()
        unedited.processVersion = 10
        let previewBase = try await preview(unedited)
        let exportBase = try await export(unedited)
        try #require(previewBase.count == exportBase.count)
        let cases: [(ParameterID, Double, ClosedRange<Double>)] = [
            (.texture, 60, 0.9 ... 1.1), (.texture, -60, 0.9 ... 1.1), (.clarity, 60, 0.8 ... 1.25),
        ]
        for (parameter, value, ratios) in cases {
            var edited = unedited
            edited[parameter] = value
            let previewEdited = try await preview(edited)
            let exportEdited = try await export(edited)
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
            #expect(
                ratios.contains(ratio),
                "\(edge) \(parameter) \(value): preview shows \(ratio)x the export's effect",
            )
            #expect(
                correlation > 0.85 || parameter == .texture && !textureCorrelates,
                "\(edge) \(parameter) \(value): correlation \(correlation)",
            )
        }
    }
}
