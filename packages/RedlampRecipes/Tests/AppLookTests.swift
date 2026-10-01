import CoreGraphics
import Foundation
import ImageIO
import RedlampEngineAPI
import RedlampRecipes
import simd
import Testing
import UniformTypeIdentifiers

struct AppLookTests {
    /// A warm, contrasty look with a hue rotation, in sRGB display values.
    static func look(_ c: SIMD3<Float>) -> SIMD3<Float> {
        let (l, chroma, hue) = ColorMath.lch(ColorMath.encodedSRGBToOKLab(c))
        var v = ColorMath.okLabToEncodedSRGB(ColorMath.lab(l: l, c: chroma * 1.1, h: hue + 15))
        v = SIMD3(v.x * 0.94 + 0.06, v.y * 0.98 + 0.01, v.z * 0.88)
        func contrast(_ x: Float) -> Float {
            x + 1.2 * (x - 0.5) * x * (1 - x)
        }
        return SIMD3(contrast(v.x), contrast(v.y), contrast(v.z))
    }

    struct Noise {
        var state: UInt64

        mutating func next() -> Float {
            state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            return Float(state >> 40) / Float(1 << 24)
        }

        mutating func gaussian() -> Float {
            let u = max(next(), 1e-7), v = next()
            return (-2 * log(u)).squareRoot() * cos(2 * .pi * v)
        }
    }

    /// What a phone app might do: the look, a vignette over the whole frame, and grain.
    static func filter(_ chart: PixelImage, vignette: VignetteModel, grain: Float, seed: UInt64) -> PixelImage {
        var cache: [SIMD3<UInt8>: SIMD3<Float>] = [:]
        var noise = Noise(state: seed)
        var image = chart
        let frame = CGRect(x: 0, y: 0, width: chart.width, height: chart.height)
        for y in 0 ..< chart.height {
            for x in 0 ..< chart.width {
                let c = chart[x, y]
                let q = (c * 255).rounded(.toNearestOrAwayFromZero)
                let key = SIMD3<UInt8>(UInt8(q.x), UInt8(q.y), UInt8(q.z))
                let looked = cache[key] ?? {
                    let value = simd_clamp(look(c), .zero, SIMD3(repeating: 1))
                    cache[key] = value
                    return value
                }()
                let d = VignetteModel.radius(SIMD2(Float(x) + 0.5, Float(y) + 0.5), in: frame)
                let g = vignette.gain(d, encoded: 0.5)
                image[x, y] = simd_clamp(looked * g + SIMD3(repeating: grain * noise.gaussian()), .zero, .one)
            }
        }
        return image
    }

    static func resized(_ image: PixelImage, longEdge: Int) throws -> PixelImage {
        try #require(image.cgImage().flatMap { PixelImage($0, maxLongEdge: longEdge) })
    }

    static func cropped(_ image: PixelImage, _ rect: CGRect) -> PixelImage {
        var pixels: [SIMD3<Float>] = []
        for y in Int(rect.minY) ..< Int(rect.maxY) {
            for x in Int(rect.minX) ..< Int(rect.maxX) {
                pixels.append(image[x, y])
            }
        }
        return PixelImage(width: Int(rect.width), height: Int(rect.height), pixels: pixels)
    }

