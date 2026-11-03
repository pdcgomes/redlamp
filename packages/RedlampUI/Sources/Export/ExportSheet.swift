import AppKit
import RedlampDesign
import RedlampDocument
import RedlampEngineAPI
import RedlampLibrary
import SwiftUI

/// The Export dialog: a preset, then where the files go and what they're called, their format,
/// size and metadata. For several photos it says how many, and asks once about files already there.
public struct ExportSheet: View {
    /// Its size on a window with room for it; on a shorter one, `height` is less and the
    /// settings scroll above the buttons.
    public static let size = CGSize(width: 540, height: 720)

    /// The open photo's size; nil while no photo is open, as in the Library once another is chosen in the grid,
    /// which leaves the exported size out.
    let photoSize: PixelSize?
    /// The open photo's edit, for the bordered size; nil leaves the readout at the photo's size.
    let recipe: EditRecipe?
    /// The Borders recipes the Border menu offers.
    let borders: [ExportBorder]
    let store: ExportPresetStore
    let namingPresets: NamingPresetStore?
    let height: CGFloat
    let onCancel: () -> Void
    /// The settings, the preset they started from, and where each photo goes.
    let onExport: (ExportSettings, UUID?, [ExportNames.Target]) -> Void

    @State private var settings: ExportSettings
    @State private var presetID: UUID?
    @State private var conflict: ExportNames?
    @State private var plan: ExportPlan
    @State private var isWaitingForNames = false
    @State private var isNamingPreset = false
    @State private var presetName = ""

    /// One photo; `files` reads the destination's files, to tell an earlier export from a photo.
    public init(
        photo: URL,
        photoSize: PixelSize,
        files: any FileInspecting,
        store: ExportPresetStore,
        settings: ExportSettings? = nil,
        presetID: UUID? = nil,
        height: CGFloat = ExportSheet.size.height,
        onCancel: @escaping () -> Void,
        onExport: @escaping (ExportSettings, UUID?, [ExportNames.Target]) -> Void,
    ) {
        self.init(
            plan: ExportPlan(photo: photo, files: files), photoSize: photoSize, store: store, namingPresets: nil,
            settings: settings, presetID: presetID, height: height, onCancel: onCancel, onExport: onExport,
        )
    }

    init(
        plan: ExportPlan,
        photoSize: PixelSize?,
        recipe: EditRecipe? = nil,
        borders: [ExportBorder] = [],
        store: ExportPresetStore,
        namingPresets: NamingPresetStore?,
        settings: ExportSettings? = nil,
        presetID: UUID? = nil,
        height: CGFloat = ExportSheet.size.height,
        onCancel: @escaping () -> Void,
        onExport: @escaping (ExportSettings, UUID?, [ExportNames.Target]) -> Void,
    ) {
        self.photoSize = photoSize
        self.recipe = recipe
        self.borders = borders
        _plan = State(initialValue: plan)
        self.store = store
        self.namingPresets = namingPresets
        self.height = height
        self.onCancel = onCancel
        self.onExport = onExport
        _settings = State(initialValue: settings ?? store.initialSettings)
        _presetID = State(initialValue: settings == nil ? store.initialPresetID : presetID)
    }

    private var count: Int {
        plan.count
    }

