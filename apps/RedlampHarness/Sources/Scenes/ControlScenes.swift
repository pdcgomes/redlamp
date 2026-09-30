import AppKit
import Observation
import RedlampDesign
import RedlampEngineAPI
@_spi(Harness) import RedlampUI
import SwiftUI

extension HarnessScene {
    static var sliderRows: HarnessScene {
        HarnessScene(
            id: "slider-rows",
            title: "Slider row",
            symbol: "slider.horizontal.3",
            synopsis: "Every track style and state — drag, Shift-drag, double-click to reset, click the value to type",
            section: .controls,
        ) {
            SliderRowsScene()
        }
    }

    static var panelChrome: HarnessScene {
        HarnessScene(
            id: "panel-chrome",
            title: "Panel chrome",
            symbol: "rectangle.split.1x2",
            synopsis: "Headers, subsection titles and control rows — click to collapse, Option-click for solo, double-click to reset",
            section: .controls,
        ) {
            PanelChromeScene()
        }
    }

    static var basicPanel: HarnessScene {
        HarnessScene(
            id: "basic-panel",
            title: "Basic",
            symbol: "slider.horizontal.below.rectangle",
            synopsis: "The AppKit Basic panel on the live editor, with a sample photo open",
            section: .panels,
        ) {
            AppKitSpecimen(width: 316) { BasicPanelView.make(model: HarnessEditor.model) }
        }
    }
}

/// One parameter for each track style, in the order a reviewer scans them.
let trackStyleSamples: [ParameterID] = [
    .exposure, .contrast, .highlights, .temperature, .tint, .vibrance,
    .hueRed, .saturationOrange, .luminanceBlue, .gradeBalance,
]

private struct SliderRowsScene: View {
    private var model: EditorModel {
        HarnessEditor.model
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            SpecimenGroup(
                title: "Track styles",
                note: "Plain tracks fill from the origin (zero for bipolar sliders, with a tick); gradient tracks show the color they push toward and never fill.",
            ) {
                AppKitSpecimen(width: 288) { column(trackStyleSamples) }
            }
            SpecimenGroup(
                title: "Planned",
                note: "Laid out for Lightroom fidelity but not rendered yet: dimmed, inert, with a tooltip naming the phase.",
            ) {
                AppKitSpecimen(width: 288) { column([.texture, .clarity, .dehaze]) }
            }
            SpecimenGroup(
                title: "Focus",
                note: "Click a label (or use , and . in the app) to focus a slider: semibold accent label and a marker in the margin.",
            ) {
                AppKitSpecimen(width: 288) { column([.shadows, .whites]) }
            }
        }
    }

    private func column(_ parameters: [ParameterID]) -> NSView {
        ColumnView(
            spacing: Metrics.panelRowSpacing,
            views: parameters.map { SliderRowView(parameter: $0, editor: HarnessEditor.model) },
        )
    }
}

@MainActor @Observable
private final class ChromeState {
    var expanded = true
    var edited = false
}

private struct PanelChromeScene: View {
    @State private var state = ChromeState()

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            SpecimenGroup(
                title: "Panel section",
                note: "The chevron turns, the rows fade and the panel below slides up. The dot appears once any slider in the panel moves off its default.",
            ) {
                HStack(alignment: .top, spacing: 24) {
                    AppKitSpecimen(width: 316) { section(title: "Sample", badge: nil) }
                    AppKitSpecimen(width: 316) { section(title: "With Badge", badge: "Beta") }
                }
                Toggle("Edited", isOn: $state.edited).toggleStyle(.checkbox)
            }
        }
    }

    private func section(title: String, badge: String?) -> NSView {
        let state = state
        let model = HarnessEditor.model
        let rows: [NSView] = [
            ControlRowView(label: "Treatment", controls: [NSSegmentedControl(
                labels: ["Color", "B&W"], trackingMode: .selectOne, target: nil, action: nil,
            )]),
            SubsectionHeaderView(title: "Tone", parameters: [.exposure, .contrast], editor: model),
            SliderRowView(parameter: .exposure, editor: model),
            SliderRowView(parameter: .contrast, editor: model),
        ]
        return ColumnView(views: [
            PanelSectionView(title: title, badge: badge, rows: rows, actions: .init(
                isExpanded: { state.expanded },
                isEdited: { state.edited },
                toggle: { _ in state.expanded.toggle() },
                reset: { state.edited = false },
            )),
            DividerView(),
        ])
    }
}
