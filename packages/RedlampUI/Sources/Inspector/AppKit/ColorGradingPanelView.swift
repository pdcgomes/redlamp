import AppKit
import RedlampDesign
import RedlampEngineAPI
import SwiftUI

/// Color Grading: the 3-way wheels (midtones above, shadows and highlights side by side)
/// or one range's large wheel with its sliders, then Blending and Balance.
@MainActor
@_spi(Harness) public enum ColorGradingPanelView {
    public static func make(model: EditorModel) -> PanelSectionView {
        let rows = PanelRows(model: model)
        let state = ColorGradingState()
        let picker = rows.native(GradingViewPicker(state: state).padding(.bottom, 8))
        let threeWay = ThreeWayWheelsView(model: model)

        func content() -> [NSView] {
            let wheels: [NSView] = if let range = state.view.range {
                [CenteredView(ColorWheelView(range: range, diameter: 170, model: model))]
                    + rows.sliders([range.hueParameter, range.saturationParameter, range.luminanceParameter])
            } else {
                [threeWay]
            }
            return [picker] + wheels + [rows.gap(6), rows.slider(.gradeBlending), rows.slider(.gradeBalance)]
        }

        let panel = rows.panel(.colorGrading, rows: content())
        state.onChange = { [weak panel] in panel?.setRows(content()) }
        return panel
    }
}

/// A grading wheel: angle is hue, distance from the center is saturation. Drag to set
/// both, double-click to reset.
final class ColorWheelView: LayerDrawnView, HeightProviding {
    private let range: GradingRange
    private let diameter: CGFloat
    private let model: EditorModel
    private var tracker: Tracker?
    private var hue = 0.0
    private var saturation = 0.0
    private var dragging = false

    /// The hue wheel and its grey center never change, so they are gradient layers under
    /// the drawn border, crosshair and puck.
    private let hues = CAGradientLayer()
    private let fade = CAGradientLayer()

    init(range: GradingRange, diameter: CGFloat, model: EditorModel) {
        self.range = range
        self.diameter = diameter
        self.model = model
        super.init(frame: CGRect(x: 0, y: 0, width: diameter, height: diameter))
        hues.type = .conic
        hues.colors = stride(from: 360.0, through: 0, by: -30).map { RGBA.wheelHue(
            $0,
            saturation: 0.75,
            brightness: 0.85,
        ).cgColor }
        hues.startPoint = CGPoint(x: 0.5, y: 0.5)
        hues.endPoint = CGPoint(x: 1, y: 0.5)
        fade.type = .radial
        fade.colors = [RGBA(white: 0.5).cgColor, RGBA(white: 0.5, alpha: 0).cgColor]
        fade.startPoint = CGPoint(x: 0.5, y: 0.5)
        fade.endPoint = CGPoint(x: 1, y: 1)
        for gradient in [fade, hues] {
            gradient.cornerRadius = diameter / 2
            gradient.masksToBounds = true
            gradient.actions = ["bounds": NSNull(), "position": NSNull()]
            layer?.insertSublayer(gradient, at: 0)
        }
    }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        hues.frame = bounds
        fade.frame = bounds
        CATransaction.commit()
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    override var intrinsicContentSize: NSSize {
        NSSize(width: diameter, height: diameter)
    }

    func height(forWidth _: CGFloat) -> CGFloat {
        diameter
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        tracker?.cancel()
        tracker = nil
        guard window != nil else { return }
        tracker = Tracker { [weak self] in
            guard let self else { return }
            hue = model.value(range.hueParameter)
            saturation = model.value(range.saturationParameter)
            toolTip = "\(range.name): hue \(Int(hue))°, saturation \(Int(saturation)). Double-click to reset."
            setNeedsContentDisplay()
        }
    }

    override func drawContent(in _: CGRect) {
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        let radius = diameter / 2
        let circle = CGRect(x: 0, y: 0, width: diameter, height: diameter)

        context.setStrokeColor(RGBA(white: 0, alpha: 0.35).cgColor)
        context.setLineWidth(1)
        context.strokeEllipse(in: circle.insetBy(dx: 0.5, dy: 0.5))

        let cross = CGMutablePath()
        cross.move(to: CGPoint(x: radius - 4, y: radius))
        cross.addLine(to: CGPoint(x: radius + 4, y: radius))
        cross.move(to: CGPoint(x: radius, y: radius - 4))
        cross.addLine(to: CGPoint(x: radius, y: radius + 4))
        context.addPath(cross)
        context.setStrokeColor(RGBA(white: 0, alpha: 0.4).cgColor)
        context.strokePath()

        let angle = hue * .pi / 180
        let distance = saturation / 100 * radius
        let puck = PixelGrid.centered(
            CGSize(width: 12, height: 12),
            at: CGPoint(x: radius + cos(angle) * distance, y: radius - sin(angle) * distance),
            scale: backingScale,
        )
        context.saveGState()
        context.setShadow(
            offset: .zero,
            blur: SliderTrackView.thumbShadowBlur * 2,
            color: RGBA(white: 0, alpha: 0.5).cgColor,
        )
        context.beginTransparencyLayer(auxiliaryInfo: nil)
        context.setFillColor(RGBA.wheelHue(hue, saturation: saturation / 100, brightness: 0.95).cgColor)
        context.fillEllipse(in: puck)
        context.setStrokeColor(RGBA(white: 1).cgColor)
        context.setLineWidth(1.5)
        context.strokeEllipse(in: puck.insetBy(dx: 0.75, dy: 0.75))
        context.endTransparencyLayer()
        context.restoreGState()
    }

    // MARK: - Events

