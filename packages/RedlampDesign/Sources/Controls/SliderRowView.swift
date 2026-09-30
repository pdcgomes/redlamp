import AppKit
import RedlampEngineAPI

/// A Lightroom-style parameter row: label, precision slider, editable value.
///
/// - Drag the thumb for relative changes, or click the track to jump.
/// - Shift-drag for fine control.
/// - Double-click the label or thumb to reset.
/// - Option-drag on tone sliders previews clipping.
/// - Click the value to type; arrow keys step (Shift for ×10).
/// - ⌘-scroll adjusts the slider under the pointer (Shift ×10, Option ×0.1); plain scrolling
///   still scrolls the panels.
///
/// While it is in a window, the row keeps itself in step with `editor`: a drag redraws
/// the track and the readout, and nothing else.
public final class SliderRowView: NSView {
    public let parameter: ParameterID
    private let spec: ParameterSpec
    private let editor: ParameterEditing
    private let enabled: @MainActor () -> Bool

    private let labelView: RowLabelView
    private let trackView: SliderTrackView
    private let valueView: ValueFieldView
    private let focusMarker = FocusMarkerView()
    private var trackers: [Tracker] = []
    private var hoverArea: NSTrackingArea?
    /// Scroll distance not yet turned into steps, and the pending end of the scroll's edit.
    private var scrollRemainder: CGFloat = 0
    private var scrollEnd: Task<Void, Never>?

    private static let clippingParameters: Set<ParameterID> = [
        .exposure, .highlights, .shadows, .whites, .blacks,
        .localExposure, .localHighlights, .localShadows, .localWhites, .localBlacks,
    ]

    public init(
        parameter: ParameterID,
        label: String? = nil,
        editor: ParameterEditing,
        enabled: @escaping @MainActor () -> Bool = { true },
    ) {
        self.parameter = parameter
        spec = parameter.spec
        self.editor = editor
        self.enabled = enabled
        labelView = RowLabelView(text: label ?? parameter.spec.label)
        trackView = SliderTrackView(spec: parameter.spec)
        valueView = ValueFieldView(spec: parameter.spec)
        super.init(frame: CGRect(x: 0, y: 0, width: 280, height: Metrics.rowHeight))
        wantsLayer = true
        clipsToBounds = false
        for view in [focusMarker, labelView, trackView, valueView] as [NSView] {
            addSubview(view)
        }
        focusMarker.isHidden = true
        toolTip = spec.availability.isLive
            ? "Double-click to reset. Shift-drag for fine control. ⌘-scroll to adjust."
            : "\(spec.label) is laid out for reference and renders in \(Self.phase(spec))."
        wireActions()
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    private static func phase(_ spec: ParameterSpec) -> String {
        if case let .planned(phase) = spec.availability {
            return phase
        }
        return ""
    }

    override public var isFlipped: Bool {
        true
    }

    override public var intrinsicContentSize: NSSize {
        NSSize(width: NSView.noIntrinsicMetric, height: Metrics.rowHeight)
    }

    // MARK: - Layout

    override public func layout() {
        super.layout()
        let height = bounds.height
        labelView.frame = CGRect(x: 0, y: 0, width: Metrics.labelWidth, height: height)
        let valueX = bounds.width - Metrics.valueWidth
        valueView.frame = CGRect(x: valueX, y: 0, width: Metrics.valueWidth, height: height)
        let trackX = Metrics.labelWidth + Metrics.rowSpacing
        trackView.frame = CGRect(
            x: trackX,
            y: (height - Metrics.trackHeight) / 2,
            width: max(valueX - Metrics.rowSpacing - trackX, 0),
            height: Metrics.trackHeight,
        )
        focusMarker.frame = CGRect(x: -8, y: (height - 12) / 2, width: 2, height: 12)
    }

    // MARK: - State

    override public func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        trackers.forEach { $0.cancel() }
        trackers = []
        guard window != nil else { return }
        trackers = [
            Tracker { [weak self] in
                guard let self else { return }
                let value = editor.sliderValue(parameter)
                trackView.value = value
                valueView.value = value
            },
            Tracker { [weak self] in
                guard let self else { return }
                let focused = editor.focusedParameter == parameter
                let live = spec.availability.isLive && enabled()
                labelView.isFocused = focused
                focusMarker.isHidden = !focused
                let opacity: CGFloat = live ? 1 : 0.35
                trackView.isEnabled = live
                valueView.isEnabled = live
                labelView.isEnabled = live
                trackView.opacity = opacity
                valueView.opacity = opacity
                labelView.opacity = opacity
                focusMarker.alphaValue = opacity
            },
        ]
    }

