import Foundation
import RedlampEngineAPI
import Testing
@testable import RedlampUI

/// The Crop & Straighten tool's editing: aspects, Constrain to Image, turns and flips.
@MainActor
struct CropToolTests {
    private func openModel() async throws -> EditorModel {
        let folder = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let model = EditorModel(engine: StubEngine())
        model.select(folder.appending(path: "IMG_0001.ARW"))
        for _ in 0 ..< 200 where model.info == nil {
            try await Task.sleep(for: .milliseconds(5))
        }
        try #require(model.info != nil)
        model.activeTool = .crop
        // The overlay choices are the app's, kept in user defaults: each test starts from Lightroom's.
        model.cropOverlayChoices = CropOverlayChoices()
        return model
    }

    private func expectNear(_ a: Double, _ b: Double, _ note: String = "") {
        #expect(abs(a - b) < 1e-6, "\(a) vs \(b) \(note)")
    }

    @Test func `an aspect fits the largest centred crop`() async throws {
        let model = try await openModel()
        model.setCropAspect(.square)
        let crop = model.recipe.crop
        expectNear(model.pixelAspect(of: crop), 1)
        expectNear(crop.height, 1, "the 600 x 400 frame's full height")
        expectNear(crop.center.x, 0.5)
        #expect(model.history.last?.name == "Crop Aspect: \(CropAspect.square.title)")
    }

    @Test func `straightening keeps the crop inside the photo, and straightening back restores it`() async throws {
        let model = try await openModel()
        model.setValue(.cropAngle, 8)
        let tilted = model.recipe.crop
        #expect(tilted.width < 1 && tilted.height < 1)
        let info = try #require(model.info)
        #expect(GeometryMap(recipe: model.recipe, imageSize: info.pixelSize, lens: nil).staysInsideImage)
        expectNear(model.pixelAspect(of: tilted), 1.5, "the frame's aspect is kept")
        model.setValue(.cropAngle, 0)
        #expect(model.recipe.crop == .full)
    }

    @Test func `without Constrain to Image the crop stays as drawn`() async throws {
        let model = try await openModel()
        model.constrainCropToImage = false
        model.setValue(.cropAngle, 8)
        #expect(model.recipe.crop == .full)
    }

    @Test func `quarter turns and flips carry the crop with the frame`() async throws {
        let model = try await openModel()
        model.constrainCropToImage = false
        model.setCrop(CropRect(left: 0.1, top: 0.2, right: 0.5, bottom: 0.6))
        model.rotate(clockwise: true)
        #expect(model.recipe.orientation == ImageOrientation(quarterTurns: 1))
        let turned = model.recipe.crop
        expectNear(turned.left, 0.4)
        expectNear(turned.top, 0.1)
        expectNear(turned.right, 0.8)
        expectNear(turned.bottom, 0.5)
        model.rotate(clockwise: false)
        #expect(model.recipe.orientation.isIdentity)
        expectNear(model.recipe.crop.left, 0.1)
        expectNear(model.recipe.crop.bottom, 0.6)

        model.setValue(.cropAngle, 5)
        model.flip(horizontally: true)
        expectNear(model.recipe.crop.left, 0.5)
        expectNear(model.recipe.crop.right, 0.9)
        expectNear(model.recipe[.cropAngle], -5, "mirrored, the angle turns the other way")
        #expect(model.history.last?.name == "Flip Horizontal")
    }

    @Test func `canvas points map to the photo through the crop`() async throws {
        let model = try await openModel()
        model.constrainCropToImage = false
        model.setCrop(CropRect(left: 0, top: 0, right: 0.5, bottom: 1))
        model.activeTool = .edit
        let point = try #require(model.imagePoint(forCanvas: CGPoint(x: 0.5, y: 0.5)))
        expectNear(point.x, 0.25)
        expectNear(point.y, 0.5)
    }

    @Test func `in the crop tool O cycles the overlay and X swaps the crop instead of rejecting`() async throws {
        let model = try await openModel()
        #expect(model.cropOverlay == .thirds)
        #expect(model.perform(.maskOverlay))
        #expect(model.cropOverlay == .diagonal)
        #expect(model.perform(.maskOverlayColor))
        #expect(model.cropOverlayTurns == 1)

        model.setCropAspect(.square)
        model.setCrop(CropRect(left: 0.2, top: 0, right: 0.6, bottom: 0.9))
        let before = model.pixelAspect(of: model.recipe.crop)
        #expect(model.perform(.flagReject))
        expectNear(model.pixelAspect(of: model.recipe.crop), 1 / before, "portrait and landscape trade places")
        #expect(model.currentMetadata.flag == nil, "the photo isn't rejected")

        let swapped = model.recipe.crop
        model.activeTool = .edit
        model.perform(.flagReject)
        #expect(model.recipe.crop == swapped, "outside the crop tool X is Reject again")
    }

