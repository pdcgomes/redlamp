import AppKit
import Observation
import RedlampDesign
import RedlampEngineAPI
import SwiftUI

/// The Tone Curve panel: a parametric curve (region sliders and split handles) or a point
/// curve (drag points, click to add, double-click to remove), over the luminance histogram.
@MainActor
@_spi(Harness) public enum ToneCurvePanelView {
    public static func make(model: EditorModel) -> PanelSectionView {
        let state = ToneCurveState()
        let picker = HostedControl(model: model, ToneCurveModePicker(state: state).padding(.bottom, 6))
        let graph = CurveGraphView(model: model, state: state)
        let parametric: [NSView] = [
            SplitHandlesView(model: model),
            SubsectionHeaderView(
                title: "Region",
                parameters: [.curveHighlights, .curveLights, .curveDarks, .curveShadows],
                editor: model,
            ),
        ] + [ParameterID.curveHighlights, .curveLights, .curveDarks, .curveShadows].map {
            SliderRowView(parameter: $0, editor: model)
        }
        let point: [NSView] = [HostedControl(model: model, PointCurvePresets().padding(.top, 6))]

        let panel = PanelSectionView(panel: .toneCurve, model: model, rows: [picker, graph] + parametric)
        state.onModeChange = { [weak panel] mode in
            panel?.setRows([picker, graph] + (mode == .parametric ? parametric : point))
        }
        return panel
    }
}

/// The panel's own view state (SwiftUI's `@State` in the original).
@MainActor @Observable
final class ToneCurveState {
    var mode = ToneCurvePanel.Mode.parametric {
        didSet {
            if mode != oldValue {
                onModeChange(mode)
            }
        }
    }

    @ObservationIgnored var onModeChange: (ToneCurvePanel.Mode) -> Void = { _ in }
}

private struct ToneCurveModePicker: View {
    @Bindable var state: ToneCurveState

    var body: some View {
        Picker("Curve", selection: $state.mode) {
            ForEach(ToneCurvePanel.Mode.allCases, id: \.self) { Text($0.rawValue).tag($0) }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .controlSize(.small)
    }
}

/// The square curve graph: grid, the luminance histogram, and the curve.
final class CurveGraphView: LayerDrawnView, HeightProviding {
    private let model: EditorModel
    private let state: ToneCurveState
    private var tracker: Tracker?

    private var histogram: [UInt32] = []
    private var curve = EditRecipe()
    private var points: [CurvePoint] = []
    private var mode = ToneCurvePanel.Mode.parametric
    private var dragIndex: Int? {
        didSet {
            if dragIndex != oldValue {
                setNeedsContentDisplay()
            }
        }
    }

