import AppKit
import RedlampDesign
import RedlampEngineAPI
import SwiftUI

/// The RGB histogram with Lightroom's clipping indicators and drag-to-adjust regions,
/// and the capture summary under it.
///
/// It redraws only when the histogram (published ~30 times a second), the photo, the
/// clipping overlay or the hovered region's value changes, without touching SwiftUI.
final class HistogramGraphView: LayerDrawnView, NSViewToolTipOwner {
    typealias Region = HistogramView.Region

    static let graphHeight: CGFloat = 104
    private static let spacing: CGFloat = 6
    private static let indicatorSize = CGSize(width: 14, height: 12)
    private static let channels: [(KeyPath<Histogram, [UInt32]>, RGBA)] = [
        (\.red, RGBA(red: 0.95, green: 0.25, blue: 0.25)),
        (\.green, RGBA(red: 0.25, green: 0.9, blue: 0.35)),
        (\.blue, RGBA(red: 0.3, green: 0.45, blue: 1.0)),
    ]

    private let model: EditorModel
    private var tracker: Tracker?
    private var hoverArea: NSTrackingArea?

    private var hoverRegion: Region? {
        didSet {
            if hoverRegion != oldValue {
                track()
            }
        }
    }

    private var dragRegion: Region? {
        didSet {
            if dragRegion != oldValue {
                track()
            }
        }
    }

    private var dragStart: (x: CGFloat, value: Double)?
    private var mouseDownX: CGFloat?

    // What the last tracked update read; drawing uses these.
    private var histogram = Histogram.empty
    private var hasPhoto = false
    private var showClipping = false
    private var summary: [String] = []
    private var regionValue = 0.0

    init(model: EditorModel) {
        self.model = model
        super.init(frame: .zero)
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    static var height: CGFloat {
        graphHeight + spacing + TextLine.lineHeight(Typography.caption.monospacedDigit)
    }

    override var intrinsicContentSize: NSSize {
        NSSize(width: NSView.noIntrinsicMetric, height: Self.height)
    }

    // MARK: - State

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        track()
    }

    private var shownRegion: Region? {
        hasPhoto ? hoverRegion ?? dragRegion : nil
    }

    private func track() {
        tracker?.cancel()
        tracker = nil
        guard window != nil else { return }
        let region = hoverRegion ?? dragRegion
        tracker = Tracker { [weak self] in
            guard let self else { return }
            histogram = model.histogram
            hasPhoto = model.info != nil
            summary = model.info?.exposureSummary ?? []
            showClipping = model.showClipping
            regionValue = region.map { model.value($0.parameter) } ?? 0
            setNeedsContentDisplay()
            updateToolTips()
        }
    }

    // MARK: - Geometry

    private var indicatorRowHeight: CGFloat {
        shownRegion == nil ? Self.indicatorSize.height : max(
            Self.indicatorSize.height,
            TextLine.lineHeight(Self.captionFont),
        )
    }

    private func indicatorFrame(trailing: Bool) -> CGRect {
        let size = Self.indicatorSize
        let x = trailing ? bounds.width - 6 - size.width : 6
        return PixelGrid.centered(
            size,
            at: CGPoint(x: x + size.width / 2, y: 4 + indicatorRowHeight / 2),
            scale: backingScale,
        )
    }

    private static let captionFont = Typography.caption.monospacedDigit

    // MARK: - Drawing

