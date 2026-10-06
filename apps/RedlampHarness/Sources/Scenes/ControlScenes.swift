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

    static var notices: HarnessScene {
        HarnessScene(
            id: "notices",
            title: "Notices",
            symbol: "exclamationmark.triangle",
            synopsis: "Text to read before going on, on a card in its tone: a download's terms, a warning, an error to dismiss",
            section: .controls,
        ) {
            NoticesScene()
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

    private func treatmentMenu() -> NSPopUpButton {
        let menu = NSPopUpButton(frame: .zero, pullsDown: false)
        menu.controlSize = .small
        menu.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        for (title, symbol) in [("Color", "paintpalette"), ("B&W", "circle.lefthalf.filled")] {
            menu.addItem(withTitle: title)
            menu.lastItem?.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
        }
        return menu
    }

    private func section(title: String, badge: String?) -> NSView {
        let state = state
        let model = HarnessEditor.model
        let rows: [NSView] = [
            ControlRowView(label: "Treatment", controls: [treatmentMenu()]),
            SubsectionHeaderView(title: "Tone", parameters: [.exposure, .contrast], editor: model),
            SliderRowView(parameter: .exposure, editor: model),
            SliderRowView(parameter: .contrast, editor: model),
        ]
        return ColumnView(views: [
            PanelSectionView(title: title, symbol: "sun.max", badge: badge, rows: rows, actions: .init(
                isExpanded: { state.expanded },
                isEdited: { state.edited },
                toggle: { _ in state.expanded.toggle() },
                reset: { state.edited = false },
            )),
            DividerView(),
        ])
    }
}

private struct NoticesScene: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            SpecimenGroup(
                title: "Tones",
                note: "Caution for what to weigh before going on (Generative fill's download, an error); info for what to know (a model's download).",
            ) {
                VStack(alignment: .leading, spacing: 10) {
                    NoticeCard(
                        "Generative fill uses FLUX.2 [klein] 4B, a 2.41 GB download. It runs on this Mac; your photos are never uploaded.",
                        tone: .caution,
                    ) {
                        HStack(spacing: 6) {
                            Link("Read the licence", destination: URL(string: "https://redlamp.app")!)
                            Spacer()
                            Button("Not Now") {}
                            Button("Download") {}
                        }
                        .controlSize(.small)
                    }
                    NoticeCard(
                        "Objects masks use SAM 3, a 1.7 GB download. You can remove it in Settings › Models.",
                        tone: .info, symbol: "arrow.down.circle.fill",
                    )
                    NoticeCard("Sky masks couldn't be computed: the model failed to load.", tone: .caution, dismiss: {})
                }
                .frame(width: 288)
                .padding(14)
                .background(Palette.panelBackground.color)
            }
        }
    }
}
