import AppKit
import RedlampCanvas
import RedlampDesign
import SwiftUI

extension PanelSectionView {
    /// The Navigator in AppKit: a live, fitted view of the current render with the zoomed
    /// viewport outlined (drag it, or click, to move around the photo), and Lightroom's FIT /
    /// FILL / 1:1 / ratio zoom buttons in the header. Panning and zooming redraw the outline
    /// and the zoom buttons only.
    convenience init(navigator model: EditorModel) {
        self.init(
            section: .navigator, model: model, accessory: NavigatorZoomButtons(model: model),
            rows: [NavigatorPreviewView(model: model)],
        )
    }
}

/// The photo at 3:2, as SwiftUI's `.aspectRatio(1.5, contentMode: .fit)`, with the viewport outlined.
final class NavigatorPreviewView: NSView, HeightProviding {
    private let model: EditorModel
    private let controller = CanvasController()
    private let well = WellView()
    private let canvas: CanvasMetalView
    private let outline: ViewportOutlineView
    private var tracker: Tracker?

    init(model: EditorModel) {
        self.model = model
        canvas = model.frames.makeView(controller: controller, interactive: false)
        outline = ViewportOutlineView(model: model, controller: controller)
        super.init(frame: .zero)
        canvas.wantsLayer = true
        canvas.layer?.cornerRadius = 6
        canvas.layer?.masksToBounds = true
        [well, canvas, outline].forEach(addSubview)
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    override var isFlipped: Bool {
        true
    }

    func height(forWidth width: CGFloat) -> CGFloat {
        PixelGrid.snap(CGRect(x: 0, y: 0, width: width, height: width / 1.5), scale: backingScale).height
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        tracker?.cancel()
        tracker = nil
        guard window != nil else { return }
        tracker = Tracker { [weak self] in
            guard let self else { return }
            controller.imageSize = model.canvas.imageSize
        }
    }

    override func layout() {
        super.layout()
        [well, canvas, outline].forEach { $0.frame = bounds }
    }
}

/// FIT, FILL, 1:1 and the ratio menu, at the trailing edge of the Navigator's header.
private final class NavigatorZoomButtons: LayerDrawnView {
    private let model: EditorModel
    private let ratio: HostedControl
    private var tracker: Tracker?
    private var zoom = CanvasController.Zoom.fit
    private var buttons: [(String, CanvasController.Zoom, CGRect)] = []

    private static let choices: [(String, CanvasController.Zoom)] = [("Fit", .fit), ("Fill", .fill), ("1:1", .oneToOne)]
    private static let gap: CGFloat = 10

    init(model: EditorModel) {
        self.model = model
        ratio = HostedControl(model: model, NavigatorRatioMenu())
        super.init(frame: .zero)
        addSubview(ratio)
    }

    /// As tall as its tallest item, like the SwiftUI HStack.
    override var intrinsicContentSize: NSSize {
        let titles = Self.choices.reduce(0) { $0 + TextLine.width($1.0, font: Typography.caption) + Self.gap }
        return NSSize(
            width: titles + ratio.intrinsicContentSize.width,
            height: max(TextLine.lineHeight(Typography.caption), ratio.intrinsicContentSize.height),
        )
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        tracker?.cancel()
        tracker = nil
        guard window != nil else { return }
        tracker = Tracker { [weak self] in
            guard let self else { return }
            zoom = model.canvas.zoom
            setNeedsContentDisplay()
        }
    }

    /// Laid out right to left from the ratio menu, 10 apart, as the SwiftUI HStack does.
    override func layout() {
        super.layout()
        let scale = backingScale
        let ratioSize = ratio.intrinsicContentSize
        ratio.frame = PixelGrid.centered(
            ratioSize, at: CGPoint(x: bounds.width - ratioSize.width / 2, y: bounds.height / 2), scale: scale,
        )
        var x = ratio.frame.minX - Self.gap
        buttons = Self.choices.reversed().map { title, zoom in
            let width = TextLine.width(title, font: Typography.caption)
            x -= width
            defer { x -= Self.gap }
            return (title, zoom, CGRect(x: x, y: 0, width: width, height: bounds.height))
        }
        setNeedsContentDisplay()
    }

