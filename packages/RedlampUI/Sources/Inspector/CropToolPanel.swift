import RedlampDesign
import RedlampEngineAPI
import SwiftUI

/// The Crop & Straighten tool's options, above its Angle slider: the aspect and its lock,
/// Constrain to Image, quarter turns and flips, and Reset.
struct CropToolPanel: View {
    @Environment(EditorModel.self) private var model

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
