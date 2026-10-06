import Foundation
import RedlampEngine
import RedlampEngineAPI
import RedlampRecipes
import RedlampUI
import Testing
@testable import RedlampLab

/// The Recipe Lab's import: a look table into the draft, read in the space chosen on the
/// import panel, as the Recipes panel's import installs it.
@MainActor
struct RecipeLabImportTests {
    private let root = FileManager.default.temporaryDirectory.appending(path: "lab-import-\(UUID().uuidString)")

    /// A 2-point identity `.3dl`: Lustre's 10-bit mesh ends, then rows with blue fastest.
    static let identity3DL = """
    0 1023
    0 0 0
    0 0 1023
    0 1023 0
    0 1023 1023
    1023 0 0
    1023 0 1023
    1023 1023 0
    1023 1023 1023
    """

    /// A warm 2-point `.cube`, red fastest.
    static let warmCube = """
    TITLE "Warm"
    LUT_3D_SIZE 2
    0.1 0 0
    1 0 0
    0.1 1 0
    1 1 0
    0.1 0 0.8
    1 0 0.8
    0.1 1 0.8
    1 1 0.8
    """

    /// A Lab on an empty library in `root`, with a new draft.
    private func lab() throws -> RecipeLabModel {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let engine = try RedlampEngine()
        let catalog = RecipeCatalog(engine: engine, library: RecipeLibrary(root: root, includeBundled: false))
        let model = RecipeLabModel(
            engine: engine, editor: EditorModel(engine: engine, recipes: catalog), root: nil, images: [],
        )
        model.newDraft()
        return model
    }

    private func write(_ text: String, as file: String) throws -> URL {
        let url = root.appending(path: file)
        try text.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    @Test func `a .3dl for log footage becomes the draft's scene-referred Base Look`() throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let model = try lab()
        let space = ImportedTableSpace.cameraLog(.appleLog, output: .sRGB)
        try model.importTable(write(Self.identity3DL, as: "Apple Log.3dl"), space: space)
        let draft = try #require(model.draft)
        let table = try #require(try draft.embeddedBaseLooks.first?.definition().table)
        #expect(table.space == .sceneLog)
        #expect(try table == LookTableImport.parse3DL(Self.identity3DL, space: space))
        #expect(draft.baseLook?.contentHash == table.contentHash)
        #expect(draft.includes.contains(.baseLook) && model.draftIncludes == draft.includes)
        #expect(model.creatorMessage == "Imported a 33-point table")
    }

    @Test func `an sRGB .cube imports as before, and the draft keeps its name, list and settings`() throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let model = try lab()
        model.draft?.name = "Warm Night"
        model.draft?.group = "Night"
        model.draft?.settings.values[.exposure] = 0.4
        try model.importTable(write(Self.warmCube, as: "warm.cube"))
        let draft = try #require(model.draft)
        #expect(draft.name == "Warm Night" && draft.group == "Night" && draft.settings.values == [.exposure: 0.4])
        #expect(draft.includes == RecipeSettingGroup.captureDefaults.union([.baseLook]))
        #expect(try draft.baseLook?.contentHash == LookTableImport.parseCube(Self.warmCube).table.contentHash)
        #expect(model.creatorMessage == "Imported a 17-point table")
    }

    @Test func `a file that isn't a readable look table leaves the draft and says why`() throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let model = try lab()
        let draft = model.draft
        try model.importTable(write("{}", as: "notes.txt"))
        #expect(model.draft == draft)
        #expect(model.creatorMessage == "Couldn't import: notes.txt isn't a .cube, .3dl or HaldCLUT file")
        try model.importTable(write("0 512 1023\n0 0 0\n", as: "short.3dl"))
        #expect(model.draft == draft)
        #expect(model.creatorMessage == "Couldn't import: not a .3dl file: expected 27 rows, found 1")
    }
}