    override func drawContent(in _: CGRect) {
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        let scale = backingScale
        let width = bounds.width
        let graph = CGRect(x: 0, y: 0, width: width, height: Self.graphHeight)

        context.addPath(CGPath(roundedRect: graph, cornerWidth: 6, cornerHeight: 6, transform: nil))
        context.setFillColor(Palette.well.cgColor)
        context.fillPath()

        if let region = shownRegion {
            let span = region.span
            let band = PixelGrid.centered(
                CGSize(width: (span.upperBound - span.lowerBound) * width, height: graph.height),
                at: CGPoint(x: (span.lowerBound + span.upperBound) / 2 * width, y: graph.midY),
                scale: scale,
            )
            context.setFillColor(RGBA(white: 1, alpha: 0.05).cgColor)
            context.fill(band)
        }

        drawChannels(in: CGRect(x: 2, y: 14, width: width - 4, height: graph.height - 18), context: context)

        drawIndicator(clipped: histogram.shadowsClipped, color: .systemBlue, trailing: false, context: context)
        drawIndicator(clipped: histogram.highlightsClipped, color: .systemRed, trailing: true, context: context)
        if let region = shownRegion {
            let spec = region.parameter.spec
            TextLine.draw(
                "\(spec.label)  \(spec.formatted(regionValue))", font: Self.captionFont, color: Palette.value.nsColor,
                in: CGRect(x: 0, y: 4, width: width, height: indicatorRowHeight), alignment: .center, scale: scale,
            )
        }

        drawSummary(y: graph.maxY + Self.spacing, scale: scale)
    }

    private func drawChannels(in rect: CGRect, context: CGContext) {
        let peak = Self.channels.flatMap { histogram[keyPath: $0.0].dropFirst().dropLast() }.max() ?? 0
        guard peak > 0 else { return }
        let scale = sqrt(Double(peak))
        // SwiftUI adds the channels (plus-lighter) in sRGB; blending in the window's wider
        // color space would tint the overlaps. So they are composited in an sRGB bitmap.
        let pixelScale = backingScale
        let width = Int((rect.width * pixelScale).rounded(.up)), height = Int((rect.height * pixelScale).rounded(.up))
        guard width > 0, height > 0, let space = CGColorSpace(name: CGColorSpace.sRGB),
              let bitmap = CGContext(
                  data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0, space: space,
                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue,
              )
        else { return }
        // Flipped, in points, like the view.
        bitmap.translateBy(x: 0, y: CGFloat(height))
        bitmap.scaleBy(x: pixelScale, y: -pixelScale)
        bitmap.setBlendMode(.plusLighter)
        for (channel, color) in Self.channels {
            let bins = histogram[keyPath: channel]
            let path = CGMutablePath()
            path.move(to: CGPoint(x: 0, y: rect.height))
            for (index, count) in bins.enumerated() {
                let x = Double(index) / Double(bins.count - 1) * rect.width
                let y = rect.height - min(sqrt(Double(count)) / scale, 1) * rect.height
                path.addLine(to: CGPoint(x: x, y: y))
            }
            path.addLine(to: CGPoint(x: rect.width, y: rect.height))
            path.closeSubpath()
            bitmap.addPath(path)
            bitmap.setFillColor(color.opacity(0.55).cgColor)
            bitmap.fillPath()
        }
        guard let image = bitmap.makeImage() else { return }
        context.saveGState()
        // The bitmap is stored top row first; undo the view's flip while drawing it.
        context.translateBy(x: rect.minX, y: rect.maxY)
        context.scaleBy(x: 1, y: -1)
        context.draw(
            image,
            in: CGRect(x: 0, y: 0, width: CGFloat(width) / pixelScale, height: CGFloat(height) / pixelScale),
        )
        context.restoreGState()
    }

    private func drawIndicator(clipped: Bool, color: NSColor, trailing: Bool, context _: CGContext) {
        let tint = clipped || showClipping ? color.usingColorSpace(.sRGB).map(RGBA.init) : Palette.tertiaryLabel
        guard let tint else { return }
        let frame = indicatorFrame(trailing: trailing)
        Symbol.draw(
            "arrowtriangle.up.fill", pointSize: 8, color: tint, centeredAt: CGPoint(x: frame.midX, y: frame.midY),
            rotation: trailing ? 45 : -45, scale: backingScale,
        )
    }

