import Foundation
import RedlampBench
import RedlampRecipes
import simd
import Testing

/// Look references (TON-36): the kit published as a template, a reference made from it as the
/// phone makes one, exports filed and paired, and the importer reading the reference.
struct BenchCaptureTests {
    /// A full kit folder as `redlamp recipe app-kit` writes one: three charts and two photos.
    private func kit(_ scratch: Scratch) throws -> URL {
        let folder = scratch.file("kit")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        var files: [CaptureKitManifest.File] = []
        for chart in 0 ..< CaptureChart.chartCount {
            let name = CaptureKitManifest.chartFileName(chart)
            let url = try TestImages.write(CaptureChart.pixels(chart: chart), to: folder.appending(path: name))
            try files.append(.init(file: name, role: "chart", chart: chart + 1, data: Data(contentsOf: url)))
        }
        for (index, subject) in ["contrast", "skin-light"].enumerated() {
            let name = "redlamp-kit-photo-\(index + 1)-\(subject).jpg"
            let url = try TestImages.write(
                TestImages.photo(seed: UInt64(40 + index), width: 1200, height: 800),
                to: folder.appending(path: name), jpeg: true,
            )
            try files.append(.init(file: name, role: "photo", subject: subject, data: Data(contentsOf: url)))
        }
        try JSONEncoder.bench.encode(CaptureKitManifest(files: files))
            .write(to: folder.appending(path: CaptureKitManifest.fileName))
        return folder
    }

    @Test func `A look reference from the kit pairs its exports and reads back the filter's table`() throws {
        let scratch = Scratch()
        let store = BenchStore(root: scratch.file("store"))
        let template = try BenchCapture.publishKit(full: kit(scratch), compact: nil, in: store)
        #expect(template.manifest.assets.compactMap(\.chart) == [1, 2, 3])

        let library = BenchLibrary(root: scratch.file("phone"), kit: template.url)
        var look = try library.newLook(.init(
            app: "Prequel", filter: "Cine Film", variant: "2", settings: "Grain 0", kitSet: .standard,
        ))
        #expect(look.manifest.assets.count == 5)
        #expect(look.manifest.look?.title == "Prequel · Cine Film 2")
        #expect(library.suggested?.id == look.id)

        let pairer = BenchPairer(folder: look)
        for asset in look.manifest.assets {
            let file = try #require(look.file(asset.file))
            let original = try #require(BenchPairer.image(file, maxLongEdge: 2048))
            let exported = try TestImages.write(TestImages.filtered(original), to: scratch.file("IMG_\(asset.id).png"))
            let result = try look.addResult(copying: exported, originalName: "IMG_0001.PNG", pairer: pairer)
            #expect(result.asset == asset.id)
        }
        #expect(look.isComplete)

        let inputs = try BenchCapture.inputs(look)
        #expect(inputs.charts.count == 3)
        #expect(inputs.photos.count == 2)
        #expect(inputs.provenance?.variant == "2")
        let result = try inputs.read()
        #expect(result.report.patchesMeasured == result.report.patchesTotal)
        for grey: Float in [0.2, 0.5, 0.8] {
            let measured = result.table.sample(SIMD3(repeating: grey))
            let expected = TestImages.filtered(PixelImage(width: 1, height: 1, pixels: [SIMD3(repeating: grey)]))
                .pixels[0]
            #expect(simd_distance(measured, expected) < 0.02, "grey \(grey)")
        }
        #expect(result.report.photos.count == 2)
        #expect(result.report.photos.allSatisfy { $0.residualMeanDeltaE < 2 })
    }

    @Test func `A reference without its charts back can't be read yet`() throws {
        let scratch = Scratch()
        let store = BenchStore(root: scratch.file("store"))
        let template = try BenchCapture.publishKit(full: kit(scratch), compact: nil, in: store)
        let library = BenchLibrary(root: scratch.file("phone"), kit: template.url)
        let look = try library.newLook(.init(app: "Prequel", filter: "Retro", kitSet: .full))
        #expect(throws: BenchCapture.CaptureError.self) { try BenchCapture.inputs(look) }
    }
}