    @Test func `O cycles the overlays in Lightroom's order, then wraps`() async throws {
        let model = try await openModel()
        model.cropOverlay = .grid
        var visited = [model.cropOverlay]
        for _ in CropOverlay.allCases {
            #expect(model.perform(.maskOverlay))
            visited.append(model.cropOverlay)
        }
        #expect(visited == [
            .grid,
            .thirds,
            .diagonal,
            .goldenTriangle,
            .goldenRatio,
            .goldenSpiral,
            .aspectRatios,
            .grid,
        ])
    }

    @Test func `the O key skips overlays not chosen, and one left out stays until it is pressed`() async throws {
        let model = try await openModel()
        defer { model.cropOverlayChoices = CropOverlayChoices() }
        for overlay in [CropOverlay.grid, .diagonal, .goldenRatio, .goldenSpiral] {
            model.cropOverlayChoices[overlay] = false
        }
        var visited = [model.cropOverlay]
        for _ in 0 ..< 4 {
            #expect(model.perform(.maskOverlay))
            visited.append(model.cropOverlay)
        }
        #expect(visited == [.thirds, .goldenTriangle, .aspectRatios, .thirds, .goldenTriangle])

        model.cropOverlayChoices[.goldenTriangle] = false
        #expect(model.cropOverlay == .goldenTriangle, "still shown, though no longer chosen")
        model.perform(.maskOverlay)
        #expect(model.cropOverlay == .aspectRatios)
        // One picked from the Overlay menu that isn't chosen shows too; O goes on from there.
        model.cropOverlay = .goldenSpiral
        model.perform(.maskOverlay)
        #expect(model.cropOverlay == .aspectRatios)
        model.perform(.maskOverlay)
        #expect(model.cropOverlay == .thirds)
    }

    @Test func `the overlays stay in the crop's frame at any Angle, in landscape and portrait`() async throws {
        let landscape = try await openModel()
        let portrait = try await openModel()
        portrait.swapCropOrientation()
        let turned = try await openModel()
        turned.rotate(clockwise: true)
        for (model, isPortrait) in [(landscape, false), (portrait, true), (turned, true)] {
            for angle in [-45.0, -12.5, 0, 7, 30, 45] {
                model.setValue(.cropAngle, angle)
                // One point a pixel, so the outlines' ratios are measured in the photo's pixels.
                let size = model.cropFrameSize
                let frame = CGRect(x: 0, y: 0, width: Double(size.width), height: Double(size.height))
                let rect = CropOverlayView.rect(of: model.recipe.crop, in: frame)
                let inside = rect.insetBy(dx: -1e-6, dy: -1e-6)
                #expect((rect.height > rect.width) == isPortrait, "\(rect) at \(angle)°")
                for (outline, ratio) in zip(CropOverlay.aspectOutlines(in: rect), CropOverlay.AspectRatio.allCases) {
                    #expect(inside.contains(outline), "\(outline) outside \(rect) at \(angle)°")
                    let long = max(outline.width, outline.height), short = min(outline.width, outline.height)
                    #expect(abs(long - short * ratio.value) <= 1, "\(ratio.title) is \(outline.size) at \(angle)°")
                }
                for turns in 0 ..< 8 {
                    for arc in GoldenSpiral(in: rect, turns: turns).arcs {
                        #expect([arc.start, arc.end, arc.control1, arc.control2].allSatisfy(inside.contains))
                    }
                }
            }
        }
    }

    @Test func `⇧O turns the golden spiral through eight orientations, then back to the first`() async throws {
        let model = try await openModel()
        model.cropOverlay = .goldenSpiral
        let rect = CGRect(x: 0, y: 0, width: 600, height: 400)
        var spirals: [GoldenSpiral] = []
        for _ in 0 ..< 8 {
            spirals.append(GoldenSpiral(in: rect, turns: model.cropOverlayTurns))
            #expect(model.perform(.maskOverlayColor))
        }
        for (index, spiral) in spirals.enumerated() {
            #expect(!spirals[..<index].contains(spiral), "orientation \(index) repeats an earlier one")
        }
        #expect(GoldenSpiral(in: rect, turns: model.cropOverlayTurns) == spirals[0])
    }

    @Test func `straightening levels a drawn horizon or vertical`() async throws {
        let model = try await openModel()
        let radians = 10.0 * .pi / 180
        // A horizon falling 10° to the right is levelled by turning 10° back.
        model.straighten(from: .zero, to: CGPoint(x: 100 * cos(radians), y: 100 * sin(radians)))
        expectNear(model.recipe[.cropAngle], -10)
        #expect(model.history.last?.name == "Straighten: 0.00° → -10.00°")
        #expect(model.history.last?.action == .straighten)
        #expect(model.recipe.crop.width < 1, "constrained to the photo")
        // Drawn the other way, the same line.
        model.straighten(from: CGPoint(x: 100 * cos(radians), y: 100 * sin(radians)), to: .zero)
        expectNear(model.recipe[.cropAngle], -20)
        // A near-vertical edge 10° off is made vertical.
        model.setValue(.cropAngle, 0)
        let steep = 80.0 * .pi / 180
        model.straighten(from: .zero, to: CGPoint(x: 100 * cos(steep), y: 100 * sin(steep)))
        expectNear(model.recipe[.cropAngle], 10)
        #expect(!model.isStraightening)
    }

    @Test func `guided upright corrects from drawn guides, and Off removes it`() async throws {
        let model = try await openModel()
        model.activeTool = .edit
        model.isPlacingGuides = true
        // Two edges that lean in towards the top, as a building shot from below.
        model.addGuide(GuideLine(start: ImagePoint(x: 0.27, y: 0.15), end: ImagePoint(x: 0.25, y: 0.85)))
        model.addGuide(GuideLine(start: ImagePoint(x: 0.73, y: 0.15), end: ImagePoint(x: 0.75, y: 0.85)))
        #expect(model.recipe[.transformVertical] < -5, "vertical \(model.recipe[.transformVertical])")
        #expect(model.history.last?.name == "Guided Upright")
        #expect(model.uprightGuides.count == 2)
        #expect(model.perform(.cancel))
        #expect(!model.isPlacingGuides)
        model.clearUpright()
        #expect(model.recipe.isDefault(.transformVertical) && model.uprightGuides.isEmpty)
    }

    @Test func `automatic upright corrects from the photo's edges, or leaves it when there are none`() async throws {
        let engine = StubEngine()
        let folder = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let model = EditorModel(engine: engine)
        model.select(folder.appending(path: "IMG_0001.ARW"))
        for _ in 0 ..< 200 where model.info == nil {
            try await Task.sleep(for: .milliseconds(5))
        }
        model.applyUpright(.vertical)
        try await Task.sleep(for: .milliseconds(50))
        #expect(model.recipe.isDefault(.transformVertical) && model.history.last?.name.hasPrefix("Upright") != true)

        // Four edges that lean in towards the top, as a building shot from below.
        engine.detectedLines = [0.2, 0.4, 0.6, 0.8].map { x in
            let lean = (x - 0.5) * 0.06
            return DetectedLine(
                line: GuideLine(start: ImagePoint(x: x - lean, y: 0.1), end: ImagePoint(x: x + lean, y: 0.9)),
                strength: 200,
            )
        }
        model.applyUpright(.vertical)
        for _ in 0 ..< 100 where model.history.last?.name != "Upright: Vertical" {
            try await Task.sleep(for: .milliseconds(5))
        }
        #expect(model.recipe[.transformVertical] < -5, "vertical \(model.recipe[.transformVertical])")
        #expect(model.history.last?.name == "Upright: Vertical")
    }

    @Test func `the process version is changed only on request, and can be undone`() async throws {
        let model = try await openModel()
        #expect(model.recipe.processVersion == EditRecipe.currentProcessVersion)
        model.setProcessVersion(3)
        #expect(model.recipe.processVersion == 3)
        #expect(model.history.last?.name == "Process Version: Version \(EditRecipe.currentProcessVersion) → Version 3")
        model.undo()
        #expect(model.recipe.processVersion == EditRecipe.currentProcessVersion)
    }

    @Test func `reset removes the crop, angle and turns`() async throws {
        let model = try await openModel()
        model.setValue(.cropAngle, 3)
        model.rotate(clockwise: true)
        model.resetCrop()
        #expect(model.recipe.crop == .full && model.recipe.orientation.isIdentity)
        #expect(model.recipe.isDefault(.cropAngle))
    }
}