    init(model: EditorModel, state: ToneCurveState) {
        self.model = model
        self.state = state
        super.init(frame: .zero)
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    func height(forWidth width: CGFloat) -> CGFloat {
        width
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        tracker?.cancel()
        tracker = nil
        guard window != nil else { return }
        tracker = Tracker { [weak self] in
            guard let self else { return }
            histogram = model.histogram.luminance
            curve = model.toneCurve
            points = curve.pointCurve
            mode = state.mode
            setNeedsContentDisplay()
        }
    }

    // MARK: - Drawing

    override func drawContent(in _: CGRect) {
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        let size = bounds.size
        context.saveGState()
        context.addPath(CGPath(roundedRect: bounds, cornerWidth: 6, cornerHeight: 6, transform: nil))
        context.clip()

        context.setFillColor(Palette.well.cgColor)
        context.fill(bounds)

        let grid = CGMutablePath()
        for step in 1 ..< 4 {
            let t = Double(step) / 4
            grid.move(to: CGPoint(x: t * size.width, y: 0))
            grid.addLine(to: CGPoint(x: t * size.width, y: size.height))
            grid.move(to: CGPoint(x: 0, y: t * size.height))
            grid.addLine(to: CGPoint(x: size.width, y: t * size.height))
        }
        stroke(grid, color: Palette.divider, width: 1, context: context)
        let diagonal = CGMutablePath()
        diagonal.move(to: CGPoint(x: 0, y: size.height))
        diagonal.addLine(to: CGPoint(x: size.width, y: 0))
        stroke(diagonal, color: Palette.divider, width: 1, dash: [3, 3], context: context)

        if mode == .parametric {
            let lines = CGMutablePath()
            for split in [curve[.curveSplitShadows], curve[.curveSplitMidtones], curve[.curveSplitHighlights]] {
                let x = split / 100 * size.width
                lines.move(to: CGPoint(x: x, y: 0))
                lines.addLine(to: CGPoint(x: x, y: size.height))
            }
            stroke(lines, color: RGBA(white: 1, alpha: 0.12), width: 1, context: context)
        }

        drawHistogram(size: size, context: context)

        let lut = ToneCurveMath.lut(for: curve, count: 256)
        let path = CGMutablePath()
        for (index, value) in lut.enumerated() {
            let point = CGPoint(x: Double(index) / 255 * size.width, y: (1 - Double(value)) * size.height)
            if index == 0 {
                path.move(to: point)
            } else {
                path.addLine(to: point)
            }
        }
        stroke(path, color: RGBA(white: 0.9), width: 1.5, context: context)
        context.restoreGState()

        if mode == .point {
            let scale = backingScale
            for (index, point) in points.enumerated() {
                let rect = PixelGrid.centered(
                    CGSize(width: 9, height: 9), at: CGPoint(x: point.x * size.width, y: (1 - point.y) * size.height),
                    scale: scale,
                )
                context.setFillColor((dragIndex == index ? RGBA(white: 1) : RGBA(white: 0.85)).cgColor)
                context.fillEllipse(in: rect)
                context.setStrokeColor(RGBA(white: 0, alpha: 0.5).cgColor)
                context.setLineWidth(0.5)
                context.strokeEllipse(in: rect.insetBy(dx: 0.25, dy: 0.25))
            }
        }
    }

    private func drawHistogram(size: CGSize, context: CGContext) {
        let peak = histogram.dropFirst().dropLast().max() ?? 0
        guard peak > 0 else { return }
        let path = CGMutablePath()
        path.move(to: CGPoint(x: 0, y: size.height))
        for (index, count) in histogram.enumerated() {
            let x = Double(index) / Double(histogram.count - 1) * size.width
            path.addLine(to: CGPoint(
                x: x,
                y: size.height - min(sqrt(Double(count) / Double(peak)), 1) * size.height * 0.9,
            ))
        }
        path.addLine(to: CGPoint(x: size.width, y: size.height))
        context.addPath(path)
        context.setFillColor(RGBA(white: 1, alpha: 0.07).cgColor)
        context.fillPath()
    }

    private func stroke(_ path: CGPath, color: RGBA, width: CGFloat, dash: [CGFloat] = [], context: CGContext) {
        context.saveGState()
        context.addPath(path)
        context.setStrokeColor(color.cgColor)
        context.setLineWidth(width)
        if !dash.isEmpty {
            context.setLineDash(phase: 0, lengths: dash)
        }
        context.strokePath()
        context.restoreGState()
    }

    // MARK: - Point editing

    private func curvePoint(_ location: CGPoint) -> CGPoint {
        CGPoint(x: location.x / bounds.width, y: 1 - location.y / bounds.height)
    }

    override func mouseDown(with event: NSEvent) {
        guard mode == .point else { return }
        let start = curvePoint(convert(event.locationInWindow, from: nil))
        var sorted = points.sorted { $0.x < $1.x }
        let nearest = sorted.indices.min { hypot(sorted[$0].x - start.x, sorted[$0].y - start.y) < hypot(
            sorted[$1].x - start.x,
            sorted[$1].y - start.y,
        ) }
        let hit = nearest.flatMap { hypot(sorted[$0].x - start.x, sorted[$0].y - start.y) < 0.05 ? $0 : nil }
        if event.clickCount == 2, let hit {
            guard hit > 0, hit < sorted.count - 1 else { return }
            sorted.remove(at: hit)
            model.setPointCurve(sorted)
            return
        }
        model.beginEdit()
        if let hit {
            dragIndex = hit
        } else {
            let curve = ToneCurveMath.pointCurve(sorted)
            sorted.append(CurvePoint(x: start.x, y: curve(start.x)))
            sorted.sort { $0.x < $1.x }
            dragIndex = sorted.firstIndex { abs($0.x - start.x) < 1e-9 }
        }
        move(to: start, in: sorted)
    }

    override func mouseDragged(with event: NSEvent) {
        guard mode == .point, dragIndex != nil else { return }
        move(to: curvePoint(convert(event.locationInWindow, from: nil)), in: points.sorted { $0.x < $1.x })
    }

    override func mouseUp(with _: NSEvent) {
        guard dragIndex != nil else { return }
        dragIndex = nil
        model.endEdit(name: "Point Curve")
    }

    private func move(to location: CGPoint, in sorted: [CurvePoint]) {
        guard let index = dragIndex, sorted.indices.contains(index) else { return }
        var points = sorted
        let location = CGPoint(x: min(max(location.x, 0), 1), y: min(max(location.y, 0), 1))
        let isEndpoint = index == 0 || index == points.count - 1
        let lower = index > 0 ? points[index - 1].x + 0.01 : 0
        let upper = index < points.count - 1 ? points[index + 1].x - 0.01 : 1
        let x = isEndpoint ? points[index].x : min(max(location.x, lower), upper)
        points[index] = CurvePoint(x: x, y: location.y)
        model.setPointCurve(points)
    }
}

/// The three draggable split points under the parametric curve.
final class SplitHandlesView: LayerDrawnView, NSViewToolTipOwner {
    private static let parameters: [ParameterID] = [.curveSplitShadows, .curveSplitMidtones, .curveSplitHighlights]
    private let model: EditorModel
    private var tracker: Tracker?
    private var values: [Double] = [25, 50, 75]
    private var dragging: ParameterID?
    private var editing = false

