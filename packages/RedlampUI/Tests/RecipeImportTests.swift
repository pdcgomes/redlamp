import Foundation
import RedlampEngineAPI
import RedlampRecipes
import Testing
@testable import RedlampUI

/// The Recipes panel's import: Lightroom presets beside recipes and look tables, files and
/// folders installed in one pass, and how what happened is told.
@MainActor
struct RecipeImportTests {
    private let root = FileManager.default.temporaryDirectory.appending(path: "recipe-import-\(UUID().uuidString)")

    private func catalog() throws -> RecipeCatalog {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return RecipeCatalog(engine: StubEngine(), library: RecipeLibrary(root: root, includeBundled: false))
    }

    private func write(_ text: String, as file: String) throws -> URL {
        let url = root.appending(path: file)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try text.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    private static func item(_ file: String, _ outcome: RecipeImportSummary.Outcome) -> RecipeImportSummary.Item {
        .init(file: URL(fileURLWithPath: "/Imports/\(file)"), outcome: outcome)
    }

    private static func imported(_ name: String, report: LightroomImportReport? = nil) -> RecipeImportSummary.Outcome {
        .imported(RecipeImport(
            recipe: Recipe(
                id: RecipeNamespace.newLocalID(), name: name, group: report == nil ? "Imported" : "Lightroom",
                includes: [.tone], settings: RecipeSettings(),
            ),
            report: report,
        ))
    }

    /// A photo's sidecar: XMP, but no develop settings.
    static let sidecar = """
    <x:xmpmeta xmlns:x="adobe:ns:meta/">
     <rdf:RDF xmlns:rdf="http://www.w3.org/1999/02/22-rdf-syntax-ns#">
      <rdf:Description rdf:about="" xmlns:xmp="http://ns.adobe.com/xap/1.0/" xmp:Rating="3"/>
     </rdf:RDF>
    </x:xmpmeta>
    """

    @Test func `the import panel offers Lightroom presets beside recipes and look tables`() {
        #expect(RecipeActions.presetType.preferredFilenameExtension == "xmp")
        #expect(RecipeActions.importTypes.contains(RecipeActions.presetType))
        #expect(RecipeActions.importTypes.contains(RecipeActions.recipeType))
        #expect(RecipeActions.lookTableTypes.allSatisfy(RecipeActions.importTypes.contains))
    }

    @Test func `files and folders install in one pass, and what didn't come in is listed`() throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let catalog = try catalog()
        let cube = try write(RecipeLabImportTests.warmCube, as: "warm.cube")
        let sidecar = try write(Self.sidecar, as: "Photos/DSC01234.xmp")
        let revision = catalog.revision

        let summary = catalog.install(contentsOf: [cube, sidecar, sidecar.deletingLastPathComponent()])
        #expect(summary.imported.map(\.recipe.name) == ["Warm"])
        #expect(summary.failures == [
            "DSC01234.xmp: This isn't a Lightroom develop preset",
            "Photos: There are no Lightroom presets in this folder",
        ])
        #expect(catalog.all.map(\.name) == ["Warm"])
        #expect(catalog.revision == revision + 1 && catalog.lastError == nil)
    }

    @Test func `a preset's report shows in a sheet, files that didn't come in in an alert, a clean import in neither`() {
        let report = LightroomImportReport(entries: [.init(setting: "GrainSeed", outcome: .ignored, note: "No seed")])
        let table = Self.item("warm.cube", Self.imported("Warm"))
        let preset = Self.item("Fade.xmp", Self.imported("Fade", report: report))
        let refused = Self.item("Old.xmp", .failed("Lightroom process version 5.0 predates Process 2012"))

        #expect(RecipeActions.message(for: RecipeImportSummary(items: [table])) == .none)
        #expect(RecipeActions.message(for: RecipeImportSummary(items: [table, preset, refused])) == .sheet)
        #expect(RecipeActions.message(for: RecipeImportSummary(items: [table, refused])) == .alert(
            title: "A file couldn't be imported",
            text: "Old.xmp: Lightroom process version 5.0 predates Process 2012",
        ))
        #expect(RecipeActions.message(for: RecipeImportSummary(items: [refused])) == .alert(
            title: "Nothing was imported",
            text: "Old.xmp: Lightroom process version 5.0 predates Process 2012",
        ))
    }
}
