import AppKit
import Observation
import RedlampDesign
import RedlampEngineAPI
@_spi(Harness) import RedlampUI
import SwiftUI

/// Tuning shared by the parity scenes. Drawing constants live as statics on the AppKit
/// components; changing one here rebuilds the port so it can be judged immediately.
@MainActor @Observable
final class ParityTuning {
    static let shared = ParityTuning()

    var mode = ParityMode.launchDefault
    var width: CGFloat = 316
    var revision = 0
    var thumbShadowBlur = Double(SliderTrackView.thumbShadowBlur) {
        didSet {
            SliderTrackView.thumbShadowBlur = CGFloat(thumbShadowBlur)
            revision += 1
        }
    }

    var snippet: String {
        "SliderTrackView.thumbShadowBlur = \(String(format: "%.2f", thumbShadowBlur))"
    }
}

extension HarnessScene {
    static var sliderRowParity: HarnessScene {
        HarnessScene(
            id: "parity-slider-rows",
            title: "Slider rows",
            symbol: "slider.horizontal.3",
            synopsis: "SwiftUI ParameterSlider against the AppKit SliderRowView — in Difference mode, anything not black is a mismatch",
            section: .parity,
        ) {
            ParitySceneView { width in
                hostedReference(width: width) {
                    VStack(alignment: .leading, spacing: Metrics.panelRowSpacing) {
                        ForEach(trackStyleSamples + [.texture], id: \.self) { ParameterSlider(parameter: $0) }
                    }
                    .padding(.horizontal, Metrics.panelPadding)
                    .environment(HarnessEditor.model)
                }
            } candidate: { _ in
                ColumnView(
                    spacing: Metrics.panelRowSpacing,
                    insets: NSEdgeInsets(top: 0, left: Metrics.panelPadding, bottom: 0, right: Metrics.panelPadding),
                    views: (trackStyleSamples + [.texture]).map { SliderRowView(
                        parameter: $0,
                        editor: HarnessEditor.model,
                    ) },
                )
            }
        } inspector: {
            ParityInspector()
        }
    }

    static var basicPanelParity: HarnessScene {
        HarnessScene(
            id: "parity-basic",
            title: "Basic panel",
            symbol: "slider.horizontal.below.rectangle",
            synopsis: "SwiftUI BasicPanel against the AppKit port, at the inspector's width",
            section: .parity,
        ) {
            ParitySceneView { width in
                hostedReference(width: width) {
                    BasicPanel().environment(HarnessEditor.model)
                }
            } candidate: { _ in
                BasicPanelView.make(model: HarnessEditor.model)
            }
        } inspector: {
            ParityInspector()
        }
    }
}

private struct ParitySceneView: View {
    let reference: @MainActor (CGFloat) -> NSView
    let candidate: @MainActor (CGFloat) -> NSView
    @State private var tuning = ParityTuning.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Picker("Compare", selection: $tuning.mode) {
                ForEach(ParityMode.allCases) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented)
            .fixedSize()
            ParityStage(
                width: tuning.width, mode: tuning.mode, revision: tuning.revision,
                reference: { reference(tuning.width) }, candidate: { candidate(tuning.width) },
            )
            .id(tuning.width)
        }
    }
}

private struct ParityInspector: View {
    @State private var tuning = ParityTuning.shared

    var body: some View {
        Form {
            Section("Stage") {
                Picker("Compare", selection: $tuning.mode) {
                    ForEach(ParityMode.allCases) { Text($0.title).tag($0) }
                }
                Knob("width", $tuning.width, 240 ... 440, step: 1)
            }
            Section("Slider") {
                Knob("thumb shadow blur", $tuning.thumbShadowBlur, 0 ... 6, step: 0.05)
            }
            Section {
                Button("Copy values") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(tuning.snippet, forType: .string)
                }
            }
        }
        .formStyle(.grouped)
    }
}
