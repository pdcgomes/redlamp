import AppKit
import Foundation
import RedlampDocument
import RedlampEngineAPI
import SwiftUI
import Testing
@testable import RedlampUI

/// The Healing tool (RM-01).
@MainActor
struct HealToolTests {
    private func openEditor(_ engine: StubEngine = StubEngine()) async throws -> (EditorModel, () -> Void) {
        let folder = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let model = EditorModel(engine: engine)
        model.select(folder.appending(path: "IMG_0001.ARW"))
        for _ in 0 ..< 200 where model.info == nil {
            try await Task.sleep(for: .milliseconds(5))
        }
        #expect(model.info != nil)
        return (model, { try? FileManager.default.removeItem(at: folder) })
    }

    @Test func `a click adds a spot copying from the source the engine finds`() async throws {
        let engine = StubEngine()
        engine.retouchSource = ImagePoint(x: 0.3, y: 0.42)
        let (model, cleanup) = try await openEditor(engine)
        defer { cleanup() }
        #expect(model.perform(.healTool))
        #expect(model.activeTool == .heal)
        model.setSliderValue(.spotSize, 40)
        await model.addSpot(at: ImagePoint(x: 0.5, y: 0.4))
        let spot = try #require(model.recipe.spots.first)
        #expect(spot.mode == .heal && spot.source == ImagePoint(x: 0.3, y: 0.42))
        #expect(abs(spot.radius - RetouchSpot.radius(size: 40)) < 1e-12)
        #expect(model.selectedSpotID == spot.id)
        #expect(model.history.last?.name == "Heal")
        #expect(abs(model.sliderValue(.spotSize) - 40) < 1e-9)
    }

    @Test func `with no source found, a spot copies from beside itself, inside the photo`() async throws {
        let (model, cleanup) = try await openEditor()
        defer { cleanup() }
        model.activeTool = .heal
        await model.setSpotMode(.clone)
        await model.addSpot(at: ImagePoint(x: 0.995, y: 0.5))
        let spot = try #require(model.recipe.spots.first)
        #expect(spot.mode == .clone)
        #expect(spot.source.x < spot.center.x && spot.source.y == spot.center.y, "at the right edge, to the left")
        #expect(model.history.last?.name == "Clone")
    }

    @Test func `a Remove spot needs no source, and finds one when it becomes Heal`() async throws {
        let engine = StubEngine()
        engine.retouchSource = ImagePoint(x: 0.2, y: 0.6)
        let (model, cleanup) = try await openEditor(engine)
        defer { cleanup() }
        model.activeTool = .heal
        await model.setSpotMode(.remove)
        await model.addSpot(at: ImagePoint(x: 0.5, y: 0.5))
        let spot = try #require(model.recipe.spots.first)
        #expect(spot.mode == .remove && spot.source == spot.center && !spot.isEmpty)
        #expect(model.history.last?.name == "Remove")
        await model.setSpotMode(.heal)
        #expect(model.recipe.spots[0].mode == .heal && model.recipe.spots[0].source == ImagePoint(x: 0.2, y: 0.6))
        #expect(model.history.last?.name == "Heal")
    }

