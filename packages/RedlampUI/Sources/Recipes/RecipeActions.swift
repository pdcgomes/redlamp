import AppKit
import RedlampRecipes
import SwiftUI
import UniformTypeIdentifiers

/// The file panels and sheets behind the Recipes panel's commands.
@MainActor
public enum RecipeActions {
    public static let recipeType = UTType(filenameExtension: Recipe.fileExtension, conformingTo: .json) ?? .json
    static var importTypes: [UTType] {
        [recipeType, UTType(filenameExtension: "cube") ?? .data, .png, .tiff]
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

    /// Installs `.redrecipe`, `.cube` and HaldCLUT files.
    public static func importRecipes(model: EditorModel) {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.allowedContentTypes = importTypes
        panel.message = "Choose recipes, .cube look tables or graded HaldCLUT images"
        guard panel.runModal() == .OK else { return }
        var failures: [String] = []
        for url in panel.urls {
            if model.recipes.install(contentsOf: url) == nil {
                failures.append("\(url.lastPathComponent): \(model.recipes.lastError ?? "unknown error")")
            }
        }
        if !failures.isEmpty {
            let alert = NSAlert()
            alert.messageText = failures.count == 1 ? "A file couldn't be imported" : "Some files couldn't be imported"
            alert.informativeText = failures.joined(separator: "\n")
            alert.runModal()
        }
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
