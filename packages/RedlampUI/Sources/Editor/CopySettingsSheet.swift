import RedlampEngineAPI
import SwiftUI

/// Lightroom's Copy Settings dialog: the settings groups in panel order, each with its items, and
/// the photo's masks by name. A group's checkbox ticks or clears its items, and shows mixed when
/// only some are ticked. Copy remembers the choice for next time.
struct CopySettingsSheet: View {
    @Environment(EditorModel.self) private var model
    let chooser: SettingsChooser
    @State private var selection: SettingsSelection

    init(chooser: SettingsChooser) {
        self.chooser = chooser
        _selection = State(initialValue: chooser.selection)
    }

    private let columns = [GridItem(.flexible(), alignment: .topLeading), GridItem(.flexible(), alignment: .topLeading)]

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(chooser.purpose == .sync ? "Synchronize Settings" : "Copy Settings")
                .font(.headline)
            if chooser.purpose == .sync {
                Text("From this photo onto the \(model.otherSelectedPhotos.count) other selected photos.")
                    .foregroundStyle(.secondary)
            }
            ScrollView {
                LazyVGrid(columns: columns, alignment: .leading, spacing: 16) {
                    ForEach(SettingsGroup.all) { group in
                        groupChecklist(group)
                    }
                    if !chooser.source.masks.isEmpty {
                        masksChecklist
                    }
                }
                .toggleStyle(.checkbox)
                .padding(.vertical, 2)
            }
            .frame(minHeight: 380)
            HStack {
                Button("Check All") { selection = .everything }
                Button("Check None") { selection = .nothing }
                Spacer()
                Button("Cancel", role: .cancel) { model.settingsChooser = nil }
                    .keyboardShortcut(.cancelAction)
                Button(chooser.purpose == .sync ? "Synchronize" : "Copy") { model.confirmSettingsChoice(selection) }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 540)
    }

    private func groupChecklist(_ group: SettingsGroup) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            if group.items.count == 1 {
                Toggle(group.name, isOn: ticked(group.items[0]))
            } else {
                Toggle(sources: group.items.map(ticked), isOn: \.self) { Text(group.name) }
                ForEach(group.items) { item in
                    Toggle(item.name, isOn: ticked(item))
                        .padding(.leading, 18)
                }
            }
        }
    }

    private var masksChecklist: some View {
        let masks = chooser.source.masks
        return VStack(alignment: .leading, spacing: 4) {
            Toggle(sources: masks.map { ticked($0, of: masks) }, isOn: \.self) { Text("Masks") }
            ForEach(masks) { mask in
                Toggle(mask.name, isOn: ticked(mask, of: masks))
                    .padding(.leading, 18)
            }
        }
    }

    private func ticked(_ item: SettingsItem) -> Binding<Bool> {
        Binding {
            selection.includes(item)
        } set: { on in
            if on {
                selection.items.insert(item.id)
            } else {
                selection.items.remove(item.id)
            }
        }
    }

    /// Masks are ticked as a whole unless some are left out; leaving them all out is no masks.
    private func ticked(_ mask: MaskLayer, of masks: [MaskLayer]) -> Binding<Bool> {
        Binding {
            selection.includes(mask: mask.id)
        } set: { on in
            if on {
                if !selection.masks {
                    selection.masks = true
                    selection.excludedMasks = Set(masks.map(\.id))
                }
                selection.excludedMasks.remove(mask.id)
            } else {
                selection.excludedMasks.insert(mask.id)
                if selection.excludedMasks.isSuperset(of: masks.map(\.id)) {
                    selection.masks = false
                    selection.excludedMasks = []
                }
            }
        }
    }
}
