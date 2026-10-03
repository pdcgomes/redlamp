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

/// Lightroom develop presets: recognised by their content, converted by `LightroomPreset`,
/// listed in their own group or Lightroom's with the converter's report, and imported a
/// folder at a time, each file that can't come in listed with the reason.
struct RecipeLibraryPresetTests {
    private let root = FileManager.default.temporaryDirectory.appending(path: "presets-\(UUID().uuidString)")
    private let library: RecipeLibrary

    init() throws {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        library = RecipeLibrary(root: root, includeBundled: false)
    }

    /// A develop preset as Lightroom writes one: settings as `crs` attributes, the name and
    /// group as language alternatives.
    static func preset(
        processVersion: String,
        name: String = "Warm Fade",
        group: String? = "Film Looks",
        settings: [String: String] = ["Exposure2012": "+0.50", "Contrast2012": "+12"],
    ) -> String {
        func alternative(_ property: String, _ value: String) -> String {
            """
               <crs:\(property)>
                <rdf:Alt>
                 <rdf:li xml:lang="x-default">\(value)</rdf:li>
                </rdf:Alt>
               </crs:\(property)>
            """
        }
        let attributes = settings.sorted { $0.key < $1.key }.map { "   crs:\($0.key)=\"\($0.value)\"" }
        return """
        <x:xmpmeta xmlns:x="adobe:ns:meta/">
         <rdf:RDF xmlns:rdf="http://www.w3.org/1999/02/22-rdf-syntax-ns#">
          <rdf:Description rdf:about=""
            xmlns:crs="http://ns.adobe.com/camera-raw-settings/1.0/"
           crs:PresetType="Normal"
           crs:UUID="6C1B5A3E9F0D4C2B8A7E6D5C4B3A2910"
           crs:SupportsAmount="False"
           crs:Version="15.0"
           crs:ProcessVersion="\(processVersion)"
        \(attributes.joined(separator: "\n"))
           crs:HasSettings="True">
        \(alternative("Name", name))
        \(group.map { alternative("Group", $0) } ?? "")
          </rdf:Description>
         </rdf:RDF>
        </x:xmpmeta>
        """
    }

    /// A photo's sidecar, as a camera or a photo manager writes one: a rating and keywords.
    static let sidecar = """
    <x:xmpmeta xmlns:x="adobe:ns:meta/">
     <rdf:RDF xmlns:rdf="http://www.w3.org/1999/02/22-rdf-syntax-ns#">
      <rdf:Description rdf:about=""
        xmlns:xmp="http://ns.adobe.com/xap/1.0/"
        xmlns:dc="http://purl.org/dc/elements/1.1/"
       xmp:Rating="4"
       xmp:Label="Green">
       <dc:subject>
        <rdf:Bag>
         <rdf:li>harbour</rdf:li>
        </rdf:Bag>
       </dc:subject>
      </rdf:Description>
     </rdf:RDF>
    </x:xmpmeta>
    """

    /// Whether `LightroomPreset.convert` converts presets yet: the contract's stub refuses
    /// every one.
    static var converts: Bool {
        (try? LightroomPreset.convert(Data(preset(processVersion: "11.0").utf8))) != nil
    }

    private func write(_ text: String, as file: String) throws -> URL {
        let url = root.appending(path: file)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try text.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    private static func converted(name: String, group: String, values: [ParameterID: Double] = [.exposure: 0.5])
        -> LightroomPresetImport {
        let recipe = Recipe(
            id: "lightroom/6c1b5a3e", name: name, group: group, includes: [.tone],
            settings: RecipeSettings(values: values),
        )
        return LightroomPresetImport(recipe: recipe, report: LightroomImportReport(processVersion: "11.0", entries: [
            .init(setting: "Exposure2012", outcome: .mapped),
            .init(setting: "GrainSeed", outcome: .ignored, note: "Redlamp's grain has no seed"),
        ]))
    }

    @Test func `a preset the converter refuses isn't installed, and says why`() throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let url = try write(Self.preset(processVersion: "5.0"), as: "Old Matte.xmp")
        #expect(try LightroomPreset.isPreset(Data(contentsOf: url)))
        #expect(throws: LightroomPresetError.self) { try library.install(contentsOf: url) }
        #expect(library.all.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: library.locations.recipes.path))
    }

