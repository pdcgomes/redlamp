import CoreGraphics
import Foundation
import RedlampEngineAPI
import RedlampRecipes
import simd
import Testing

struct CompactKitTests {
    static let layout = CaptureLayout.compact

    /// Stand-ins for the kit photos: textured gradients in different colours, some with
    /// highlights.
    static func tiles() -> [PixelImage] {
        (0 ..< 8).map { k in
            let width = 600, height = 400
            let hue = Float(k) / 8 * 2 * .pi
            let tint = SIMD3<Float>(cos(hue), cos(hue - 2.1), cos(hue + 2.1)) * 0.2
            var pixels: [SIMD3<Float>] = []
            pixels.reserveCapacity(width * height)
            for y in 0 ..< height {
                for x in 0 ..< width {
                    let u = Float(x) / Float(width), v = Float(y) / Float(height)
                    let texture = 0.07 * sin(Float(x) * (0.15 + 0.02 * Float(k))) * cos(Float(y) * 0.19)
                    let spot = k % 2 == 0 && simd_distance(SIMD2(u, v), SIMD2(0.7, 0.35)) < 0.08 ? 0.5 : 0
                    let base = SIMD3<Float>(repeating: 0.2 + 0.55 * u * (1 - 0.4 * v))
                    pixels.append(simd_clamp(base + tint + SIMD3(repeating: texture + Float(spot)), .zero, .one))
                }
            }
            return PixelImage(width: width, height: height, pixels: pixels)
        }
    }

    static let kit = layout.pixels(chart: 0, tiles: tiles())
    static let tileNames = ["sky", "foliage", "night", "interior", "contrast", "colours", "skin-deep", "skin-light"]

    /// The kit through a phone app: a 4:5 crop, the look, a vignette over the exported frame,
    /// grain, a resize so the long edge is `longEdge`, and JPEG at quality 0.8.
    static func export(longEdge: Int, vignette: VignetteModel) throws -> PixelImage {
        let side = layout.side, width = side * 4 / 5
        let crop = AppLookTests.cropped(kit, CGRect(x: (side - width) / 2, y: 0, width: width, height: side))
        let filtered = AppLookTests.filter(crop, vignette: vignette, grain: 0.012, seed: UInt64(longEdge))
        return try AppLookTests.jpeg(AppLookTests.resized(filtered, longEdge: longEdge), quality: 0.8)
    }

    static func deltaE(_ a: SIMD3<Float>, _ b: SIMD3<Float>) -> Float {
        simd_distance(
            ColorMath.encodedSRGBToOKLab(simd_clamp(a, .zero, .one)),
            ColorMath.encodedSRGBToOKLab(simd_clamp(b, .zero, .one)),
        ) * 100
    }

    @Test func `the compact image is found as compact, with its markers`() throws {
        let location = try #require(AppLookImport.locate(Self.kit))
        #expect(location.layout.kind == .compact)
        #expect(location.chart == 0)
        #expect(location.markersFound == 8)
        #expect(abs(location.transform.scale.x - 1) < 0.002)
        let unchanged = try AppLookImport.read(
            [AppLookImport.Export(name: "kit.png", image: Self.kit)], sources: AppLookImport.Originals(),
        )
        #expect(unchanged.report.resolution?.effectiveScale.map { abs($0 - 1) < 0.01 } == true)
        #expect(unchanged.report.warnings.isEmpty)
        let full = try #require(AppLookImport.locate(CaptureChart.pixels(chart: 1)))
        #expect(full.layout.kind == .full)
        #expect(full.chart == 1)
    }

    @Test func `the compact layout fits a 4:5 crop and keeps its patch sizes`() {
        let layout = Self.layout
        #expect(layout.slices(chart: 0).count == layout.lattice)
        #expect(layout.patches(chart: 0).count == layout.lattice * layout.lattice * layout.lattice)
        let keep = CGRect(x: layout.side / 10, y: 0, width: layout.side * 8 / 10, height: layout.side)
        let wide = CGRect(x: 0, y: layout.side / 10, width: layout.side, height: layout.side * 8 / 10)
        let colour = layout.markerCentres.map(layout.markerRectForTests) + [layout.latticeRect, layout.rampRect]
            + layout.barcodeCopies.flatMap(\.self) + layout.linePairs.map(\.rect)
        #expect(colour.allSatisfy { keep.contains($0) && wide.contains($0) })
        #expect(layout.photoTiles.allSatisfy { keep.contains($0) })
        #expect(Float(layout.patch) * 2048 / Float(layout.side) >= 8)
        #expect(Float(layout.patch) * 1440 / Float(layout.side) >= 6)
    }