/// The composition guides' geometry in the crop's rectangle on screen.
struct CropOverlayTests {
    /// Crops on screen: landscape, portrait, square, a panorama and a small golden portrait.
    private static let frames = [
        CGRect(x: 10, y: 20, width: 600, height: 400),
        CGRect(x: 0, y: 0, width: 400, height: 600),
        CGRect(x: 5, y: 5, width: 300, height: 300),
        CGRect(x: -40, y: 12.5, width: 1000, height: 90),
        CGRect(x: 0, y: 0, width: 61.8, height: 100),
    ]

    private func expectInside(_ point: CGPoint, _ rect: CGRect, _ note: String = "") {
        let slack = 1e-9 * max(rect.width, rect.height)
        #expect(rect.insetBy(dx: -slack, dy: -slack).contains(point), "\(point) outside \(rect) \(note)")
    }

    /// The corner a spiral winds into, and whether it winds clockwise on screen.
    private struct Eye: Hashable {
        var right: Bool
        var bottom: Bool
        var clockwise: Bool

        init(_ spiral: GoldenSpiral, in rect: CGRect) {
            let first = spiral.arcs[0], last = spiral.arcs[spiral.arcs.count - 1]
            let from = CGPoint(x: first.start.x - first.center.x, y: first.start.y - first.center.y)
            let to = CGPoint(x: first.end.x - first.center.x, y: first.end.y - first.center.y)
            right = last.end.x > rect.midX
            bottom = last.end.y > rect.midY
            clockwise = from.x * to.y - from.y * to.x > 0
        }
    }

