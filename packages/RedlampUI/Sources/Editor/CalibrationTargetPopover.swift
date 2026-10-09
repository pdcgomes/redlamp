import RedlampDesign
import RedlampEngineAPI
import SwiftUI

/// Hangs Calibrate from Target's popover on the patch that was clicked: a point over the photo, in
/// the canvas's own coordinates, as the tools' overlays are (CAM-28).
struct CalibrationTargetAnchor: View {
    let target: CalibrationTarget
    @Environment(EditorModel.self) private var model

    var body: some View {
        let frame = model.canvas.imageRect(in: model.canvas.viewSize)
        Color.clear
            .frame(width: 1, height: 1)
            .popover(
                isPresented: Binding(
                    get: { model.calibrationTarget != nil },
                    set: {
                        if !$0 {
                            model.cancelCalibration()
                        }
                    },
                ),
                arrowEdge: .bottom,
            ) {
                CalibrationTargetPopover(target: target)
                    .environment(model)
            }
            .position(x: frame.minX + target.point.x * frame.width, y: frame.minY + target.point.y * frame.height)
            .allowsHitTesting(false)
    }
}

/// Asks for the measured patch's reference L*, from the target's data sheet, then calibrates the
/// camera or sets this photo's Exposure.
struct CalibrationTargetPopover: View {
    let target: CalibrationTarget
    @Environment(EditorModel.self) private var model
    @State private var text = ""
    @FocusState private var focused: Bool

    /// What was typed, as a lightness; the last one used while the field is empty.
    private var reference: Double? {
        guard !text.isEmpty else { return model.calibrationReference }
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        let value = formatter.number(from: text)?.doubleValue ?? Double(text)
        return value.flatMap { (1 ... 100).contains($0) ? $0 : nil }
    }

    var body: some View {
        let camera = model.info?.isRaw == true ? model.info?.cameraName : nil
        VStack(alignment: .leading, spacing: 10) {
            Text("Calibrate from Target").font(.headline)
            Text("This patch reads L* \(String(format: "%.1f", target.lstar)).")
                .foregroundStyle(Theme.secondaryLabel)
            HStack(spacing: 8) {
                Text("Reference L*")
                TextField(
                    model.calibrationReference.formatted(.number.precision(.fractionLength(0 ... 2))),
                    text: $text,
                )
                .frame(width: 64)
                .focused($focused)
                .onSubmit { submit(calibrating: camera != nil) }
                .accessibilityIdentifier("calibration.reference")
                Text("from the target's data sheet").foregroundStyle(Theme.secondaryLabel)
            }
            HStack(spacing: 8) {
                Button("Set This Photo's Exposure") { submit(calibrating: false) }
                    .disabled(reference == nil)
                    .accessibilityIdentifier("calibration.exposure")
                    .help("Set Exposure so this patch reads its reference; nothing is kept for the camera")
                Spacer(minLength: 0)
                if let camera {
                    Button("Calibrate \(camera)") { submit(calibrating: true) }
                        .keyboardShortcut(.defaultAction)
                        .disabled(reference == nil)
                        .accessibilityIdentifier("calibration.calibrate")
                        .help("Keep this camera's exposure anchor, give it to this photo and set Exposure to 0")
                }
            }
            Text("Use a shot exposed as the meter read, white-balanced on this patch.")
                .foregroundStyle(Theme.secondaryLabel)
        }
        .font(Theme.labelFont)
        .padding(14)
        .frame(width: 360)
        .background(KeyWindow())
        .onAppear {
            DispatchQueue.main.async { focused = true }
        }
    }

    /// The popover opens from a click on the photo, which leaves the editor window key; its window
    /// takes the keys as it appears, so the field can be typed in at once.
    private struct KeyWindow: NSViewRepresentable {
        final class View: NSView {
            override func viewDidMoveToWindow() {
                super.viewDidMoveToWindow()
                window?.makeKey()
            }
        }

        func makeNSView(context _: Context) -> View {
            View()
        }

        func updateNSView(_: View, context _: Context) {}
    }

    private func submit(calibrating: Bool) {
        guard let reference else { return }
        if calibrating {
            model.calibrate(toReference: reference)
        } else {
            model.setExposure(toReference: reference)
        }
    }
}