    public var body: some View {
        VStack(spacing: 0) {
            if count > 1 {
                Text(Self.title(count))
                    .font(.headline)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 20)
                    .padding(.top, 14)
            }
            form
                .frame(maxHeight: .infinity)
                .tint(Theme.nativeTint)
                .focusEffectDisabled()
            Divider()
            HStack {
                if let problem {
                    Label(problem, systemImage: "exclamationmark.triangle")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
                Spacer()
                Button("Cancel", role: .cancel, action: onCancel).keyboardShortcut(.cancelAction)
                    .automationIdentifier("export.cancel")
                Button(count > 1 ? Self.title(count) : "Export", action: export)
                    .keyboardShortcut(.defaultAction)
                    .disabled(problem != nil)
            }
            .padding(16)
        }
        .frame(width: Self.size.width, height: height)
        .tint(Theme.nativeTint)
        .alert(conflictTitle, isPresented: Binding(
            get: { conflict != nil },
            set: {
                if !$0 {
                    conflict = nil
                }
            },
        )) {
            Button("Replace", role: .destructive) { answer(.overwrite) }
            Button("Keep Both") { answer(.addNumber) }
            if count > 1 {
                Button("Skip") { answer(.skip) }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(conflictMessage)
        }
        .alert("Save Preset", isPresented: $isNamingPreset) {
            TextField("Name", text: $presetName)
            Button("Save") {
                let name = presetName.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !name.isEmpty else { return }
                presetID = store.savePreset(named: name, settings: settings).id
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Saving under the name of one of your presets replaces it.")
        }
    }

    private var form: some View {
        Form {
            Section {
                PresetMenu(
                    store: store, settings: $settings, presetID: $presetID,
                    onSaveAs: {
                        presetName = store.preset(presetID).map { $0.isBuiltIn ? "" : $0.name } ?? ""
                        isNamingPreset = true
                    },
                )
            }
            ExportLocationSection(plan: plan, namingPresets: namingPresets, settings: $settings)
            ExportFileSection(settings: $settings)
            ExportBorderSection(border: $settings.border, borders: borders)
            ExportSizeSection(
                photoSize: photoSize.map { size in
                    recipe.map { settings.sizingSource(recipe: $0, size: size) } ?? size
                },
                bordered: photoSize.flatMap { size in
                    recipe.map { settings.border.apply(to: $0).borderLayout(imageSize: size).hasBorder }
                } ?? false,
                sizing: $settings.sizing,
            )
            Section {
                Picker("Metadata", selection: $settings.metadata) {
                    ForEach(ExportMetadataPolicy.allCases, id: \.self) { Text($0.name).tag($0) }
                }
                Toggle("Show in Finder after export", isOn: $settings.revealInFinder)
            } footer: {
                Text("""
                Camera, lens, exposure and capture date come from the original. Location is \
                its GPS position and the city and country fields. All and All Except Location \
                also embed the edit, so the file says how it was made.
                """)
                .formFooter()
            }
        }
        .overlayScrollers()
        .formStyle(.grouped)
    }

    /// Why Export is unavailable, if it is.
    var problem: String? {
        if settings.naming.template.trimmingCharacters(in: .whitespaces).isEmpty {
            return "Type a name for the file."
        }
        if let problem = plan.problem {
            return problem
        }
        if !settings.sizing.isValid {
            return "Enter a size above zero."
        }
        if let folder = settings.destinationFolder, !FileManager.default.fileExists(atPath: folder.path) {
            return "The folder “\(folder.lastPathComponent)” isn't there any more."
        }
        return nil
    }

    private func export() {
        if let names = plan.names {
            return take(names)
        }
        guard !isWaitingForNames else { return }
        isWaitingForNames = true
        Task {
            if let names = await plan.currentNames() {
                take(names)
            }
            isWaitingForNames = false
        }
    }

    private func take(_ names: ExportNames) {
        if names.asked > 0 {
            conflict = names
        } else {
            onExport(settings, presetID, names.targets)
        }
    }

    private func answer(_ policy: ExistingFilePolicy) {
        guard let conflict else { return }
        onExport(settings, presetID, conflict.answering(policy))
    }

    private var conflictTitle: String {
        guard let conflict else { return "" }
        if count == 1, let url = conflict.targets.first?.url {
            return Self.conflictTitle(url)
        }
        return Self.conflictTitle(conflict.asked, of: count)
    }

    private var conflictMessage: String {
        guard let conflict else { return "" }
        if count == 1, let url = conflict.targets.first?.url {
            return Self.conflictMessage(url)
        }
        return Self.conflictMessage(several: conflict.asked)
    }

    /// "Export 12 Photos".
    static func title(_ count: Int) -> String {
        "Export \(count) Photos"
    }

    static func conflictTitle(_ url: URL) -> String {
        "“\(url.lastPathComponent)” already exists."
    }

    static func conflictMessage(_ url: URL) -> String {
        "It's in “\(url.deletingLastPathComponent().lastPathComponent)”. Replace it, or keep both and number the new file."
    }

    static func conflictTitle(_ asked: Int, of count: Int) -> String {
        asked == 1 ? "1 of the \(count) files already exists." : "\(asked) of the \(count) files already exist."
    }

    static func conflictMessage(several asked: Int) -> String {
        asked == 1
            ? "It's an earlier export. Replace it, keep both and number the new file, or skip its photo."
            : "They're earlier exports. Replace them, keep both and number the new files, or skip their photos."
    }
}

/// The preset popup, as in the macOS Print dialog: presets, then saving and deleting them.
private struct PresetMenu: View {
    let store: ExportPresetStore
    @Binding var settings: ExportSettings
    @Binding var presetID: UUID?
    let onSaveAs: () -> Void

    var body: some View {
        LabeledContent("Preset") {
            Menu(title) {
                Section {
                    ForEach(ExportPreset.builtIns) { item($0) }
                }
                if !store.userPresets.isEmpty {
                    Section {
                        ForEach(store.userPresets) { item($0) }
                    }
                }
                Divider()
                Button("Save as Preset…", action: onSaveAs)
                if let preset, !preset.isBuiltIn {
                    Button("Update “\(preset.name)”") { store.updatePreset(preset.id, settings: settings) }
                        .disabled(!isEdited)
                    Button("Delete “\(preset.name)”") {
                        store.deletePreset(preset.id)
                        presetID = nil
                    }
                }
            }
            .fixedSize()
            .automationIdentifier("export.preset")
        }
    }

    private var preset: ExportPreset? {
        store.preset(presetID)
    }

    private var isEdited: Bool {
        preset.map { $0.settings != settings } ?? false
    }

    private var title: String {
        guard let preset else { return "Custom" }
        return isEdited ? "\(preset.name) (edited)" : preset.name
    }

    private func item(_ preset: ExportPreset) -> some View {
        Button {
            settings = preset.settings
            presetID = preset.id
        } label: {
            if preset.id == presetID {
                Label(preset.name, systemImage: "checkmark")
            } else {
                Text(preset.name)
            }
        }
    }
}
