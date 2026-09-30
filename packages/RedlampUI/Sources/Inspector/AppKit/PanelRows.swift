import AppKit
import RedlampDesign
import RedlampEngineAPI
import SwiftUI

/// Builders for the rows of an AppKit Develop panel, mirroring the SwiftUI panels' parts:
/// `slider` is `ParameterSlider`, `header` is `SubsectionHeader`, `controls` is `ControlRow`,
/// `native` hosts a SwiftUI control on its own.
@MainActor
struct PanelRows {
    let model: EditorModel

    func slider(
        _ parameter: ParameterID,
        label: String? = nil,
        enabled: @escaping @MainActor () -> Bool = { true },
    ) -> SliderRowView {
        SliderRowView(parameter: parameter, label: label, editor: model, enabled: enabled)
    }

    func sliders(_ parameters: [ParameterID]) -> [NSView] {
        parameters.map { slider($0) }
    }

    func header(_ title: String, _ parameters: [ParameterID], accessory: NSView? = nil) -> SubsectionHeaderView {
        SubsectionHeaderView(title: title, parameters: parameters, editor: model, accessory: accessory)
    }

    func gap(_ height: CGFloat = Metrics.groupGap) -> GapView {
        GapView(height: height)
    }

    func controls(_ label: String, _ view: some View) -> ControlRowView {
        ControlRowView(label: label, controls: [native(view)])
    }

    func native(_ view: some View) -> HostedControl {
        HostedControl(model: model, view)
    }

    func panel(_ panel: PanelID, badge: String? = nil, rows: [NSView]) -> PanelSectionView {
        PanelSectionView(panel: panel, model: model, badge: badge, rows: rows)
    }
}