    override func drawContent(in _: CGRect) {
        let scale = backingScale
        for (title, choice, rect) in buttons {
            let color = choice == zoom ? Palette.labelHover : Palette.secondaryLabel
            TextLine.draw(title, font: Typography.caption, color: color.nsColor, in: rect, scale: scale)
        }
    }

    override func mouseDown(with event: NSEvent) {
        let location = convert(event.locationInWindow, from: nil)
        if let choice = buttons.first(where: { $0.2.contains(location) }) {
            model.canvas.zoom = choice.1
        }
    }
}

/// The rounded well behind the navigator photo.
private final class WellView: NSView {
    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.backgroundColor = Palette.well.cgColor
        layer?.cornerRadius = 6
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        fatalError("init(coder:) is not supported")
    }
}

/// The zoomed viewport's outline over the navigator photo. Drag it to move it from where it
/// was grabbed; click elsewhere to center the view there, as in Lightroom.
private final class ViewportOutlineView: LayerDrawnView {
    private let model: EditorModel
    private let controller: CanvasController
    private var tracker: Tracker?
    private var outline: CGRect?
    private var grab: CGPoint?

    init(model: EditorModel, controller: CanvasController) {
        self.model = model
        self.controller = controller
        super.init(frame: .zero)
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        tracker?.cancel()
        tracker = nil
        guard window != nil else { return }
        tracker = Tracker { [weak self] in
            guard let self else { return }
            outline = currentOutline()
            setNeedsContentDisplay()
        }
    }

    override func layout() {
        super.layout()
        outline = currentOutline()
        setNeedsContentDisplay()
    }

    private func currentOutline() -> CGRect? {
        guard model.canvas.isZoomedIn, model.info != nil else { return nil }
        let image = controller.imageRect(in: bounds.size)
        let visible = model.canvas.visibleImageRect
        let size = CGSize(width: visible.width * image.width, height: visible.height * image.height)
        let center = CGPoint(x: image.minX + visible.midX * image.width, y: image.minY + visible.midY * image.height)
        return PixelGrid.snap(
            CGRect(x: center.x - size.width / 2, y: center.y - size.height / 2, width: size.width, height: size.height),
            scale: backingScale,
        )
    }

    override func drawContent(in _: CGRect) {
        guard let outline, let context = NSGraphicsContext.current?.cgContext else { return }
        context.setStrokeColor(RGBA(white: 1, alpha: 0.9).cgColor)
        context.setLineWidth(1)
        context.stroke(outline.insetBy(dx: 0.5, dy: 0.5))
    }

    private func normalized(_ point: CGPoint) -> CGPoint? {
        let image = controller.imageRect(in: bounds.size)
        guard image.width > 0, image.height > 0 else { return nil }
        return CGPoint(x: (point.x - image.minX) / image.width, y: (point.y - image.minY) / image.height)
    }

    override func mouseDown(with event: NSEvent) {
        guard model.canvas.isZoomedIn, model.info != nil,
              let start = normalized(convert(event.locationInWindow, from: nil))
        else { return }
        let visible = model.canvas.visibleImageRect
        grab = visible.contains(start) ? CGPoint(x: start.x - visible.midX, y: start.y - visible.midY) : .zero
        mouseDragged(with: event)
    }

    override func mouseDragged(with event: NSEvent) {
        guard let grab, let point = normalized(convert(event.locationInWindow, from: nil)) else { return }
        model.canvas.centerOn(CGPoint(x: point.x - grab.x, y: point.y - grab.y))
    }

    override func mouseUp(with _: NSEvent) {
        grab = nil
    }
}

@_spi(Harness) public enum NavigatorPanelViews {
    @MainActor public static func make(model: EditorModel) -> NSView {
        PanelSectionView(navigator: model)
    }
}