    @Test func `a photo's .xmp sidecar isn't taken for a preset`() throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let url = try write(Self.sidecar, as: "DSC01234.xmp")
        #expect(try !LightroomPreset.isPreset(Data(contentsOf: url)))
        #expect(throws: LightroomPresetError.notAPreset) { try library.install(contentsOf: url) }
        #expect(throws: LightroomPresetError.notAPreset) { try RecipeLibrary.read(importing: url) }
        #expect(library.all.isEmpty)
    }

    @Test func `a converted preset joins your recipes in its own group, with its report`() throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let converted = Self.converted(name: "Warm Fade", group: "Film Looks")
        let installed = try library.install(RecipeImport(converted, file: root.appending(path: "Warm Fade.xmp")))
        #expect(installed.report == converted.report && installed.issues.isEmpty)
        #expect(installed.recipe.isLocal && installed.recipe.name == "Warm Fade")
        #expect(installed.recipe.settings == converted.recipe.settings)
        #expect(library.userRecipes.map(\.id) == [installed.recipe.id])
        #expect(library.sections.map(\.name) == ["Film Looks"])
    }

    @Test func `a preset without a name or group is named after its file and listed under Lightroom`() throws {
        let file = URL(fileURLWithPath: "/Presets/Soft Light.xmp")
        let imported = try RecipeImport(Self.converted(name: " ", group: ""), file: file)
        #expect(imported.recipe.name == "Soft Light" && imported.recipe.group == "Lightroom")
        #expect(imported.recipe.isLocal && imported.recipe.version == 1)
        let defaulted = try RecipeImport(Self.converted(name: "Fade", group: "My Recipes"), file: file)
        #expect(defaulted.recipe.group == "Lightroom")
    }

    @Test func `a value out of range comes in clamped, and says so`() throws {
        let imported = try RecipeImport(
            Self.converted(name: "Blown", group: "Lightroom", values: [.exposure: 9]),
            file: root.appending(path: "Blown.xmp"),
        )
        #expect(imported.recipe.settings.values[.exposure] == ParameterID.exposure.spec.range.upperBound)
        #expect(imported.issues.map(\.severity) == [.warning])
    }

    @Test func `a folder's presets are found in its subfolders, leaving out sidecars and other files`() throws {
        defer { try? FileManager.default.removeItem(at: root) }
        _ = try write(Self.preset(processVersion: "11.0", name: "Amber"), as: "Pack/Warm/Amber.xmp")
        _ = try write(Self.preset(processVersion: "11.0", name: "Frost"), as: "Pack/Frost.XMP")
        _ = try write(Self.preset(processVersion: "11.0", name: "Hidden"), as: "Pack/.Hidden.xmp")
        _ = try write(Self.sidecar, as: "Pack/DSC01234.xmp")
        _ = try write("{}", as: "Pack/notes.txt")
        let found = RecipeLibrary.presets(in: root.appending(path: "Pack"))
        #expect(found.map(\.lastPathComponent) == ["Frost.XMP", "Amber.xmp"])
    }

    @Test func `importing files and folders installs what it can and lists the rest with the reason`() throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let cube = try write(LookTableFixtures.cube(size: 2, header: ["TITLE \"Teal\""]) { $0 }, as: "teal.cube")
        let old = Self.preset(processVersion: "5.0", name: "Old Matte")
        _ = try write(old, as: "Pack/Old Matte.xmp")
        _ = try write(Self.sidecar, as: "Photos/DSC01234.xmp")
        let refusal = try #require(throws: LightroomPresetError.self) { try LightroomPreset.convert(Data(old.utf8)) }

        let summary = library.install(contentsOf: [
            cube, root.appending(path: "Pack"), root.appending(path: "Photos"),
            root.appending(path: "missing.redrecipe"),
        ])
        #expect(summary.imported.map(\.recipe.name) == ["Teal"])
        #expect(summary.failures.prefix(2) == [
            "Old Matte.xmp: \(refusal)", "Photos: There are no Lightroom presets in this folder",
        ])
        #expect(summary.failures.last?.hasPrefix("missing.redrecipe: The file") == true)
        #expect(library.all.map(\.name) == ["Teal"] && library.all.first?.id == summary.imported.first?.recipe.id)
    }

    @Test(.enabled(if: converts))
    func `a Process 2012 preset installs in its own group, with the converter's report`() throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let text = Self.preset(processVersion: "11.0")
        let url = try write(text, as: "warm-fade.xmp")
        let converted = try LightroomPreset.convert(Data(text.utf8))
        let installed = try library.install(RecipeLibrary.read(importing: url))
        #expect(installed.report == converted.report)
        #expect(installed.recipe.name == "Warm Fade" && installed.recipe.group == "Film Looks")
        #expect(library.userRecipes.map(\.id) == [installed.recipe.id])
        #expect(library.sections.map(\.name) == ["Film Looks"])
    }
}