    static func jpeg(_ image: PixelImage, quality: Double) throws -> PixelImage {
        let data = NSMutableData()
        let cg = try #require(image.cgImage())
        let destination = try #require(CGImageDestinationCreateWithData(
            data as CFMutableData, UTType.jpeg.identifier as CFString, 1, nil,
        ))
        CGImageDestinationAddImage(
            destination,
            cg,
            [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary,
        )
        #expect(CGImageDestinationFinalize(destination))
        let source = try #require(CGImageSourceCreateWithData(data as CFData, nil))
        let decoded = try #require(CGImageSourceCreateImageAtIndex(source, 0, nil))
        return try #require(PixelImage(decoded))
    }

    @Test func `an unfiltered chart is found with all its markers and its number`() throws {
        for chart in 0 ..< CaptureChart.chartCount {
            let location = try #require(AppLookImport.locate(CaptureChart.pixels(chart: chart)))
            #expect(location.chart == chart)
            #expect(location.markersFound == 8)
            #expect(abs(location.transform.scale.x - 1) < 0.002)
            #expect(simd_length(location.transform.offset) < 1)
        }
    }

    @Test func `a known look survives resize, crop, vignette, grain and JPEG`() throws {
        let vignette = VignetteModel(amount: -30, midpoint: 50, feather: 50)
        var exports: [AppLookImport.Export] = []
        for chart in 0 ..< CaptureChart.chartCount {
            let filtered = Self.filter(
                CaptureChart.pixels(chart: chart), vignette: vignette, grain: 0.015, seed: UInt64(chart + 1),
            )
            let small = try Self.resized(filtered, longEdge: Int((Float(CaptureChart.side) * 0.53).rounded()))
            let crop = CGRect(x: 60, y: 45, width: small.width - 95, height: small.height - 95)
            let compressed = try Self.jpeg(Self.cropped(small, crop), quality: 0.8)
            exports.append(AppLookImport.Export(name: "IMG_\(4100 + chart).jpg", image: compressed))
        }
        let result = try AppLookImport.read(exports)

        var errors: [Float] = []
        let n = CaptureChart.lattice
        for b in 0 ..< n {
            for g in 0 ..< n {
                for r in 0 ..< n {
                    let input = CaptureChart.nodeValue(SIMD3(r, g, b))
                    let known = simd_clamp(Self.look(input), .zero, .one)
                    let measured = simd_clamp(result.table.entry(r: r, g: g, b: b), .zero, .one)
                    errors.append(simd_distance(
                        ColorMath.encodedSRGBToOKLab(known),
                        ColorMath.encodedSRGBToOKLab(measured),
                    ) * 100)
                }
            }
        }
        let mean = errors.reduce(0, +) / Float(errors.count)
        let worst = errors.max() ?? 0
        let estimate = try #require(result.report.vignette)
        let trueCorner = vignette.gain(Float(2).squareRoot(), encoded: 0.5)
        print(String(
            format: "app look: ΔE mean %.3f max %.3f; vignette amount %.1f (true -30), midpoint %.0f, "
                + "feather %.0f, corner gain %.3f (true %.3f), frame %@; grain %.4f",
            mean, worst, estimate.model.amount, estimate.model.midpoint, estimate.model.feather,
            estimate.cornerGain, trueCorner, estimate.frame, result.report.grain?.luma ?? -1,
        ))
        print(result.report.summary)
        #expect(result.report.patchesMeasured == n * n * n)
        #expect(mean < 1.5)
        #expect(worst < 5)
        #expect(abs(estimate.model.amount - vignette.amount) < 6)
        #expect(abs(estimate.cornerGain - Double(trueCorner)) < 0.04)
        #expect(estimate.frame == "chart")
        let grain = try #require(result.report.grain)
        #expect(grain.luma > 0.003 && grain.luma < 0.03)

        var captured = result
        captured.report.provenance = AppLookReport.Provenance(app: "prequel", filter: "Their Filter")
        let recipe = try AppLookRecipe.make(captured, name: "Ember")
        #expect(recipe.name == "Ember")
        #expect(recipe.embeddedBaseLooks.allSatisfy { $0.name == "Ember" })
        #expect(recipe.includes.isSuperset(of: [.baseLook, .effects]))
        #expect(abs((recipe.settings.values[.vignetteAmount] ?? 0) + 30) <= 6)
        guard case let .other(dialect, payload) = recipe.source,
              case let .object(provenance) = payload["provenance"] else {
            Issue.record("no provenance")
            return
        }
        #expect(dialect == AppLookRecipe.dialect)
        #expect(provenance["filter"] == .string("Their Filter"))
    }

    @Test func `a photo pair gives the vignette and a small residual`() throws {
        let width = 1200, height = 800
        var pixels: [SIMD3<Float>] = []
        for y in 0 ..< height {
            for x in 0 ..< width {
                let u = Float(x) / Float(width), v = Float(y) / Float(height)
                let texture = 0.08 * sin(Float(x) * 0.21) * cos(Float(y) * 0.17)
                let block = (x / 150 + y / 160) % 3 == 0 ? SIMD3<Float>(0.2, -0.1, 0.05) : .zero
                pixels.append(simd_clamp(
                    SIMD3(0.25 + 0.5 * u + texture, 0.3 + 0.4 * v + texture, 0.55 - 0.3 * u * v + texture) + block,
                    .zero, .one,
                ))
            }
        }
        let photo = PixelImage(width: width, height: height, pixels: pixels)
        let vignette = VignetteModel(amount: -40, midpoint: 40, feather: 60)
        let exported = try Self.jpeg(Self.filter(photo, vignette: vignette, grain: 0, seed: 9), quality: 0.85)
        let table = try LookTable(size: 25) { simd_clamp(Self.look($0), .zero, .one) }
        let measures = try #require(PhotoPairAnalysis.analyse(kit: photo, export: exported, table: table))
        let estimate = try #require(measures.vignette)
        let corner = try #require(measures.cornerGain)
        print(String(
            format: "photo pair: vignette %.1f (true -40), corner %.3f (true %.3f), residual ΔE %.2f",
            estimate.amount,
            corner,
            vignette.gain(Float(2).squareRoot(), encoded: 0.5),
            measures.residualMean,
        ))
        #expect(abs(corner - vignette.gain(Float(2).squareRoot(), encoded: 0.5)) < 0.06)
        #expect(measures.residualMean < 2)
        #expect(PhotoPairAnalysis.similarity(photo, exported) > 0.8)
    }

    @Test func `a crop into the lattice is refused with a clear error`() throws {
        let chart = CaptureChart.pixels(chart: 0)
        let width = CaptureChart.side * 9 / 16
        let crop = Self.cropped(chart, CGRect(
            x: (CaptureChart.side - width) / 2, y: 0, width: width, height: CaptureChart.side,
        ))
        #expect {
            _ = try AppLookImport.read([AppLookImport.Export(name: "story.jpg", image: crop, chartHint: 0)])
        } throws: { error in
            guard case let .latticeCut(file, visible) = error as? AppLookImportError else { return false }
            return file == "story.jpg" && visible < 0.9
        }
    }
}
