import AppKit
import RedlampRecipes
import SwiftUI
import UniformTypeIdentifiers

/// The file panels and sheets behind the Recipes panel's commands.
@MainActor
public enum RecipeActions {
    public static let recipeType = UTType(filenameExtension: Recipe.fileExtension, conformingTo: .json) ?? .json
    /// The look tables `RecipeLibrary.lookTable` reads: `.cube`, `.3dl` and HaldCLUT images.
    static var lookTableTypes: [UTType] {
        [UTType(filenameExtension: "cube") ?? .data, UTType(filenameExtension: "3dl") ?? .data, .png, .tiff]
    }

    static var importTypes: [UTType] {
        [recipeType] + lookTableTypes
    }

    /// Asks for a name and the settings to include, then saves the edit to My Recipes.
    public static func createRecipe(model: EditorModel) {
        guard model.info != nil, let window = NSApp.keyWindow ?? NSApp.mainWindow else { return }
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

    /// Installs `.redrecipe`, `.cube`, `.3dl` and HaldCLUT files, reading look tables in the
    /// space the panel's accessory chooses.
    public static func importRecipes(model: EditorModel) {
        guard let chosen = chooseImports(
            importTypes,
            message: "Choose recipes, .cube or .3dl look tables, or graded HaldCLUT images",
            multiple: true,
        ) else { return }
        var failures: [String] = []
        for url in chosen.urls where model.recipes.install(contentsOf: url, tableSpace: chosen.tableSpace) == nil {
            failures.append("\(url.lastPathComponent): \(model.recipes.lastError ?? "unknown error")")
        }
        if !failures.isEmpty {
            let alert = NSAlert()
            alert.messageText = failures.count == 1 ? "A file couldn't be imported" : "Some files couldn't be imported"
            alert.informativeText = failures.joined(separator: "\n")
            alert.runModal()
        }
    }

    /// Asks for files of `types` on an open panel whose accessory chooses what the look tables
    /// among them were made for. Nil when cancelled.
    static func chooseImports(
        _ types: [UTType],
        message: String,
        multiple: Bool = false,
    ) -> (urls: [URL], tableSpace: ImportedTableSpace)? {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = multiple
        panel.allowedContentTypes = types
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
