import AppKit
import RedlampDesign
import RedlampEngineAPI
import SwiftUI

/// The Basic panel: Treatment, Base Look, White Balance, Tone and Presence.
///
/// Sliders and chrome are AppKit. The native controls (segmented picker, menus, the Auto
/// button) are the SwiftUI panel's own, each hosted on its own: they only update when their
/// value changes, and look exactly like the originals.
@MainActor
@_spi(Harness) public enum BasicPanelView {
    public static func make(model: EditorModel) -> PanelSectionView {
        let whiteBalanceSupported: @MainActor () -> Bool = { model.info?.supportsWhiteBalance ?? false }
        func slider(_ parameter: ParameterID, enabled: @escaping @MainActor () -> Bool = { true }) -> SliderRowView {
            SliderRowView(parameter: parameter, editor: model, enabled: enabled)
        }
        func controls(_ label: String, _ view: some View) -> ControlRowView {
            ControlRowView(label: label, controls: [HostedControl(model: model, view)])
        }
        return PanelSectionView(panel: .basic, model: model, rows: [
            controls("Treatment", TreatmentPicker()),
            controls("Base Look", BaseLookMenu()),
            HostedControl(model: model, BaseLookAmountRow()),
            controls("White Balance", WhiteBalanceControls()),
            slider(.temperature, enabled: whiteBalanceSupported),
            slider(.tint, enabled: whiteBalanceSupported),
            SubsectionHeaderView(
                title: "Tone",
                parameters: [.exposure, .contrast, .highlights, .shadows, .whites, .blacks],
                editor: model,
                accessory: HostedControl(model: model, AutoToneButton()),
            ),
            slider(.exposure),
            slider(.contrast),
            GapView(height: Metrics.groupGap),
            slider(.highlights),
            slider(.shadows),
            slider(.whites),
            slider(.blacks),
            SubsectionHeaderView(
                title: "Presence",
                parameters: [.texture, .clarity, .dehaze, .vibrance, .saturation],
                editor: model,
            ),
            slider(.texture),
            slider(.clarity),
            slider(.dehaze),
            GapView(height: Metrics.groupGap),
            slider(.vibrance),
            slider(.saturation),
        ])
    }
}

/// A native control from SwiftUI, hosted on its own inside an AppKit panel. It is given
/// the rest of its row and lays itself out in it, leading-aligned, exactly as SwiftUI
/// does in the original row (a menu takes its ideal width, not its minimum).
final class HostedControl: NSView, ProposalSizing, HeightProviding {
    private let controller: NSHostingController<AnyView>
    private var observation: NSKeyValueObservation?

    init(model: EditorModel, _ view: some View) {
        controller = NSHostingController(rootView: AnyView(
            view.environment(model).tint(Theme.nativeTint).frame(maxWidth: .infinity, alignment: .leading),
        ))
        controller.sizingOptions = [.preferredContentSize]
        super.init(frame: .zero)
        addSubview(controller.view)
        observation = controller.observe(\.preferredContentSize) { [weak self] _, _ in
            MainActor.assumeIsolated {
                self?.invalidateIntrinsicContentSize()
                self?.superview?.needsLayout = true
            }
        }
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    func size(proposing proposal: CGSize) -> CGSize {
        CGSize(width: proposal.width, height: height(forWidth: proposal.width))
    }

    /// The height SwiftUI chooses at this width (not the minimum, which is shorter for
    /// some controls, such as checkboxes).
    func height(forWidth width: CGFloat) -> CGFloat {
        controller.sizeThatFits(in: CGSize(width: width, height: .greatestFiniteMagnitude)).height
    }

    override var intrinsicContentSize: NSSize {
        controller.view.fittingSize
    }

    override func layout() {
        super.layout()
        controller.view.frame = bounds
    }
}