    init(model: EditorModel) {
        self.model = model
        super.init(frame: .zero)
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    /// 12 for the handles, and the 4 SwiftUI pads below them.
    override var intrinsicContentSize: NSSize {
        NSSize(width: NSView.noIntrinsicMetric, height: 16)
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        tracker?.cancel()
        tracker = nil
        guard window != nil else { return }
        tracker = Tracker { [weak self] in
            guard let self else { return }
            values = Self.parameters.map { self.model.value($0) }
            setNeedsContentDisplay()
            updateToolTips()
        }
    }

    private func frame(for value: Double) -> CGRect {
        PixelGrid.centered(
            Symbol.layoutSize("arrowtriangle.up.fill", pointSize: 9, weight: .regular),
            at: CGPoint(x: value / 100 * bounds.width, y: 6), scale: backingScale,
        )
    }

    override func drawContent(in _: CGRect) {
        for value in values {
            Symbol.draw(
                "arrowtriangle.up.fill", pointSize: 9, color: Palette.label,
                centeredAt: CGPoint(x: value / 100 * bounds.width, y: 6), scale: backingScale,
            )
        }
    }

    private func parameter(at location: CGPoint) -> ParameterID? {
        zip(Self.parameters, values).first { frame(for: $0.1).insetBy(dx: -2, dy: -2).contains(location) }?.0
    }

    override func mouseDown(with event: NSEvent) {
        guard let parameter = parameter(at: convert(event.locationInWindow, from: nil)) else { return }
        if event.clickCount == 2 {
            model.reset(parameter)
            return
        }
        dragging = parameter
    }

    override func mouseDragged(with event: NSEvent) {
        guard let parameter = dragging else { return }
        if !editing {
            editing = true
            model.beginEdit(parameter)
        }
        model.setValue(parameter, convert(event.locationInWindow, from: nil).x / bounds.width * 100)
    }

    override func mouseUp(with _: NSEvent) {
        dragging = nil
        guard editing else { return }
        editing = false
        model.endEdit()
    }

    private func updateToolTips() {
        removeAllToolTips()
        for (index, value) in values.enumerated() {
            addToolTip(frame(for: value), owner: self, userData: UnsafeMutableRawPointer(bitPattern: index + 1))
        }
    }

    func view(
        _: NSView,
        stringForToolTip _: NSView.ToolTipTag,
        point _: NSPoint,
        userData: UnsafeMutableRawPointer?,
    ) -> String {
        let index = Int(bitPattern: userData) - 1
        let parameter = Self.parameters[max(0, min(index, Self.parameters.count - 1))]
        return "\(parameter.spec.label): drag to move, double-click to reset"
    }
}