    /// A mask covering the left or right half of the photo.
    private func half(_ left: Bool) throws -> AIMask {
        let (width, height) = (8, 4)
        let pixels = (0 ..< width * height).map { index -> UInt8 in (index % width < width / 2) == left ? 255 : 0 }
        let rep = try #require(NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height, bitsPerSample: 8, samplesPerPixel: 1,
            hasAlpha: false, isPlanar: false, colorSpaceName: .deviceWhite, bytesPerRow: width, bitsPerPixel: 8,
        ))
        rep.bitmapData?.update(from: pixels, count: pixels.count)
        let png = try #require(rep.representation(using: .png, properties: [:]))
        return AIMask(
            kind: .people, provider: "stub", revision: 1, analysisHash: "h",
            center: ImagePoint(x: left ? 0.25 : 0.75, y: 0.5), bitmap: MaskBitmap(
                png: png,
                width: width,
                height: height,
            ),
        )
    }

    @Test func `a click picks the person under it, to remove`() async throws {
        let engine = StubEngine()
        engine.computed = try [half(true), half(false)]
        let (model, cleanup) = try await openEditor(engine)
        defer { cleanup() }
        model.activeTool = .heal
        model.spotPick = .person
        await model.pickRegion(at: ImagePoint(x: 0.6, y: 0.5))
        let spot = try #require(model.recipe.spots.first)
        #expect(spot.mode == .remove && spot.region?.center == ImagePoint(x: 0.75, y: 0.5))
        #expect(engine.lastRequest?.kind == .people)
        #expect(model.history.last?.name == "Remove Person")
        #expect(model.recipe.maskBitmaps.count == 1)
    }

    @Test func `a click picks the object under it, or says nothing is there`() async throws {
        let engine = StubEngine()
        engine.computed = try [half(true)]
        let (model, cleanup) = try await openEditor(engine)
        defer { cleanup() }
        model.activeTool = .heal
        model.spotPick = .object
        await model.pickRegion(at: ImagePoint(x: 0.3, y: 0.4))
        #expect(engine.lastRequest?.kind == .objects && engine.lastRequest?.prompts == [ImagePoint(x: 0.3, y: 0.4)])
        #expect(model.recipe.spots.first?.region != nil && model.history.last?.name == "Remove Object")
        engine.computed = []
        await model.pickRegion(at: ImagePoint(x: 0.3, y: 0.4))
        #expect(model.pickMessage == "Nothing was found there." && model.recipe.spots.count == 1)
    }

    @Test func `a picked object takes its shadow and reflection with it, unless that's turned off`() async throws {
        let engine = StubEngine()
        engine.computed = try [half(true)]
        engine.withShadow = try half(false)
        let (model, cleanup) = try await openEditor(engine)
        defer { cleanup() }
        let kept = model.removesShadows
        defer { model.removesShadows = kept }
        model.activeTool = .heal
        model.spotPick = .object
        model.removesShadows = true
        await model.pickRegion(at: ImagePoint(x: 0.3, y: 0.4))
        #expect(model.recipe.spots.last?.region?.center == ImagePoint(x: 0.75, y: 0.5))
        model.removesShadows = false
        await model.pickRegion(at: ImagePoint(x: 0.3, y: 0.4))
        #expect(model.recipe.spots.count == 2 && model.recipe.spots.last?.region?.center == ImagePoint(x: 0.25, y: 0.5))
    }

    /// An Objects mask of 300 × 200 pixels, as for the stub's 600 × 400 photo, covering what lies
    /// between `inner` and `outer` image heights from `centre`.
    private func ring(at centre: ImagePoint, outer: Double, inner: Double = 0) throws -> AIMask {
        let (width, height) = (300, 200)
        let aspect = Double(width) / Double(height)
        let pixels = (0 ..< width * height).map { index -> UInt8 in
            let dx = ((Double(index % width) + 0.5) / Double(width) - centre.x) * aspect
            let dy = (Double(index / width) + 0.5) / Double(height) - centre.y
            let distance = (dx * dx + dy * dy).squareRoot()
            return distance <= outer && distance >= inner ? 255 : 0
        }
        let rep = try #require(NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height, bitsPerSample: 8, samplesPerPixel: 1,
            hasAlpha: false, isPlanar: false, colorSpaceName: .deviceWhite, bytesPerRow: width, bitsPerPixel: 8,
        ))
        rep.bitmapData?.update(from: pixels, count: pixels.count)
        let png = try #require(rep.representation(using: .png, properties: [:]))
        return AIMask(
            kind: .objects, provider: "stub", revision: 1, analysisHash: "h", center: centre,
            bitmap: MaskBitmap(png: png, width: width, height: height),
        )
    }

    /// The Healing tool's overlay drawn over a canvas of `size` points, a pixel a point: how opaque
    /// it is at a point of the canvas, and where the photo's points are on it.
    private func drawOverlay(_ model: EditorModel, size: CGSize) throws
        -> (opacity: (CGPoint) -> Double, frame: ImageFrame) {
        model.canvas.updateView(size: size, backingScale: 1)
        let renderer = ImageRenderer(
            content: HealOverlayView().environment(model).frame(width: size.width, height: size.height),
        )
        renderer.scale = 1
        let image = try #require(renderer.cgImage)
        let (width, height) = (image.width, image.height)
        let context = try #require(CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue,
        ))
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        let data = try #require(context.data)
        let pixels = Array(UnsafeBufferPointer(
            start: data.bindMemory(to: UInt8.self, capacity: width * height * 4), count: width * height * 4,
        ))
        let frame = ImageFrame(rect: model.canvas.imageRect(in: size), geometry: model.canvasGeometry)
        return ({ point in
            let (x, y) = (min(max(Int(point.x), 0), width - 1), min(max(Int(point.y), 0), height - 1))
            return Double(pixels[(y * width + x) * 4 + 3]) / 255
        }, frame)
    }

    /// Picks the disc the engine finds about `centre` and draws the Healing tool's overlay with it
    /// selected, its outline traced, then expects its edge outlined, eight ways round, and nothing
    /// drawn over the photo inside it.
    private func expectOutlinedPick(_ model: EditorModel, at centre: ImagePoint, radius: Double) async throws {
        model.activeTool = .heal
        model.spotPick = .object
        await model.pickRegion(at: centre)
        let region = try #require(model.selectedSpot?.region)
        await model.traceOutline(of: region)
        let (opacity, frame) = try drawOverlay(model, size: CGSize(width: 600, height: 400))
        func shown(_ distance: Double, _ angle: Double) -> CGPoint {
            frame.view(ImagePoint(x: centre.x + distance * cos(angle) / 1.5, y: centre.y + distance * sin(angle)))
        }
        let point = 1 / Double(frame.heightScale)
        for angle in stride(from: 0.0, to: 2 * .pi, by: .pi / 4) {
            #expect(opacity(shown(radius / 2, angle)) == 0, "inside the pick, \(angle) radians round")
            let edge = stride(from: -4.0, through: 4, by: 0.5).map { opacity(shown(radius + $0 * point, angle)) }
            #expect(edge.max() ?? 0 > 0.8, "its edge, \(angle) radians round")
        }
    }

    @Test func `a selected pick is outlined, leaving the photo inside it to be seen`() async throws {
        let engine = StubEngine()
        engine.computed = try [ring(at: ImagePoint(x: 0.5, y: 0.5), outer: 0.25)]
        let (model, cleanup) = try await openEditor(engine)
        defer { cleanup() }
        try await expectOutlinedPick(model, at: ImagePoint(x: 0.5, y: 0.5), radius: 0.25)
    }

    @Test func `a selected pick's outline is on it in the cropped photo`() async throws {
        let engine = StubEngine()
        engine.computed = try [ring(at: ImagePoint(x: 0.25, y: 0.5), outer: 0.2)]
        let (model, cleanup) = try await openEditor(engine)
        defer { cleanup() }
        model.setCrop(CropRect(left: 0, top: 0, right: 0.5, bottom: 1))
        let info = try #require(model.info)
        model.canvas.imageSize = GeometryMap(recipe: model.recipe, imageSize: info.pixelSize, lens: nil).outputSize
        #expect(model.canvas.imageSize == PixelSize(width: 300, height: 400))
        try await expectOutlinedPick(model, at: ImagePoint(x: 0.25, y: 0.5), radius: 0.2)
    }

    @Test func `a mask's outline is a closed loop along each of its edges, in the photo's coordinates`() throws {
        let png = try #require(try ring(at: ImagePoint(x: 0.5, y: 0.5), outer: 0.3, inner: 0.15).bitmap.png)
        let loops = EditorModel.outline(ofMask: png).sorted { $0.count > $1.count }
        #expect(loops.count == 2)
        for (loop, radius) in zip(loops, [0.3, 0.15]) {
            let distances = loop.map { hypot(($0.x - 0.5) * 1.5, $0.y - 0.5) }
            #expect(distances.allSatisfy { abs($0 - radius) < 1.5 / 200 }, "the edge \(radius) from the middle")
        }

        // The left half of the frame: closed along the frame's edges.
        let halves = try EditorModel.outline(ofMask: #require(half(true).bitmap.png))
        let edge = try #require(halves.first)
        let (xs, ys) = (edge.map(\.x), edge.map(\.y))
        #expect(halves.count == 1)
        #expect(abs((xs.min() ?? 1) - 0) < 1e-6 && abs((xs.max() ?? 0) - 0.5) < 1e-6)
        #expect(abs((ys.min() ?? 1) - 0) < 1e-6 && abs((ys.max() ?? 0) - 1) < 1e-6)

        let empty = try #require(try ring(at: ImagePoint(x: 0.5, y: 0.5), outer: 0).bitmap.png)
        #expect(EditorModel.outline(ofMask: empty).isEmpty)
    }

    private static let car = FoundThing(
        thing: "car",
        score: 0.6,
        box: ImageRect(x: 0.1, y: 0.5, width: 0.3, height: 0.2),
    )
    private static let sign = FoundThing(
        thing: "sign", score: 0.4, box: ImageRect(x: 0.7, y: 0.2, width: 0.1, height: 0.1),
    )

    @Test func `the thing chosen is outlined, and a click on it removes it by its box`() async throws {
        let engine = StubEngine()
        engine.things = ["car", "sign"]
        engine.found = [Self.car, Self.sign]
        engine.computed = try [half(true)]
        let (model, cleanup) = try await openEditor(engine)
        defer { cleanup() }
        model.activeTool = .heal
        await model.loadThingsToFind()
        #expect(model.thingsToFind == ["car", "sign"])
        model.thingToFind = "car"
        await model.findThings()
        #expect(engine.lastFind == ["car"] && model.foundThings.map(\.thing) == ["car"])
        #expect(model.findMessage == "Found 1: click it to remove it.")
        await model.removeFound(model.foundThings[0])
        #expect(engine.lastRequest?.kind == .objects && engine.lastRequest?.box == Self.car.box)
        let spot = try #require(model.recipe.spots.first)
        #expect(spot.mode == .remove && spot.region != nil)
        #expect(model.history.last?.name == "Remove Car" && model.foundThings.isEmpty)
    }

    @Test func `with nothing chosen, everything is found, removed in one step, and let go when the tool closes`(
    ) async throws {
        let engine = StubEngine()
        engine.things = ["car", "sign"]
        engine.found = [Self.car, Self.sign]
        engine.computed = try [half(true)]
        let (model, cleanup) = try await openEditor(engine)
        defer { cleanup() }
        model.activeTool = .heal
        await model.findThings()
        #expect(engine.lastFind == ["car", "sign"] && model.foundThings.count == 2)
        let steps = model.history.count
        await model.removeAllFound()
        #expect(model.recipe.spots.count == 2 && model.history.count == steps + 1)
        #expect(model.history.last?.name == "Remove Everything Found" && model.foundThings.isEmpty)
        await model.findThings()
        #expect(model.foundThings.count == 2)
        model.activeTool = .edit
        #expect(model.foundThings.isEmpty && model.findMessage == nil)
    }

    @Test func `without its model, Find says which one to download`() async throws {
        let engine = StubEngine()
        engine.findingModel = ModelInfo(
            id: "owlv2-base", name: "OWLv2 (base)", purpose: "Find", downloadBytes: 365_090_755, state: .notDownloaded,
        )
        let (model, cleanup) = try await openEditor(engine)
        defer { cleanup() }
        model.activeTool = .heal
        await model.findThings()
        #expect(model.findMessage == "Finding things needs OWLv2 (base), from Settings › Models.")
        #expect(engine.lastFind == nil && model.foundThings.isEmpty)
    }

    @Test func `a drag brushes a spot that follows the stroke`() async throws {
        let (model, cleanup) = try await openEditor()
        defer { cleanup() }
        model.activeTool = .heal
        let points = (0 ... 40).map { ImagePoint(x: 0.3 + Double($0) * 0.005, y: 0.4) }
        await model.addStroke(points)
        let spot = try #require(model.recipe.spots.first)
        #expect(spot.center == points[0])
        #expect(spot.stroke.count > 4 && spot.stroke.count < points.count, "thinned to a quarter brush apart")
        let end = try #require(spot.points().last)
        #expect(abs(end.x - 0.5) < 0.02 && end.y == 0.4)
        #expect(spot.source.y > 0.4 + spot.radius * 2, "no source found: below the stroke")
        #expect(model.history.last?.name == "Heal Brush")

        // A stroke that barely moves is a click.
        await model.addStroke([ImagePoint(x: 0.7, y: 0.7), ImagePoint(x: 0.7001, y: 0.7)])
        #expect(model.recipe.spots.last?.stroke.isEmpty == true)
    }

    @Test func `Remove Dust heals every speck found, in one step`() async throws {
        let engine = StubEngine()
        engine.dust = [
            DetectedSpot(center: ImagePoint(x: 0.2, y: 0.2), radius: 0.01, strength: 30),
            DetectedSpot(center: ImagePoint(x: 0.7, y: 0.3), radius: 0.02, strength: 12),
        ]
        engine.retouchSource = ImagePoint(x: 0.5, y: 0.5)
        let (model, cleanup) = try await openEditor(engine)
        defer { cleanup() }
        model.activeTool = .heal
        let steps = model.history.count
        await model.removeDust()
        #expect(model.recipe.spots.map(\.center) == engine.dust.map(\.center))
        #expect(model.recipe.spots.allSatisfy { $0.mode == .heal && $0.source == ImagePoint(x: 0.5, y: 0.5) })
        #expect(model.recipe.spots.map(\.radius) == [0.01, 0.02])
        #expect(model.history.count == steps + 1 && model.history.last?.name == "Remove Dust")
        #expect(model.dustMessage == "Healed 2 specks of dust.")
        engine.dust = []
        await model.removeDust()
        #expect(model.dustMessage == "No dust found." && model.recipe.spots.count == 2)
        model.activeTool = .edit
        #expect(model.dustMessage == nil)
    }

    @Test func `Remove Dust across a selection heals the dust its photos share`() async throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let photos = ["A", "B", "C"].map { folder.appending(path: "\($0).ARW") }
        let speck = DetectedSpot(center: ImagePoint(x: 0.3, y: 0.2), radius: 0.01, strength: 20)
        let engine = StubEngine()
        engine.retouchSource = ImagePoint(x: 0.4, y: 0.2)
        let worker = StubEngine()
        worker.retouchSource = ImagePoint(x: 0.35, y: 0.25)
        worker.shootDust = [photos[0]: [speck], photos[1]: [speck]]
        let model = EditorModel(engine: engine)
        model.makeWorkerEngine = { worker }
        photos.forEach { model.library.insert(LibraryItem(url: $0)) }
        model.select(photos[0])
        for _ in 0 ..< 200 where model.info?.url != photos[0] {
            try await Task.sleep(for: .milliseconds(5))
        }
        model.selectAllPhotos()
        model.activeTool = .heal
        await model.removeDustInSelection()
        await model.settingsSync.idle()
        #expect(worker.shootPhotos == photos, "every selected photo is looked at, the open one too")
        #expect(model.recipe.spots.map(\.center) == [speck.center])
        #expect(model.recipe.spots.first?.source == ImagePoint(x: 0.4, y: 0.2))
        #expect(model.history.last?.name == "Remove Dust")
        let other = try #require(model.settingsSync.store.load(for: photos[1]))
        #expect(other.recipe.spots.map(\.center) == [speck.center])
        #expect(other.recipe.spots.first?.source == ImagePoint(x: 0.35, y: 0.25))
        #expect(model.settingsSync.store.load(for: photos[2]) == nil, "no dust there, nothing written")
        #expect(model.dustMessage == "Healed 1 speck of dust in 2 photos.")
        model.undoSync()
        await model.settingsSync.idle()
        #expect(model.settingsSync.store.load(for: photos[1]) == nil)
    }

    @Test func `Visualize Spots shows in the Healing tool only`() async throws {
        let engine = StubEngine()
        let (model, cleanup) = try await openEditor(engine)
        defer { cleanup() }
        model.activeTool = .heal
        model.visualizeSpots = true
        #expect(engine.lastRender?.visualizeSpots == 50)
        model.setSliderValue(.spotVisualize, 80)
        #expect(engine.lastRender?.visualizeSpots == 80)
        #expect(model.recipe[.spotVisualize] == 50, "a tool setting, never in the edit")
        model.activeTool = .edit
        #expect(engine.lastRender?.visualizeSpots == nil)
    }

    @Test func `the sliders change the selected spot, and the next one`() async throws {
        let (model, cleanup) = try await openEditor()
        defer { cleanup() }
        model.activeTool = .heal
        await model.addSpot(at: ImagePoint(x: 0.5, y: 0.5))
        model.setSliderValue(.spotOpacity, 60)
        #expect(model.recipe.spots[0].opacity == 60)
        #expect(model.history.last?.name == "Spot Opacity")
        model.selectedSpotID = nil
        #expect(model.sliderValue(.spotOpacity) == 60, "the next spot's too")
        model.resetSlider(.spotOpacity)
        #expect(model.recipe.spots[0].opacity == 60, "nothing selected: only the next spot's")
        #expect(model.sliderValue(.spotOpacity) == 100)
        #expect(model.recipe[.spotOpacity] == ParameterID.spotOpacity.spec.defaultValue, "never in the edit")
    }

    @Test func `a drag is one step, and Delete removes the selected spot`() async throws {
        let (model, cleanup) = try await openEditor()
        defer { cleanup() }
        model.activeTool = .heal
        await model.addSpot(at: ImagePoint(x: 0.5, y: 0.5))
        let id = try #require(model.selectedSpotID)
        let steps = model.history.count
        model.beginEdit()
        model.updateSpot(id) { $0.center = ImagePoint(x: 0.55, y: 0.5) }
        model.updateSpot(id) { $0.center = ImagePoint(x: 0.6, y: 0.5) }
        model.endEdit(.retouch, "Move Spot")
        #expect(model.history.count == steps + 1 && model.history.last?.name == "Move Spot")
        #expect(model.recipe.spots[0].center == ImagePoint(x: 0.6, y: 0.5))

        #expect(model.canPerform(.deleteMask))
        #expect(model.perform(.deleteMask))
        #expect(model.recipe.spots.isEmpty && model.selectedSpotID == nil)
        model.undo()
        #expect(model.recipe.spots.count == 1)
    }
}
