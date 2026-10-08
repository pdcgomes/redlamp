import AppKit
import RedlampEngineAPI
import RedlampRecipes
import SwiftUI
import UniformTypeIdentifiers

/// The file panels and sheets behind the Recipes panel's commands.
@MainActor
public enum RecipeActions {
    public static let recipeType = UTType(filenameExtension: Recipe.fileExtension, conformingTo: .json) ?? .json
    /// The look tables `RecipeLibrary.lookTable` reads: `.cube`, `.3dl` and HaldCLUT images.
    @_spi(Harness) public static var lookTableTypes: [UTType] {
        [UTType(filenameExtension: "cube") ?? .data, UTType(filenameExtension: "3dl") ?? .data, .png, .tiff]
    }

    /// Lightroom develop presets. Photos' `.xmp` sidecars share the extension; the library
    /// tells them apart by their content.
    static var presetType: UTType {
        UTType(filenameExtension: "xmp") ?? .xml
    }

    static var importTypes: [UTType] {
        [recipeType, presetType] + lookTableTypes
    }

    /// The files of a drop on the Recipes panel it imports: folders (not packages), and files
    /// with one of the import's extensions. None means the panel refuses the drop.
    static func droppableFiles(_ urls: [URL]) -> [URL] {
        let extensions: Set = [Recipe.fileExtension, "xmp", "cube", "3dl", "png", "tif", "tiff"]
        return urls.filter { url in
            guard url.isFileURL else { return false }
            let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .isPackageKey])
            if values?.isDirectory == true {
                return values?.isPackage != true
            }
            return extensions.contains(url.pathExtension.lowercased())
        }
    }

    /// Asks for a name and the settings to include, then saves the edit to My Recipes.
    public static func createRecipe(model: EditorModel) {
        guard model.info != nil, let window = EditorWindowController.frontWindow else { return }
        let sheetWindow = NSWindow(
            contentRect: CGRect(x: 0, y: 0, width: 380, height: 460),
            styleMask: [.titled],
            backing: .buffered,
            defer: false,
        )
        let close = { [weak window, weak sheetWindow] in
            if let window, let sheetWindow {
                window.endSheet(sheetWindow)
            }
        }
        sheetWindow.contentViewController = NSHostingController(rootView: CreateRecipeSheet(
            model: model,
            dismiss: close,
        ).focusEffectDisabled())
        window.beginSheet(sheetWindow)
    }

    /// Installs `.redrecipe` files, Lightroom presets (several, or folders of them) and
    /// `.cube`, `.3dl` and HaldCLUT files, reading look tables in the space the panel's
    /// accessory chooses, then tells what came in.
    public static func importRecipes(model: EditorModel) {
        guard let chosen = chooseImports(
            importTypes,
            message: "Choose recipes, Lightroom presets or folders of them, .cube or .3dl look tables, or graded HaldCLUT images",
            multiple: true,
            folders: true,
        ) else { return }
        importFiles(chosen.urls, tableSpace: chosen.tableSpace, model: model)
    }

    /// Installs files, and the Lightroom presets in folders, as the Recipes panel's import
    /// does (files dropped on the panel too), then tells what came in: presets' reports in a
    /// sheet, or the files that didn't come in when no preset did.
    @discardableResult
    public static func importFiles(
        _ urls: [URL],
        tableSpace: ImportedTableSpace = .sRGB,
        model: EditorModel,
    ) -> Task<Void, Never> {
        let files = model.engine.files
        return Task {
            await tell(model.recipes.install(read(urls, tableSpace: tableSpace, files: files)))
        }
    }

    /// The files as `RecipeLibrary.read(importing:)` reads them, off the main thread: `files`
    /// decodes HaldCLUT images in the decode service, which the main thread mustn't wait on.
    static func read(_ urls: [URL], tableSpace: ImportedTableSpace, files: any FileInspecting) async
        -> RecipeImportSummary {
        await Task.detached {
            RecipeLibrary.read(importing: urls, tableSpace: tableSpace, reading: files)
        }.value
    }

    private static func tell(_ summary: RecipeImportSummary) {
        switch message(for: summary) {
        case .none:
            break
        case let .alert(title, text):
            let alert = NSAlert()
            alert.messageText = title
            alert.informativeText = text
            alert.runModal()
        case .sheet:
            showSummary(summary)
        }
    }

    /// How an import tells what happened.
    enum ImportMessage: Equatable {
        /// Everything came in, and none of it has a report.
        case none
        /// The files that didn't come in, when no preset did.
        case alert(title: String, text: String)
        /// Each preset's report, then any files that didn't come in.
        case sheet
    }

    static func message(for summary: RecipeImportSummary) -> ImportMessage {
        if summary.imported.contains(where: { $0.report != nil }) {
            .sheet
        } else if summary.failures.isEmpty {
            .none
        } else {
            .alert(title: summary.failureTitle, text: summary.failures.joined(separator: "\n"))
        }
    }

    private static func showSummary(_ summary: RecipeImportSummary) {
        guard let window = EditorWindowController.frontWindow else {
            let alert = NSAlert()
            alert.messageText = summary.headline
            alert.informativeText = ([summary.placement].compactMap(\.self) + summary.failures).joined(separator: "\n")
            alert.runModal()
            return
        }
        let sheetWindow = NSWindow(
            contentRect: CGRect(origin: .zero, size: RecipeImportSheet.size),
            styleMask: [.titled],
            backing: .buffered,
            defer: false,
        )
        let close = { [weak window, weak sheetWindow] in
            if let window, let sheetWindow {
                window.endSheet(sheetWindow)
            }
        }
        sheetWindow.contentViewController = NSHostingController(rootView: RecipeImportSheet(
            summary: summary,
            dismiss: close,
        ).focusEffectDisabled())
        window.beginSheet(sheetWindow)
    }

    /// Asks for files of `types`, and folders when `folders` is set, on an open panel whose
    /// accessory chooses what the look tables among them were made for. Nil when cancelled.
    @_spi(Harness) public static func chooseImports(
        _ types: [UTType],
        message: String,
        multiple: Bool = false,
        folders: Bool = false,
    ) -> (urls: [URL], tableSpace: ImportedTableSpace)? {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = multiple
        panel.canChooseDirectories = folders
        panel.allowedContentTypes = folders ? types + [.folder] : types
        panel.message = message
        let choice = LookTableSpaceChoice()
        let accessory = NSHostingView(rootView: LookTableSpaceAccessory(choice: choice))
        accessory.frame.size = accessory.fittingSize
        panel.accessoryView = accessory
        panel.isAccessoryViewDisclosed = true
        guard panel.runModal() == .OK else { return nil }
        return (panel.urls, choice.space)
    }

    /// Saves a self-contained `.redrecipe` for sharing.
    public static func export(_ recipe: Recipe, model: EditorModel) {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [recipeType]
        panel.nameFieldStringValue = RecipeFile.fileName(for: recipe)
        guard panel.runModal() == .OK, let url = panel.url else { return }
        model.recipes.export(recipe, to: url)
    }
}

