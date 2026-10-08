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
    private let resized: Resized
    /// SwiftUI's height at a width, until the content lays out at another height.
    private var measured: (width: CGFloat, height: CGFloat)?

    /// Told as the content lays out at a new height (a row appearing inside it), so the columns
    /// around it are measured again.
    @MainActor private final class Resized {
        var action: () -> Void = {}
    }

    init(model: EditorModel, _ view: some View) {
        let resized = Resized()
        controller = NSHostingController(rootView: AnyView(
            view.environment(model).tint(Theme.nativeTint).focusEffectDisabled()
                .frame(maxWidth: .infinity, alignment: .leading)
                .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { _ in resized.action() },
        ))
        controller.sizingOptions = [.preferredContentSize]
        self.resized = resized
        super.init(frame: .zero)
        addSubview(controller.view)
        resized.action = { [weak self] in
            guard let self else { return }
            measured = nil
            guard abs(bounds.height - height(forWidth: bounds.width)) > 0.5 else { return }
            invalidateColumnLayout()
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
        if let measured, measured.width == width {
            return measured.height
        }
        let height = controller.sizeThatFits(in: CGSize(width: width, height: .greatestFiniteMagnitude)).height
        measured = (width, height)
        return height
    }

    /// Its content may have changed while it was out of the window, where SwiftUI doesn't lay it out.
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        measured = nil
        if window != nil {
            invalidateColumnLayout()
        }
    }

    override var intrinsicContentSize: NSSize {
        controller.view.fittingSize
    }

    override func layout() {
        super.layout()
        controller.view.frame = bounds
    }
}
