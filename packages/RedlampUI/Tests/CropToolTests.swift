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
        #expect(model.cropOverlay == .grid)
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