    private func drawSummary(y: CGFloat, scale: CGFloat) {
        let parts = summary.isEmpty ? [" "] : summary
        let font = Self.captionFont
        let widths = parts.map { ceil(TextLine.width($0, font: font) * scale) / scale }
        let total = widths.reduce(0, +) + 12 * CGFloat(parts.count - 1)
        var x = PixelGrid.round((bounds.width - total) / 2, scale: scale)
        let height = TextLine.lineHeight(font)
        for (part, width) in zip(parts, widths) {
            TextLine.draw(
                part, font: font, color: Palette.secondaryLabel.nsColor,
                in: CGRect(x: x, y: y, width: width, height: height), scale: scale,
            )
            x += width + 12
        }
    }

    // MARK: - Events

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let hoverArea {
            removeTrackingArea(hoverArea)
        }
        let area = NSTrackingArea(
            rect: .zero, options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
            owner: self,
        )
        addTrackingArea(area)
        hoverArea = area
    }

    override func mouseMoved(with event: NSEvent) {
        let location = convert(event.locationInWindow, from: nil)
        hoverRegion = location.y <= Self.graphHeight ? Region.at(location.x / max(bounds.width, 1)) : nil
    }

    override func mouseExited(with _: NSEvent) {
        hoverRegion = nil
    }

    override func mouseDown(with event: NSEvent) {
        let location = convert(event.locationInWindow, from: nil)
        if indicatorFrame(trailing: false).contains(location) || indicatorFrame(trailing: true).contains(location) {
            model.showClipping.toggle()
            return
        }
        mouseDownX = location.y <= Self.graphHeight ? location.x : nil
    }

    override func mouseDragged(with event: NSEvent) {
        guard let startX = mouseDownX, hasPhoto else { return }
        let x = convert(event.locationInWindow, from: nil).x
        if dragRegion == nil {
            guard abs(x - startX) >= 2 else { return }
            let region = Region.at(startX / max(bounds.width, 1))
            dragStart = (startX, model.value(region.parameter))
            dragRegion = region
            model.beginEdit(region.parameter)
        }
        guard let region = dragRegion, let start = dragStart else { return }
        let spec = region.parameter.spec
        let span = spec.range.upperBound - spec.range.lowerBound
        model.setValue(region.parameter, start.value + (x - start.x) / bounds.width * span * 0.6)
    }

    override func mouseUp(with _: NSEvent) {
        mouseDownX = nil
        guard dragRegion != nil else { return }
        dragRegion = nil
        dragStart = nil
        model.endEdit()
    }

    // MARK: - Tooltips

    private func updateToolTips() {
        removeAllToolTips()
        addToolTip(indicatorFrame(trailing: false), owner: self, userData: nil)
        addToolTip(indicatorFrame(trailing: true), owner: self, userData: nil)
    }

    func view(
        _: NSView,
        stringForToolTip _: NSView.ToolTipTag,
        point _: NSPoint,
        userData _: UnsafeMutableRawPointer?,
    ) -> String {
        showClipping ? "Hide clipping (J)" : "Show clipping (J)"
    }
}

extension RGBA {
    init(_ color: NSColor) {
        self.init(
            red: color.redComponent,
            green: color.greenComponent,
            blue: color.blueComponent,
            alpha: color.alphaComponent,
        )
    }
}

extension FontSpec {
    var monospacedDigit: FontSpec {
        var copy = self
        copy.monospacedDigits = true
        return copy
    }
}

@_spi(Harness) public enum HistogramPanelView {
    @MainActor public static func make(model: EditorModel) -> NSView {
        HistogramGraphView(model: model)
    }
}

/// Hosts the AppKit histogram in the SwiftUI inspector. SwiftUI never updates it: it
/// follows the histogram itself.
struct HistogramHost: NSViewRepresentable {
    let model: EditorModel

    func makeNSView(context _: Context) -> NSView {
        HistogramGraphView(model: model)
    }

    func updateNSView(_: NSView, context _: Context) {}

    func sizeThatFits(_ proposal: ProposedViewSize, nsView _: NSView, context _: Context) -> CGSize? {
        CGSize(width: proposal.width ?? 290, height: HistogramGraphView.height)
    }
}