    @Test func `the golden spiral winds into each corner both ways, the longer side cut first`() {
        for rect in Self.frames.prefix(2) {
            let eyes = (0 ..< 8).map { Eye(GoldenSpiral(in: rect, turns: $0), in: rect) }
            #expect(Set(eyes).count == 8, "\(rect)")
            let corners = eyes.prefix(4).map { [$0.right, $0.bottom] }
            #expect(corners == [[true, true], [false, true], [false, false], [true, false]], "BR, BL, TL, TR")

            let first = GoldenSpiral(in: rect, turns: 0).arcs[0]
            if rect.width > rect.height {
                #expect(abs(first.end.y - first.start.y) == rect.height, "a landscape crop's first square is as tall")
            } else {
                #expect(abs(first.end.x - first.start.x) == rect.width, "a portrait crop's first square is as wide")
            }
        }
    }

    @Test func `the golden spiral and its squares stay inside the crop, as one unbroken curve`() {
        for rect in Self.frames {
            for turns in 0 ..< 8 {
                let spiral = GoldenSpiral(in: rect, turns: turns)
                #expect(spiral.arcs.count > 5)
                for (index, arc) in spiral.arcs.enumerated() {
                    for point in [arc.center, arc.start, arc.end, arc.control1, arc.control2] {
                        expectInside(point, rect, "turn \(turns)")
                    }
                    if index > 0 {
                        #expect(arc.start == spiral.arcs[index - 1].end)
                    }
                }
                for divider in spiral.dividers {
                    expectInside(divider.start, rect)
                    expectInside(divider.end, rect)
                }
            }
        }
    }

    @Test func `in a golden rectangle the spiral's squares are square and its arcs circular`() {
        let golden = (1 + sqrt(5)) / 2
        let rects = [
            CGRect(x: 0, y: 0, width: 100 * golden, height: 100),
            CGRect(x: 0, y: 0, width: 100, height: 100 * golden),
        ]
        for rect in rects {
            for turns in 0 ..< 4 {
                for arc in GoldenSpiral(in: rect, turns: turns).arcs {
                    let across = abs(arc.start.x - arc.center.x) + abs(arc.end.x - arc.center.x)
                    let down = abs(arc.start.y - arc.center.y) + abs(arc.end.y - arc.center.y)
                    #expect(abs(across - down) < 1e-6, "\(across) × \(down) in \(rect), turn \(turns)")
                }
            }
        }
    }

    @Test func `each aspect outline keeps its ratio, centred in the crop, as large as fits and turned with it`() {
        for rect in Self.frames {
            let outlines = CropOverlay.aspectOutlines(in: rect)
            #expect(outlines.count == CropOverlay.AspectRatio.allCases.count)
            for (outline, ratio) in zip(outlines, CropOverlay.AspectRatio.allCases) {
                let long = max(outline.width, outline.height), short = min(outline.width, outline.height)
                #expect(abs(long - short * ratio.value) < 1e-9 * long, "\(ratio.title) is \(outline.size) in \(rect)")
                #expect(rect.height > rect.width ? outline.height >= outline.width : outline.width >= outline.height)
                expectInside(CGPoint(x: outline.minX, y: outline.minY), rect)
                expectInside(CGPoint(x: outline.maxX, y: outline.maxY), rect)
                #expect(abs(outline.midX - rect.midX) < 1e-9 && abs(outline.midY - rect.midY) < 1e-9)
                #expect(
                    abs(outline.width - rect.width) < 1e-9 || abs(outline.height - rect.height) < 1e-9,
                    "\(ratio) spans the crop one way",
                )
            }
        }
        let common: [Double] = [1, 5.0 / 4, 7.0 / 5, 3.0 / 2, 4.0 / 3, 16.0 / 9]
        let values = CropOverlay.AspectRatio.allCases.map(\.value)
        #expect(common.allSatisfy(values.contains), "1 × 1, 4 × 5, 5 × 7, 2 × 3, 4 × 3, 16 × 9")
    }
}