/// Name, list and settings for a new recipe, as Lightroom's New Develop Preset dialog.
struct CreateRecipeSheet: View {
    let model: EditorModel
    let dismiss: () -> Void
    @State private var name = ""
    @State private var group = "My Recipes"
    @State private var includes = RecipeSettingGroup.captureDefaults

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("New Recipe").font(.headline)
            Form {
                TextField("Name", text: $name)
                TextField("List", text: $group)
            }
            Text("Settings to include").font(.subheadline).foregroundStyle(.secondary)
            ScrollView {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(RecipeSettingGroup.allCases, id: \.self) { settingGroup in
                        Toggle(settingGroup.name, isOn: Binding(
                            get: { includes.contains(settingGroup) },
                            set: { on in
                                if on {
                                    includes.insert(settingGroup)
                                } else {
                                    includes.remove(settingGroup)
                                }
                            },
                        ))
                        .toggleStyle(.checkbox)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            HStack {
                Button("Check All") { includes = Set(RecipeSettingGroup.allCases) }
                Button("Check None") { includes = [] }
                Spacer()
                Button("Cancel", role: .cancel, action: dismiss).keyboardShortcut(.cancelAction)
                Button("Create") {
                    let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
                    model.saveRecipe(name: trimmed, group: group.isEmpty ? "My Recipes" : group, includes: includes)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || includes.isEmpty)
            }
            if let error = model.recipes.lastError {
                Text(error).font(.caption).foregroundStyle(.red)
            }
        }
        .padding(20)
        .frame(width: 380, height: 460)
    }
}

/// What imported look tables were made for, chosen on an import panel. Recipes ignore it.
@MainActor
@Observable
final class LookTableSpaceChoice {
    enum Input: Hashable {
        case sRGB
        case displayRec2020
        case camera(CameraLogSpace)
    }

    var input = Input.sRGB
    var output = LookTableOutput.rec709

    var isForCameraFootage: Bool {
        if case .camera = input {
            true
        } else {
            false
        }
    }

    var space: ImportedTableSpace {
        switch input {
        case .sRGB: .sRGB
        case .displayRec2020: .displayRec2020
        case let .camera(camera): .cameraLog(camera, output: output)
        }
    }
}

/// The import panels' accessory: the input space of look tables and, for camera log
/// footage, the display their output is for.
struct LookTableSpaceAccessory: View {
    @Bindable var choice: LookTableSpaceChoice

    var body: some View {
        Form {
            Picker("Look tables are for", selection: $choice.input) {
                Text("sRGB (most LUTs)").tag(LookTableSpaceChoice.Input.sRGB)
                Text("Redlamp display (Rec.2020)").tag(LookTableSpaceChoice.Input.displayRec2020)
                Divider()
                ForEach(CameraLogSpace.allCases, id: \.self) { camera in
                    Text("\(camera.name) footage").tag(LookTableSpaceChoice.Input.camera(camera))
                }
            }
            Picker("Output", selection: $choice.output) {
                ForEach(LookTableOutput.allCases, id: \.self) { Text($0.name).tag($0) }
            }
            .disabled(!choice.isForCameraFootage)
        }
        .padding(12)
        .frame(width: 420)
    }
}
