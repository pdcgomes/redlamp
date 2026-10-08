import Foundation
import RedlampBench
import RedlampRecipes
import Testing

struct BenchPairerTests {
    @Test func `File names pair after the suffixes apps add are removed`() throws {
        let scratch = Scratch()
        var folder = try makeTask(in: scratch)
        let pairer = BenchPairer(folder: folder)
        let unrelated = try TestImages.write(TestImages.photo(seed: 500), to: scratch.file("unrelated.png"))
        for (name, asset) in [
            ("photo-2-Edit.jpg", "photo-2"),
            ("PHOTO-3 copy.JPG", "photo-3"),
            ("photo-1 (1).png", "photo-1"),
        ] {
            let result = try folder.addResult(copying: unrelated, originalName: name, pairer: pairer)
            #expect(result.asset == asset, "\(name)")
            #expect(result.pairedBy == .fileName)
        }
    }

    @Test(arguments: [
        ("colour", false, false),
        ("resized JPEG", true, false),
        ("masked", false, true),
    ])
    func `Results pair by similarity through a filter, a resize, JPEG and a local change`(
        _ name: String, resize: Bool, mask: Bool,
    ) throws {
        let scratch = Scratch()
        var folder = try makeTask(in: scratch)
        let pairer = BenchPairer(folder: folder)
        for (seed, asset) in [(UInt64(2), "photo-2"), (3, "photo-3"), (1, "photo-1")] {
            var image = TestImages.filtered(TestImages.photo(seed: seed))
            if resize {
                image = TestImages.resized(image, longEdge: 540)
            }
            if mask {
                image = TestImages.darkenedLeft(image)
            }
            let file = try TestImages.write(image, to: scratch.file("IMG_\(seed).jpg"), jpeg: resize)
            let result = try folder.addResult(copying: file, originalName: "IMG_000\(seed).JPG", pairer: pairer)
            #expect(result.asset == asset, "\(name): seed \(seed)")
            #expect(result.pairedBy == .similarity)
        }
        #expect(folder.isComplete)
    }

    @Test func `Similarity refuses to choose between near-identical assets`() throws {
        let scratch = Scratch()
        let base = TestImages.photo(seed: 7)
        let a = try TestImages.write(base, to: scratch.file("a.png"))
        let b = try TestImages.write(TestImages.filtered(base), to: scratch.file("b.png"))
        let parent = scratch.file("tasks")
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        var folder = try BenchFolder.create(
            BenchManifest(id: "twins", title: "Twins", kind: "check", pairing: [.similarity]),
            assets: [.init(file: a), .init(file: b)], in: parent,
        )
        let result = try folder.addResult(
            copying: TestImages.write(base, to: scratch.file("out.png")), originalName: "out.png",
            pairer: BenchPairer(folder: folder),
        )
        #expect(result.asset == nil)
    }

    @Test func `Capture-kit charts pair by their barcodes, which similarity can't tell apart`() throws {
        let scratch = Scratch()
        let charts = try (0 ..< 3).map { chart in
            try TestImages.write(
                CaptureChart.pixels(chart: chart),
                to: scratch.file("redlamp-kit-chart-\(chart + 1).png"),
            )
        }
        let parent = scratch.file("looks")
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        var folder = try BenchFolder.create(
            BenchManifest(
                id: "cine-film-2", title: "Prequel · Cine Film 2", kind: BenchManifest.Kind.lookReference,
                pairing: [.captureChart, .fileName, .similarity],
            ),
            assets: charts.enumerated().map { .init(file: $1, chart: $0 + 1) }, in: parent,
        )
        let pairer = BenchPairer(folder: folder)
        for chart in [2, 0, 1] {
            let exported = TestImages.resized(TestImages.filtered(CaptureChart.pixels(chart: chart)), longEdge: 1440)
            let file = try TestImages.write(exported, to: scratch.file("IMG_\(chart).jpg"), jpeg: true)
            let result = try folder.addResult(copying: file, originalName: "IMG_\(chart).JPG", pairer: pairer)
            #expect(result.asset == "redlamp-kit-chart-\(chart + 1)")
            #expect(result.pairedBy == .captureChart)
        }
        #expect(folder.isComplete)
    }
}
