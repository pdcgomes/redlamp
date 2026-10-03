import Foundation
import RedlampEngineAPI
import RedlampRecipes
import simd
import Testing

/// Installing files: look tables in every format, read in the space they were made for
/// exactly as the parsers read them, and recipe files as they are.
struct RecipeLibraryInstallTests {
    private let root = FileManager.default.temporaryDirectory.appending(path: "install-\(UUID().uuidString)")
    private let library: RecipeLibrary

    init() throws {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        library = RecipeLibrary(root: root, includeBundled: false)
    }

    private func write(_ text: String, as file: String) throws -> URL {
        let url = root.appending(path: file)
        try text.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    /// A camera's plain conversion of its log footage to Rec.709 (gamma 2.4).
    private static func cameraToRec709(_ space: CameraLogSpace) -> (SIMD3<Float>) -> SIMD3<Float> {
        { signal in
            LookTableFixtures.bt1886Encode(simd_clamp(
                ColorMath.rec2020ToRec709 * (space.toRec2020 * space.decode(signal)),
                .zero,
                SIMD3(repeating: 1),
            ))
        }
    }

    @Test func `a .cube installs as before, named by its title, with the table the parser reads`() throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let text = LookTableFixtures.cube(size: 17, header: ["TITLE \"Teal and Orange\""], LookTableFixtures.grade)
        let url = try write(text, as: "teal-orange.cube")
        let parsed = try LookTableImport.parseCube(text).table
        let (recipe, issues) = try library.install(contentsOf: url)
        #expect(issues.isEmpty)
        #expect(recipe.name == "Teal and Orange" && recipe.group == "Imported" && recipe.tags == ["lut"])
        #expect(recipe.baseLook?.contentHash == parsed.contentHash)
        #expect(try recipe.embeddedBaseLooks.first?.definition().table == parsed)
        let explicit = try library.install(contentsOf: url, tableSpace: .sRGB).recipe
        #expect(explicit.baseLook?.contentHash == parsed.contentHash)
    }

    @Test func `a .3dl installs as a .cube does, named by its file`() throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let text = LookTableFixtures.threeDL(size: 17, LookTableFixtures.grade)
        let url = try write(text, as: "Lustre Grade.3dl")
        let (recipe, issues) = try library.install(contentsOf: url)
        #expect(issues.isEmpty)
        #expect(recipe.name == "Lustre Grade" && recipe.group == "Imported" && recipe.tags == ["lut"])
        #expect(try recipe.baseLook?.contentHash == LookTableImport.parse3DL(text).contentHash)
        #expect(library.recipe(id: recipe.id) != nil)
        let native = try library.install(contentsOf: url, tableSpace: .displayRec2020).recipe
        #expect(try native.baseLook?.contentHash == LookTableImport.parse3DL(text, space: .displayRec2020).contentHash)
    }

    @Test(arguments: ["cube", "3dl"])
    func `a LUT for log footage installs with a scene-referred Base Look`(format: String) throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let space = CameraLogSpace.vLog
        let text = format == "cube"
            ? LookTableFixtures.cube(size: 33, Self.cameraToRec709(space))
            : LookTableFixtures.threeDL(size: 33, Self.cameraToRec709(space))
        let url = try write(text, as: "V-Log to Rec.709.\(format)")
        let (recipe, issues) = try library.install(contentsOf: url, tableSpace: .cameraLog(space))
        #expect(issues.isEmpty)
        #expect(recipe.name == "V-Log to Rec.709")
        let table = try #require(try recipe.embeddedBaseLooks.first?.definition().table)
        #expect(table.space == .sceneLog && table.size == LookTableImport.storedSize)
        let parsed = format == "cube"
            ? try LookTableImport.parseCube(text, space: .cameraLog(space)).table
            : try LookTableImport.parse3DL(text, space: .cameraLog(space))
        #expect(table == parsed)
        // Scene light in, the camera's display out: middle grey comes back as itself.
        let grey = table.sample(SceneLogEncoding.encode(SIMD3(repeating: 0.18)))
        #expect(abs(grey - SIMD3(repeating: ColorMath.srgbEncode(0.18))).max() < 0.005, "\(grey)")
    }

    @Test func `a HaldCLUT installs as before`() throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appending(path: "graded.png")
        try LookTableImport.writePNG(LookTableFixtures.gradedHald(), to: url)
        let (recipe, _) = try library.install(contentsOf: url)
        #expect(recipe.name == "graded")
        #expect(try recipe.baseLook?.contentHash == LookTableImport.parseHald(LookTableImport.readImage(url))
            .contentHash)
    }

    @Test func `a recipe file installs as itself, whatever the table space`() throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let shared = Recipe(
            id: "example/warm-shadows", name: "Warm Shadows", group: "Shared", includes: [.tone],
            settings: RecipeSettings(values: [.exposure: 0.3]), created: Date(),
        )
        let url = root.appending(path: RecipeFile.fileName(for: shared))
        try RecipeFile.write(shared, to: url)
        let (installed, issues) = try library.install(contentsOf: url, tableSpace: .cameraLog(.appleLog))
        #expect(issues.isEmpty)
        #expect(installed.id == shared.id && installed.settings == shared.settings && installed.baseLook == nil)
        #expect(library.installed.map(\.id) == [shared.id])
        #expect(library.userRecipes.isEmpty)
    }

    @Test func `a broken .3dl isn't installed, and says why`() throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let url = try write("0 512 1023\n0 0 0\n", as: "broken.3dl")
        #expect(throws: LookTableImportError.notA3DL("expected 27 rows, found 1")) {
            try library.install(contentsOf: url)
        }
        #expect(library.all.isEmpty)
    }
}
