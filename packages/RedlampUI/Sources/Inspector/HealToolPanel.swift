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
                selection: Binding(
                    get: { selected?.mode ?? model.spotMode },
                    set: { mode in Task { await model.setSpotMode(mode) } },
                ),
            ) {
                ForEach(RetouchSpot.Mode.allCases, id: \.self) { mode in
                    Text(mode.name).tag(mode)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .controlSize(.small)
            .help(
                "Remove fills the spot from the photo around it; Heal matches a source to the light around the spot; Clone copies it as it is",
            )

            if (selected?.mode ?? model.spotMode) == .remove, model.offersGenerativeFill {
                generativeRows(selected)
            }

            HStack(spacing: 6) {
                Text("Click picks")
                    .font(Theme.labelFont)
                    .foregroundStyle(Theme.label)
                Picker("Click picks", selection: $model.spotPick) {
                    ForEach(SpotPick.allCases, id: \.self) { pick in
                        Text(pick.name).tag(pick)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .controlSize(.small)
                .help("Spot adds a spot where you click; Person and Object remove the person or object you click")
                if model.isPickingRegion {
                    ProgressView().controlSize(.small)
                }
            }
            if let message = model.pickMessage {
                Text(message)
                    .font(Theme.labelFont)
                    .foregroundStyle(Theme.label)
                    .fixedSize(horizontal: false, vertical: true)
            }

            findRow

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
                if model.isMultiSelecting {
                    Button("In \(model.selectedPhotos.count) Photos") { Task { await model.removeDustInSelection() } }
                        .controlSize(.small)
                        .disabled(model.isFindingDust || model.settingsSync.progress != nil)
                        .help(
                            "Heal the dust found in the same place on the sensor in several of the selected photos, in all of them",
                        )
                }
                if let search = model.dustSearch {
                    Text("\(search.done) of \(search.total)")
                        .font(Theme.labelFont)
                        .foregroundStyle(Theme.label)
                } else if model.isFindingDust {
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
                    .disabled(selected?.mode.usesSource != true)
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
        .task {
            await model.loadThingsToFind()
            await model.loadGenerativeFill()
        }
    }

    /// Generative Remove (RM-10): Fill, the model's download, the fill being made, and the selected
    /// spot's fills to choose from, labelled as generated.
    @ViewBuilder private func generativeRows(_ selected: RetouchSpot?) -> some View {
        @Bindable var model = model
        let availability = model.generativeAvailability
        HStack(spacing: 6) {
            Text("Fill")
                .font(Theme.labelFont)
                .foregroundStyle(Theme.label)
            Picker("Fill", selection: $model.fillsGeneratively) {
                Text("Content-Aware").tag(false)
                Text("Generative").tag(true)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .controlSize(.small)
            .help(
                "Content-Aware fills from the photo around the spot; Generative repaints it with an image model on this Mac, for areas too large to fill from the photo",
            )
        }
        if model.fillsGeneratively, case let .needsModel(info) = availability {
            VStack(alignment: .leading, spacing: 6) {
                note(
                    "Generative fill uses \(info.name), a \(info.formattedSize) download. It runs on this Mac; your photos are never uploaded. Its training data is undisclosed, so what it makes is labelled as generated fill."
                        + (info.licence.map { " Its licence: \($0)." } ?? ""),
                )
                HStack {
                    if let url = info.licenceURL {
                        Link("Read the licence", destination: url).font(Theme.labelFont)
                    }
                    Spacer()
                    if let fraction = model.generativeDownload {
                        ProgressView(value: fraction).frame(width: 90)
                    } else {
                        Button("Not Now") { model.fillsGeneratively = false }
                            .controlSize(.small)
                        Button("Download") { Task { await model.downloadGenerativeModel() } }
                            .controlSize(.small)
                    }
                }
            }
        }
        if let generating = model.generating {
            HStack(spacing: 6) {
                ProgressView(value: generating.progress)
                    .frame(width: 110)
                Text("Generating")
                    .font(Theme.labelFont)
                    .foregroundStyle(Theme.label)
                Spacer()
                Button("Cancel") { model.cancelGenerativeFill() }
                    .controlSize(.small)
            }
        }
        if let selected, selected.mode == .remove {
            if let variations = model.fillVariations(of: selected) {
                HStack(spacing: 6) {
                    Label("Generated fill", systemImage: "sparkles")
                        .font(Theme.labelFont)
                        .foregroundStyle(Theme.value)
                        .help("This spot is filled by FLUX.2 [klein] 4B, an image model, rather than from the photo")
                    Spacer()
                    if variations.count > 1 {
                        Button { model.showFillVariation(-1) } label: { Image(systemName: "chevron.left") }
                            .buttonStyle(.borderless)
                            .help("The previous fill")
                        Text("\(variations.index + 1) of \(variations.count)")
                            .font(Theme.labelFont.monospacedDigit())
                            .foregroundStyle(Theme.label)
                        Button { model.showFillVariation(1) } label: { Image(systemName: "chevron.right") }
                            .buttonStyle(.borderless)
                            .help("The next fill")
                    }
                }
                HStack(spacing: 6) {
                    Button("More") { model.fillGeneratively([selected.id], more: true) }
                        .controlSize(.small)
                        .disabled(availability != .ready || model.generating != nil)
                        .help("Make \(EditorModel.fillVariations) more fills to choose from")
                    Button("Content-Aware") { model.useContentAwareFill() }
                        .controlSize(.small)
                        .help("Fill the spot from the photo around it instead")
                }
            } else if availability == .ready, model.generating == nil {
                Button("Fill Generatively") { model.fillGeneratively([selected.id]) }
                    .controlSize(.small)
                    .help(
                        "Repaint this spot with the image model, with \(EditorModel.fillVariations) fills to choose from",
                    )
            }
        }
        if let message = model.generativeMessage {
            note(message)
        }
    }

    private func note(_ text: String) -> some View {
        Text(text)
            .font(Theme.labelFont)
            .foregroundStyle(Theme.label)
            .fixedSize(horizontal: false, vertical: true)
    }

    /// Find: a thing to look for (or everything), outlined on the photo for a click to remove.
    @ViewBuilder private var findRow: some View {
        @Bindable var model = model
        HStack(spacing: 6) {
            Text("Find")
                .font(Theme.labelFont)
                .foregroundStyle(Theme.label)
            Picker("Find", selection: $model.thingToFind) {
                Text("Everything").tag(String?.none)
                Divider()
                ForEach(model.thingsToFind, id: \.self) { thing in
                    Text(thing.capitalized).tag(String?.some(thing))
                }
            }
            .labelsHidden()
            .controlSize(.small)
            .fixedSize()
            .disabled(model.thingsToFind.isEmpty)
            Button("Find") { Task { await model.findThings() } }
                .controlSize(.small)
                .disabled(model.isFindingThings)
                .help("Outline what's chosen wherever it is in the photo; click one to remove it")
            if model.isFindingThings {
                ProgressView().controlSize(.small)
            }
        }
        if !model.foundThings.isEmpty {
            HStack(spacing: 6) {
                Button("Remove All") { Task { await model.removeAllFound() } }
                    .controlSize(.small)
                    .disabled(model.isPickingRegion)
                    .help("Remove everything outlined, as one step")
                Button("Clear") { model.foundThings = [] }
                    .controlSize(.small)
                    .help("Stop outlining what was found")
            }
        }
        if let message = model.findMessage {
            Text(message)
                .font(Theme.labelFont)
                .foregroundStyle(Theme.label)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}