    private func wireActions() {
        let parameter = parameter
        labelView.onClick = { [weak self] in self?.editor.focusedParameter = parameter }
        labelView.onDoubleClick = { [weak self] in self?.editor.resetSlider(parameter) }
        trackView.onBegin = { [weak self] in
            guard let self else { return }
            editor.focusedParameter = parameter
            editor.beginEdit(parameter)
            if Self.clippingParameters.contains(parameter), NSEvent.modifierFlags.contains(.option) {
                editor.setTemporaryClipping(true)
            }
        }
        trackView.onChange = { [weak self] in self?.editor.setSliderValue(parameter, $0) }
        trackView.onEnd = { [weak self] in
            self?.editor.setTemporaryClipping(false)
            self?.editor.endEdit(name: nil)
        }
        trackView.onReset = { [weak self] in self?.editor.resetSlider(parameter) }
        valueView.onCommit = { [weak self] in self?.editor.setSliderValue(parameter, $0) }
    }

    // MARK: - Scroll

    override public func scrollWheel(with event: NSEvent) {
        guard event.modifierFlags.contains(.command), spec.availability.isLive, enabled() else {
            super.scrollWheel(with: event)
            return
        }
        // Shift turns vertical scrolling horizontal; the device's own direction means up is more.
        var delta = event.scrollingDeltaY != 0 ? event.scrollingDeltaY : event.scrollingDeltaX
        if event.isDirectionInvertedFromDevice {
            delta = -delta
        }
        scrollRemainder += event.hasPreciseScrollingDeltas ? delta / 8 : delta
        let steps = scrollRemainder.rounded(.towardZero)
        guard steps != 0 else { return }
        scrollRemainder -= steps
        if scrollEnd == nil {
            editor.focusedParameter = parameter
            editor.beginEdit(parameter)
        }
        let flags = event.modifierFlags
        let multiplier = flags.contains(.shift) ? 10.0 : flags.contains(.option) ? 0.1 : 1.0
        let value = editor.sliderValue(parameter) + Double(steps) * spec.step * multiplier
        editor.setSliderValue(parameter, spec.clamp(value))
        // One history step per gesture: it ends once scrolling pauses.
        scrollEnd?.cancel()
        scrollEnd = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(400))
            guard !Task.isCancelled, let self else { return }
            scrollEnd = nil
            scrollRemainder = 0
            editor.endEdit(name: nil)
        }
    }

    // MARK: - Hover

    override public func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let hoverArea {
            removeTrackingArea(hoverArea)
        }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
            owner: self,
        )
        addTrackingArea(area)
        hoverArea = area
    }

    override public func mouseEntered(with _: NSEvent) {
        labelView.isHovering = true
    }

    override public func mouseExited(with _: NSEvent) {
        labelView.isHovering = false
    }
}

/// The row's label: hover brightens it, focus makes it semibold in the accent color.
final class RowLabelView: LayerDrawnView {
    let text: String
    var isHovering = false {
        didSet {
            if isHovering != oldValue {
                setNeedsContentDisplay()
            }
        }
    }

    var isFocused = false {
        didSet {
            if isFocused != oldValue {
                setNeedsContentDisplay()
            }
        }
    }

    var isEnabled = true {
        didSet {
            if isEnabled != oldValue {
                setNeedsContentDisplay()
            }
        }
    }

    var opacity: CGFloat = 1 {
        didSet {
            if opacity != oldValue {
                setNeedsContentDisplay()
            }
        }
    }

    var onClick: () -> Void = {}
    var onDoubleClick: () -> Void = {}

    init(text: String) {
        self.text = text
        super.init(frame: .zero)
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    override func drawContent(in _: CGRect) {
        let color: NSColor = if isFocused {
            Palette.accent.withAlphaComponent(Palette.accent.alphaComponent * opacity)
        } else {
            (isHovering && isEnabled ? Palette.labelHover : Palette.label).opacity(opacity).nsColor
        }
        TextLine.draw(
            text, font: isFocused ? Typography.label.weight(.semibold) : Typography.label,
            color: color, in: bounds, scale: backingScale,
        )
    }

    override func mouseDown(with event: NSEvent) {
        guard isEnabled else { return }
        if event.clickCount >= 2 {
            onDoubleClick()
        } else {
            onClick()
        }
    }
}

/// Lightroom-style marker beside the slider `,` `.` select and `-` `=` nudge.
final class FocusMarkerView: NSView {
    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    override func draw(_: NSRect) {
        Palette.accent.setFill()
        NSBezierPath(roundedRect: bounds, xRadius: bounds.width / 2, yRadius: bounds.width / 2).fill()
    }
}
