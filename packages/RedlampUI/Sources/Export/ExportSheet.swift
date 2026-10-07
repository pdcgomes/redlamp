import AppKit
import RedlampDocument
import RedlampEngineAPI
import SwiftUI

/// The Export dialog: a preset, then where the file goes, its format, size and metadata.
public struct ExportSheet: View {
    /// Its size on a window with room for it; on a shorter one, `height` is less and the
    /// settings scroll above the buttons.
    public static let size = CGSize(width: 540, height: 720)

    let photo: URL
    let photoSize: PixelSize
    let store: ExportPresetStore
    let height: CGFloat
    let onCancel: () -> Void
    /// The settings, the preset they started from, and the file to write.
    let onExport: (ExportSettings, UUID?, URL) -> Void

    @State private var settings: ExportSettings
    @State private var presetID: UUID?
    @State private var conflict: URL?
    @State private var isNamingPreset = false
    @State private var presetName = ""

    public init(
        photo: URL,
        photoSize: PixelSize,
        store: ExportPresetStore,
        settings: ExportSettings? = nil,
        presetID: UUID? = nil,
        height: CGFloat = ExportSheet.size.height,
        onCancel: @escaping () -> Void,
        onExport: @escaping (ExportSettings, UUID?, URL) -> Void,
    ) {
        self.photo = photo
        self.photoSize = photoSize
        self.store = store
        self.height = height
        self.onCancel = onCancel
        self.onExport = onExport
        _settings = State(initialValue: settings ?? store.initialSettings)
        _presetID = State(initialValue: settings == nil ? store.initialPresetID : presetID)
    }

    public var body: some View {
        VStack(spacing: 0) {
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
                Button("Export", action: export)
                    .keyboardShortcut(.defaultAction)
                    .disabled(problem != nil)
            }
            .padding(16)
        }
        .frame(width: Self.size.width, height: height)
        .tint(Theme.nativeTint)
        .alert(conflict.map(Self.conflictTitle) ?? "", isPresented: Binding(
            get: { conflict != nil },
            set: {
                if !$0 {
                    conflict = nil
                }
            },
        )) {
            Button("Replace", role: .destructive) { finish(conflict) }
            Button("Keep Both") { finish(conflict.map { ExportDestination.firstFree($0) }) }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(conflict.map(Self.conflictMessage) ?? "")
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
            ExportLocationSection(photo: photo, settings: $settings)
            ExportFileSection(settings: $settings)
            ExportSizeSection(photoSize: photoSize, sizing: $settings.sizing)
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
        .formStyle(.grouped)
    }

    /// Why Export is unavailable, if it is.
    var problem: String? {
        if !settings.naming.isValid {
            return "Type a name for the file."
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
        switch ExportActions.step(for: settings, photo: photo) {
        case let .ready(url, _): finish(url)
        case let .confirmReplace(url, _): conflict = url
        case .needsDialog: break
        }
    }

    private func finish(_ url: URL?) {
        guard let url else { return }
        onExport(settings, presetID, url)
    }

    static func conflictTitle(_ url: URL) -> String {
        "“\(url.lastPathComponent)” already exists."
    }

    static func conflictMessage(_ url: URL) -> String {
        "It's in “\(url.deletingLastPathComponent().lastPathComponent)”. Replace it, or keep both and number the new file."
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
