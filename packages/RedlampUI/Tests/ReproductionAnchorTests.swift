import Foundation
import RedlampDocument
import RedlampEngineAPI
import RedlampRecipes
import Testing
@testable import RedlampUI

/// Redlamp Reproduction's exposure anchor in the editor (CAM-28): each photo gets its own camera's,
/// the calibration's or else the typical one, whether the look is chosen, pasted, synced or applied
/// with a recipe, and keeps it until Update Calibration.
@MainActor
struct ReproductionAnchorTests {
    private let folder = FileManager.default.temporaryDirectory.appending(path: "reproduction-\(UUID().uuidString)")

    private static let calibrated = CameraCalibrations.Entry(
        camera: "Canon EOS R5", stops: 0.82, iso: 100, date: Date(timeIntervalSince1970: 1_791_500_000),
        photo: "target.CR3",
    )

    private func open(
        _ name: String = "IMG_0001.CR3", model: String = "EOS R5",
        cameras: CameraCalibrations = CameraCalibrations(file: nil),
    ) async throws -> EditorModel {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let engine = StubEngine()
        engine.camera = ("Canon", model)
        let editor = EditorModel(engine: engine, cameras: cameras)
        let url = folder.appending(path: name)
        editor.library.insert(LibraryItem(url: url))
        editor.select(url)
        for _ in 0 ..< 200 where editor.info == nil {
            try await Task.sleep(for: .milliseconds(5))
        }
        #expect(editor.info?.cameraName == "Canon \(model)")
        return editor
    }

    @Test func `the store keeps each camera's calibration in its file`() throws {
        defer { try? FileManager.default.removeItem(at: folder) }
        let file = folder.appending(path: "Cameras/Calibrations.json")
        let store = CameraCalibrations(file: file)
        #expect(store.anchor(for: "Canon EOS R5") == .typical(for: "Canon EOS R5"))
        try store.calibrate(Self.calibrated)
        let read = CameraCalibrations(file: file)
        #expect(read.entry(for: "Canon EOS R5") == Self.calibrated)
        #expect(read.anchor(for: "Canon EOS R5") == ExposureAnchor(
            stops: 0.82,
            source: .target,
            camera: "Canon EOS R5",
        ))
        try read.forget("Canon EOS R5")
        #expect(CameraCalibrations(file: file).entries.isEmpty)
    }

    @Test func `choosing the look writes the camera's anchor in the same step, and another look takes it out`(
    ) async throws {
        defer { try? FileManager.default.removeItem(at: folder) }
        let cameras = CameraCalibrations(file: nil)
        let editor = try await open(cameras: cameras)
        let steps = editor.history.count
        editor.setBaseLook(BuiltInBaseLook.reproduction.reference)
        #expect(editor.recipe.exposureAnchor == .typical(for: "Canon EOS R5"))
        #expect(editor.history.count == steps + 1)
        editor.setBaseLook(BuiltInBaseLook.color.reference)
        #expect(editor.recipe.exposureAnchor == nil)
        try cameras.calibrate(Self.calibrated)
        editor.setBaseLook(BuiltInBaseLook.reproduction.reference)
        #expect(editor.recipe.exposureAnchor == ExposureAnchor(stops: 0.82, source: .target, camera: "Canon EOS R5"))
    }

    @Test func `a later calibration reaches the edit only through Update Calibration`() async throws {
        defer { try? FileManager.default.removeItem(at: folder) }
        let cameras = CameraCalibrations(file: nil)
        let editor = try await open(cameras: cameras)
        editor.setBaseLook(BuiltInBaseLook.reproduction.reference)
        #expect(!editor.canUpdateCalibration)
        try cameras.calibrate(Self.calibrated)
        #expect(editor.recipe.exposureAnchor?.source == .typical, "the edit keeps the anchor it was given")
        #expect(editor.canUpdateCalibration)
        editor.updateCalibration()
        #expect(editor.recipe.exposureAnchor?.stops == 0.82 && !editor.canUpdateCalibration)
        editor.undo()
        #expect(editor.recipe.exposureAnchor?.source == .typical)
        editor.redo()
        editor.forgetCalibration()
        #expect(cameras.entries.isEmpty)
        #expect(editor.recipe.exposureAnchor?.stops == 0.82, "forgetting leaves the edit alone")
        #expect(editor.canUpdateCalibration, "and offers the typical anchor back")
    }

    @Test func `a paste brings the look with this photo's anchor, never the source's`() async throws {
        defer { try? FileManager.default.removeItem(at: folder) }
        let editor = try await open(model: "EOS R6")
        var source = EditRecipe()
        source.baseLook = BuiltInBaseLook.reproduction.reference
        source.exposureAnchor = ExposureAnchor(stops: 0.5, source: .target, camera: "Nikon Z 8")
        editor.paste(source, SettingsSelection(items: ["look.baseLook"]), name: "Paste Settings")
        #expect(editor.recipe.baseLook.isReproduction)
        #expect(editor.recipe.exposureAnchor == .typical(for: "Canon EOS R6"))
    }

    @Test func `a recipe with the look gives this photo's anchor, and its Amount stays adjustable`() async throws {
        defer { try? FileManager.default.removeItem(at: folder) }
        let editor = try await open()
        let recipe = Recipe(
            id: "local/test/reproduction", name: "Copy Stand", group: "Mine", includes: [.baseLook],
            settings: RecipeSettings(), baseLook: BuiltInBaseLook.reproduction.reference,
        )
        editor.applyRecipe(recipe)
        #expect(editor.recipe.exposureAnchor == .typical(for: "Canon EOS R5"))
        #expect(editor.recipeAmount == 100)
        let captured = Recipe.capture(editor.recipe, name: "Mine", includes: Set(RecipeSettingGroup.allCases))
        #expect(captured.baseLook?.isReproduction == true)
        let file = try String(decoding: JSONEncoder().encode(captured), as: UTF8.self)
        #expect(!file.contains("exposureAnchor") && !file.contains("Canon"), "a .redrecipe holds no anchor")
    }

    @Test func `a sync gives each photo its own camera's anchor`() async throws {
        defer { try? FileManager.default.removeItem(at: folder) }
        let editor = try await open("A.CR3")
        let (b, c) = (folder.appending(path: "B.NEF"), folder.appending(path: "C.JPG"))
        [b, c].forEach { editor.library.insert(LibraryItem(url: $0)) }
        editor.settingsSync.photoAnchor = { url in
            url == c ? nil : ExposureAnchor(stops: 0.7, source: .target, camera: "Nikon Z 8")
        }
        editor.setBaseLook(BuiltInBaseLook.reproduction.reference)
        editor.selectAllPhotos()
        editor.copySelection = .default
        editor.syncSettings()
        await editor.settingsSync.idle()
        let store = SidecarStore()
        #expect(store.load(for: b)?.recipe.baseLook.isReproduction == true)
        #expect(store.load(for: b)?.recipe.exposureAnchor == ExposureAnchor(
            stops: 0.7,
            source: .target,
            camera: "Nikon Z 8",
        ))
        #expect(store.load(for: c)?.recipe.baseLook.isReproduction == true)
        #expect(store.load(for: c)?.recipe.exposureAnchor == nil, "a bitmap has none")
        editor.copySelection = .default
    }
}