/// Your recipes in the lists their groups name, as the Recipes panel shows them.
struct RecipeLibrarySectionTests {
    private let root = FileManager.default.temporaryDirectory.appending(path: "sections-\(UUID().uuidString)")

    @Test func `your recipes are listed by group, My Recipes first, then your other lists by name`() throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let library = RecipeLibrary(root: root)
        let bundledGroup = try #require(BuiltInRecipes.all.first?.group)
        let recipes = [
            ("Mine", "My Recipes"), ("Amber", "Lightroom"), ("Ash", "Analog Pack"), ("Odd", "Favorites"),
            ("Blank", " "), ("Shared", bundledGroup),
        ]
        for (name, group) in recipes {
            try library.save(Recipe(
                id: RecipeNamespace.newLocalID(), name: name, group: group, includes: [.tone],
                settings: RecipeSettings(values: [.exposure: 0.1]),
            ))
        }
        let sections = library.sections
        #expect(sections.prefix(3).map(\.name) == ["My Recipes", "Analog Pack", "Lightroom"])
        #expect(sections[0].recipes.map(\.name) == ["Blank", "Mine", "Odd"])
        let shared = sections.filter { $0.name == bundledGroup }
        #expect(shared.count == 1)
        #expect(shared.first?.recipes.last?.name == "Shared")
        #expect(shared.first?.recipes.dropLast().allSatisfy(\.isBundled) == true)
    }
}

/// What an import says: a preset's report in words, the headline, where the recipes are
/// listed, and each file as the CLI prints it.
struct RecipeImportSummaryTests {
    static let report = LightroomImportReport(processVersion: "11.0", entries: [
        .init(setting: "Exposure2012", outcome: .mapped),
        .init(setting: "Clarity2012", outcome: .approximated, note: "Redlamp's Clarity is edge-aware"),
        .init(setting: "Contrast2012", outcome: .mapped),
        .init(setting: "GrainSeed", outcome: .ignored, note: "Redlamp's grain has no seed"),
        .init(setting: "LensProfileEnable", outcome: .ignored, note: "  "),
    ])

    private static func recipe(_ name: String, group: String = "Lightroom", id: String? = nil) -> Recipe {
        Recipe(
            id: id ?? RecipeNamespace.newLocalID(), name: name, group: group, includes: [.tone],
            settings: RecipeSettings(),
        )
    }

    private static func item(_ file: String, _ outcome: RecipeImportSummary.Outcome) -> RecipeImportSummary.Item {
        .init(file: URL(fileURLWithPath: "/Presets/\(file)"), outcome: outcome)
    }

