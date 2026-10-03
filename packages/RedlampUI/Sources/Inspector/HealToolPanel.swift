import RedlampDesign
import RedlampEngineAPI
import SwiftUI

/// The Healing tool's options, above its Size, Feather and Opacity sliders: Heal or Clone, a
/// fresh source for the selected spot, and deleting spots.
struct HealToolPanel: View {
    @Environment(EditorModel.self) private var model

    var body: some View {
        @Bindable var model = model
        let selected = model.selectedSpot
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label(EditTool.heal.title, systemImage: EditTool.heal.symbol)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Theme.value)
                Spacer()
                Button("Reset") { model.deleteAllSpots() }
                    .controlSize(.small)
                    .disabled(model.recipe.spots.isEmpty)
                    .help("Delete every spot")
            }

            Picker(
                "Mode",
                selection: Binding(get: { selected?.mode ?? model.spotMode }, set: { model.setSpotMode($0) }),
            ) {
                ForEach(RetouchSpot.Mode.allCases, id: \.self) { mode in
                    Text(mode.name).tag(mode)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .controlSize(.small)
            .help("Heal matches the source to the light around the spot; Clone copies it as it is")

            Text(selected == nil
                ? "Click the photo to add a spot, or drag to brush one. Its source is found nearby."
                : "Drag the spot or its source to move it, or its handle to resize it.")
                .font(Theme.labelFont)
                .foregroundStyle(Theme.label)
                .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: 6) {
                Button("Remove Dust") { Task { await model.removeDust() } }
                    .controlSize(.small)
                    .disabled(model.isFindingDust)
                    .help("Find the specks dust on the sensor leaves on smooth areas, and heal them")
                if model.isFindingDust {
                    ProgressView().controlSize(.small)
                } else if let message = model.dustMessage {
                    Text(message)
                        .font(Theme.labelFont)
                        .foregroundStyle(Theme.label)
                }
            }

            Toggle("Visualize Spots", isOn: $model.visualizeSpots)
                .toggleStyle(.checkbox)
                .font(Theme.labelFont)
                .help(
                    "Show the photo's edges in white, so dust and specks stand out; Visualize below sets how much shows",
                )

            HStack(spacing: 6) {
                Button("Find Source") { Task { await model.findNewSource() } }
                    .controlSize(.small)
                    .disabled(selected == nil)
                    .help("Find the best source for the spot where it is now")
                Button("Delete") {
                    if let id = model.selectedSpotID {
                        model.deleteSpot(id)
                    }
                }
                .controlSize(.small)
                .disabled(selected == nil)
                .help("Delete the selected spot (⌫)")
                Spacer()
                Button("Done") { model.activeTool = .edit }
                    .controlSize(.small)
                    .keyboardShortcut(.return, modifiers: [])
            }
        }
        .padding(Theme.panelPadding)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
