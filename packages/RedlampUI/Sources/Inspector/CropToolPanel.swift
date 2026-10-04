import RedlampDesign
import RedlampEngineAPI
import SwiftUI

/// The Crop & Straighten tool's options, above its Angle slider: the aspect and its lock, the
/// overlay and which overlays and ratios it uses, Constrain to Image, quarter turns and flips,
/// and Reset.
struct CropToolPanel: View {
    @Environment(EditorModel.self) private var model
    @State private var choosingOverlays = false

    var body: some View {
        @Bindable var model = model
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label(EditTool.crop.title, systemImage: EditTool.crop.symbol)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Theme.value)
                Spacer()
                Button("Reset") { model.resetCrop() }
                    .controlSize(.small)
                    .disabled(model.recipe.crop.isFull && model.recipe.orientation.isIdentity
                        && model.recipe.isDefault(.cropAngle))
            }

            HStack(spacing: 6) {
                Text("Aspect")
                    .font(Theme.labelFont)
                    .foregroundStyle(Theme.label)
                Picker("Aspect", selection: Binding(get: { model.cropAspect }, set: { model.setCropAspect($0) })) {
                    ForEach(CropAspect.allCases, id: \.self) { aspect in
                        Text(aspect.title).tag(aspect)
                    }
                }
                .labelsHidden()
                .controlSize(.small)
                Button {
                    model.cropAspectLocked.toggle()
                } label: {
                    Image(systemName: model.cropAspectLocked ? "lock" : "lock.open")
                }
                .buttonStyle(.borderless)
                .help(model.cropAspectLocked ? "Unlock the aspect (A)" : "Lock the aspect (A)")
            }

            HStack(spacing: 6) {
                Text("Overlay")
                    .font(Theme.labelFont)
                    .foregroundStyle(Theme.label)
                Picker("Overlay", selection: $model.cropOverlay) {
                    ForEach(CropOverlay.allCases, id: \.self) { overlay in
                        Text(overlay.title).tag(overlay)
                    }
                }
                .labelsHidden()
                .controlSize(.small)
                .help("O cycles the chosen overlays, ⇧O turns it, X swaps the crop's orientation")
                Button {
                    choosingOverlays.toggle()
                } label: {
                    Image(systemName: "checklist")
                }
                .buttonStyle(.borderless)
                .help("Choose Overlays to Cycle and Aspect Ratios")
                .popover(isPresented: $choosingOverlays, arrowEdge: .leading) {
                    CropOverlayChooser()
                        .environment(model)
                }
            }

            Toggle("Constrain to Image", isOn: $model.constrainCropToImage)
                .toggleStyle(.checkbox)
                .font(Theme.labelFont)

            HStack(spacing: 4) {
                iconButton("rotate.left", "Rotate Left (⌘[)") { model.rotate(clockwise: false) }
                iconButton("rotate.right", "Rotate Right (⌘])") { model.rotate(clockwise: true) }
                iconButton("arrow.left.and.right.righttriangle.left.righttriangle.right", "Flip Horizontal") {
                    model.flip(horizontally: true)
                }
                iconButton("arrow.up.and.down.righttriangle.up.righttriangle.down", "Flip Vertical") {
                    model.flip(horizontally: false)
                }
                Button {
                    model.isStraightening.toggle()
                } label: {
                    Image(systemName: "level")
                        .frame(width: 24, height: 20)
                }
                .buttonStyle(.borderless)
                .foregroundStyle(model.isStraightening ? Color.accentColor : Theme.label)
                .help("Straighten: draw along a horizon or vertical (or ⌘-drag in the crop)")
                Spacer()
                Button("Done") { model.activeTool = .edit }
                    .controlSize(.small)
                    .keyboardShortcut(.return, modifiers: [])
            }
        }
        .padding(Theme.panelPadding)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func iconButton(_ symbol: String, _ help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .frame(width: 24, height: 20)
        }
        .buttonStyle(.borderless)
        .help(help)
    }
}

/// Lightroom's Choose Overlays to Cycle and Choose Aspect Ratios, side by side. The last one
/// checked in each list can't be cleared.
struct CropOverlayChooser: View {
    @Environment(EditorModel.self) private var model

    var body: some View {
        @Bindable var model = model
        let choices = model.cropOverlayChoices
        HStack(alignment: .top, spacing: 24) {
            VStack(alignment: .leading, spacing: 6) {
                heading("Overlays to Cycle", "O steps through these")
                ForEach(CropOverlay.allCases, id: \.self) { overlay in
                    Toggle(overlay.title, isOn: $model.cropOverlayChoices[overlay])
                        .disabled(choices.overlays == [overlay])
                }
            }
            VStack(alignment: .leading, spacing: 6) {
                heading("Aspect Ratios", "For the Aspect Ratios overlay")
                ForEach(CropOverlay.AspectRatio.allCases, id: \.self) { ratio in
                    Toggle(ratio.title, isOn: $model.cropOverlayChoices[ratio])
                        .disabled(choices.ratios == [ratio])
                }
            }
        }
        .toggleStyle(.checkbox)
        .padding(14)
    }

    private func heading(_ title: String, _ caption: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.headline)
            Text(caption).font(.caption).foregroundStyle(.secondary)
        }
        .padding(.bottom, 2)
    }
}