    @Test func `a report reads as a tally, then each setting under what happened to it`() {
        let summary = LightroomReportSummary(Self.report)
        #expect(summary.tally == "2 mapped, 1 approximated, 2 ignored")
        #expect(summary.sections.map(\.title) == ["Approximated", "Ignored", "Mapped"])
        #expect(summary.sections[1].lines == ["GrainSeed: Redlamp's grain has no seed", "LensProfileEnable"])
        #expect(summary.lines == [
            "2 mapped, 1 approximated, 2 ignored (Lightroom process version 11.0)",
            "Approximated:",
            "  Clarity2012: Redlamp's Clarity is edge-aware",
            "Ignored:",
            "  GrainSeed: Redlamp's grain has no seed",
            "  LensProfileEnable",
            "Mapped:",
            "  Exposure2012",
            "  Contrast2012",
        ])
    }

    @Test func `a report leaves out the outcomes no setting had`() {
        let mapped = LightroomReportSummary(LightroomImportReport(entries: [.init(
            setting: "Vibrance",
            outcome: .mapped,
        )]))
        #expect(mapped.tally == "1 mapped" && mapped.lines == ["1 mapped", "Mapped:", "  Vibrance"])
        let empty = LightroomReportSummary(LightroomImportReport())
        #expect(empty.tally == "No settings" && empty.sections.isEmpty && empty.lines == ["No settings"])
    }

    @Test func `the headline counts what came in, and says where it's listed`() {
        let preset = RecipeImport(recipe: Self.recipe("Warm Fade"), report: Self.report)
        let other = RecipeImport(recipe: Self.recipe("Teal", group: "Imported"))
        let shared = RecipeImport(recipe: Self.recipe("Shared", group: "Portrait", id: "example/shared"))
        let presets = RecipeImportSummary(items: [
            Self.item("a.xmp", .imported(preset)),
            Self.item("b.xmp", .imported(preset)),
        ])
        #expect(presets.headline == "Imported 2 Lightroom presets")
        #expect(presets.placement == "In the Recipes panel under Lightroom")

        let mixed = RecipeImportSummary(items: [
            Self.item("a.xmp", .imported(preset)), Self.item("teal.cube", .imported(other)),
            Self.item("shared.redrecipe", .imported(shared)), Self.item("old.xmp", .failed("Too old")),
        ])
        #expect(mixed.headline == "Imported 3 recipes, 1 of them from Lightroom presets")
        #expect(mixed.lists == ["Lightroom", "Imported", "Installed"])
        #expect(mixed.placement == "In the Recipes panel under Lightroom, Imported and Installed")
        #expect(mixed.failures == ["old.xmp: Too old"] && mixed.failureTitle == "A file couldn't be imported")

        let one = RecipeImportSummary(items: [Self.item("teal.cube", .imported(other))])
        #expect(one.headline == "Imported 1 recipe" && one.failures.isEmpty)

        let none = RecipeImportSummary(items: [
            Self.item("old.xmp", .failed("Too old")),
            Self.item("x.xmp", .failed("No")),
        ])
        #expect(none.headline == "Nothing was imported" && none.failureTitle == "Nothing was imported")
        #expect(none.lists.isEmpty && none.placement == nil)
    }

    @Test func `each file prints as what it became, with its issues and report, or why it didn't come in`() {
        let preset = RecipeImport(
            recipe: Self.recipe("Warm Fade"), issues: [RecipeIssue(.warning, "exposure was clamped to +5.00")],
            report: LightroomImportReport(entries: [.init(setting: "GrainSeed", outcome: .ignored, note: "No seed")]),
        )
        #expect(Self.item("Warm Fade.xmp", .imported(preset)).text == """
        Warm Fade.xmp → Lightroom / Warm Fade
          warning: exposure was clamped to +5.00
          1 ignored
          Ignored:
            GrainSeed: No seed
        """)
        let table = RecipeImport(recipe: Self.recipe("Teal", group: "Imported"))
        #expect(Self.item("teal.cube", .imported(table)).text == "teal.cube → Imported / Teal")
        #expect(Self.item("old.xmp", .failed("Too old")).text == "old.xmp: Too old")
    }
}