    @Test(arguments: [2048, 1440])
    func `a known look survives the compact kit at a phone export size`(longEdge: Int) throws {
        let vignette = VignetteModel(amount: -30, midpoint: 50, feather: 50)
        let image = try Self.export(longEdge: longEdge, vignette: vignette)
        let result = try AppLookImport.read(
            [AppLookImport.Export(name: "IMG_\(longEdge).jpg", image: image)],
            sources: AppLookImport.Originals(compact: Self.kit, tileNames: Self.tileNames),
        )
        let report = result.report
        let n = Self.layout.lattice
        var nodes: [Float] = []
        for b in 0 ..< n {
            for g in 0 ..< n {
                for r in 0 ..< n {
                    let input = Self.layout.nodeValue(SIMD3(r, g, b))
                    nodes.append(Self.deltaE(AppLookTests.look(input), result.table.entry(r: r, g: g, b: b)))
                }
            }
        }
        var between: [Float] = []
        for b in 0 ..< 25 {
            for g in 0 ..< 25 {
                for r in 0 ..< 25 {
                    let input = SIMD3(Float(r), Float(g), Float(b)) / 24
                    between.append(Self.deltaE(AppLookTests.look(input), result.table.sample(input)))
                }
            }
        }
        let estimate = try #require(report.vignette)
        let resolution = try #require(report.resolution)
        print(String(
            format: "compact %d px: nodes ΔE mean %.3f max %.3f; 25³ grid ΔE mean %.3f max %.3f; "
                + "vignette %.1f (true -30) %@ frame, corner %.3f (true %.3f); grain %.4f; "
                + "scale %.3f, effective %.3f (resolved period %.2f), patches %.2f px; %d tiles",
            longEdge, nodes.reduce(0, +) / Float(nodes.count), nodes.max() ?? 0,
            between.reduce(0, +) / Float(between.count), between.max() ?? 0,
            estimate.model.amount, estimate.frame, estimate.cornerGain,
            vignette.gain(Float(2).squareRoot(), encoded: 0.5), report.grain?.luma ?? -1,
            resolution.scale, resolution.effectiveScale ?? -1, resolution.resolvedPeriod ?? -1,
            resolution.patchPixels, report.photos.count,
        ))
        print(report.summary)
        #expect(report.layout == .compact)
        #expect(report.lattice == n)
        #expect(report.patchesMeasured == n * n * n)
        #expect(nodes.reduce(0, +) / Float(nodes.count) < 1.5)
        #expect(between.reduce(0, +) / Float(between.count) < 1.5)
        #expect((nodes.max() ?? 0) < 5)
        #expect(estimate.frame == "export")
        #expect(abs(estimate.model.amount - vignette.amount) < 6)
        #expect(abs(estimate.cornerGain - Double(vignette.gain(Float(2).squareRoot(), encoded: 0.5))) < 0.04)
        #expect(abs(resolution.scale - Double(longEdge) / Double(Self.layout.side)) < 0.005)
        #expect(abs((resolution.effectiveScale ?? 0) / resolution.scale - 1) < 0.2)
        #expect(!report.warnings.contains { $0.contains("detail of") || $0.contains("patches are") })
        #expect(report.photos.count == 8)
        #expect(report.photos.map(\.kitPhoto) == Self.tileNames)
        #expect(report.photos.allSatisfy { $0.residualMeanDeltaE < 2.5 && $0.similarity > 0.8 })
        let grain = try #require(report.grain)
        #expect(grain.luma > 0.003 && grain.luma < 0.03)
    }

    @Test func `an export scaled up from a small image is flagged`() throws {
        let small = try #require(try AppLookTests.resized(Self.kit, longEdge: 900).cgImage())
        let space = try #require(CGColorSpace(name: CGColorSpace.sRGB))
        let context = try #require(CGContext(
            data: nil, width: 2048, height: 2048, bitsPerComponent: 8, bytesPerRow: 2048 * 4, space: space,
            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue,
        ))
        context.interpolationQuality = .high
        context.draw(small, in: CGRect(x: 0, y: 0, width: 2048, height: 2048))
        let upscaled = try #require(context.makeImage().flatMap { PixelImage($0) })
        let image = try AppLookTests.jpeg(upscaled, quality: 0.9)
        let result = try AppLookImport.read(
            [AppLookImport.Export(name: "upscaled.jpg", image: image)], sources: AppLookImport.Originals(),
        )
        let resolution = try #require(result.report.resolution)
        print(String(
            format: "upscaled: scale %.3f, effective %.3f (resolved period %.2f), patches %.2f px (%.2f effective)",
            resolution.scale, resolution.effectiveScale ?? -1, resolution.resolvedPeriod ?? -1, resolution.patchPixels,
            resolution.effectivePatchPixels,
        ))
        #expect(resolution.effectiveScale ?? 1 < 0.8 * resolution.scale)
        #expect(result.report.warnings.contains { $0.contains("detail of") })
    }

    @Test func `several compact exports in one folder are refused`() throws {
        let image = try AppLookTests.resized(Self.kit, longEdge: 1600)
        #expect {
            _ = try AppLookImport.read([
                AppLookImport.Export(name: "a.jpg", image: image), AppLookImport.Export(name: "b.jpg", image: image),
            ], sources: AppLookImport.Originals())
        } throws: { error in
            (error as? AppLookImportError) == .severalCompact(files: ["a.jpg", "b.jpg"])
        }
    }
}

extension CaptureLayout {
    func markerRectForTests(_ centre: SIMD2<Float>) -> CGRect {
        let box = CGFloat(9 * markerModule)
        return CGRect(x: CGFloat(centre.x) - box / 2, y: CGFloat(centre.y) - box / 2, width: box, height: box)
    }
}