    override func mouseDown(with event: NSEvent) {
        let location = convert(event.locationInWindow, from: nil)
        guard hypot(location.x - diameter / 2, location.y - diameter / 2) <= diameter / 2 else { return }
        if event.clickCount >= 2 {
            model.resetParameters([range.hueParameter, range.saturationParameter], name: "Reset \(range.name) Grading")
            return
        }
        dragging = true
        model.beginEdit()
        set(location)
    }

    override func mouseDragged(with event: NSEvent) {
        guard dragging else { return }
        set(convert(event.locationInWindow, from: nil))
    }

    override func mouseUp(with _: NSEvent) {
        guard dragging else { return }
        dragging = false
        model.endEdit(name: "\(range.name) Grading")
    }

    private func set(_ location: CGPoint) {
        let radius = diameter / 2
        let dx = location.x - radius
        let dy = radius - location.y
        var degrees = atan2(dy, dx) * 180 / .pi
        if degrees < 0 {
            degrees += 360
        }
        model.setValue(range.hueParameter, degrees)
        model.setValue(range.saturationParameter, min(hypot(dx, dy) / radius, 1) * 100)
    }
}

/// The 3-way layout: midtones on top, shadows and highlights side by side below, each
/// with its name above and a compact luminance slider under it.
final class ThreeWayWheelsView: NSView, HeightProviding {
    private let midtones: WheelGroupView
    private let shadows: WheelGroupView
    private let highlights: WheelGroupView

    init(model: EditorModel) {
        midtones = WheelGroupView(range: .midtones, diameter: 118, model: model)
        shadows = WheelGroupView(range: .shadows, diameter: 104, model: model)
        highlights = WheelGroupView(range: .highlights, diameter: 104, model: model)
        super.init(frame: .zero)
        [midtones, shadows, highlights].forEach(addSubview)
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    override var isFlipped: Bool {
        true
    }

    func height(forWidth _: CGFloat) -> CGFloat {
        midtones.groupHeight + 10 + max(shadows.groupHeight, highlights.groupHeight)
    }

    override func layout() {
        super.layout()
        let scale = backingScale
        let midX = bounds.width / 2
        midtones.frame = PixelGrid.centered(
            CGSize(width: midtones.diameter, height: midtones.groupHeight),
            at: CGPoint(x: midX, y: midtones.groupHeight / 2), scale: scale,
        )
        let rowWidth = shadows.diameter + 12 + highlights.diameter
        let top = midtones.groupHeight + 10
        let left = PixelGrid.round(midX - rowWidth / 2, scale: scale)
        shadows.frame = CGRect(x: left, y: top, width: shadows.diameter, height: shadows.groupHeight)
        highlights.frame = CGRect(
            x: left + shadows.diameter + 12,
            y: top,
            width: highlights.diameter,
            height: highlights.groupHeight,
        )
    }
}

/// A range's name, its wheel and its luminance slider.
final class WheelGroupView: NSView {
    let diameter: CGFloat
    private let range: GradingRange
    private let wheel: ColorWheelView
    private let luminance: SliderTrackView
    private let model: EditorModel
    private var tracker: Tracker?

    private static let font = Typography.caption

    init(range: GradingRange, diameter: CGFloat, model: EditorModel) {
        self.range = range
        self.diameter = diameter
        self.model = model
        wheel = ColorWheelView(range: range, diameter: diameter, model: model)
        luminance = SliderTrackView(spec: range.luminanceParameter.spec)
        super.init(frame: .zero)
        wantsLayer = true
        addSubview(wheel)
        addSubview(luminance)
        let parameter = range.luminanceParameter
        luminance.onBegin = { model.beginEdit(parameter) }
        luminance.onChange = { model.setValue(parameter, $0) }
        luminance.onEnd = { model.endEdit() }
        luminance.onReset = { model.reset(parameter) }
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    override var isFlipped: Bool {
        true
    }

    var groupHeight: CGFloat {
        TextLine.lineHeight(Self.font) + 4 + diameter + 4 + Metrics.trackHeight
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        tracker?.cancel()
        tracker = nil
        guard window != nil else { return }
        let parameter = range.luminanceParameter
        tracker = Tracker { [weak self] in
            guard let self else { return }
            let value = model.value(parameter)
            luminance.value = value
            luminance.toolTip = "Luminance \(parameter.spec.formatted(value))"
        }
    }

    override func layout() {
        super.layout()
        let label = TextLine.lineHeight(Self.font)
        wheel.frame = CGRect(x: 0, y: label + 4, width: diameter, height: diameter)
        luminance.frame = CGRect(x: 0, y: label + 4 + diameter + 4, width: diameter, height: Metrics.trackHeight)
    }

    override func draw(_: NSRect) {
        TextLine.draw(
            range.name, font: Self.font, color: Palette.secondaryLabel.nsColor,
            in: CGRect(x: 0, y: 0, width: bounds.width, height: TextLine.lineHeight(Self.font)),
            alignment: .center, scale: backingScale,
        )
    }
}

/// A fixed-size view centered in its row (SwiftUI's `HStack { Spacer(); view; Spacer() }`).
final class CenteredView: NSView, HeightProviding {
    private let content: NSView

    init(_ content: NSView) {
        self.content = content
        super.init(frame: .zero)
        addSubview(content)
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    override var isFlipped: Bool {
        true
    }

    func height(forWidth _: CGFloat) -> CGFloat {
        content.intrinsicContentSize.height
    }

    override func layout() {
        super.layout()
        let size = content.intrinsicContentSize
        content.frame = PixelGrid.centered(size, at: CGPoint(x: bounds.midX, y: size.height / 2), scale: backingScale)
    }
}
