import AppKit
import RedlampDesign
import RedlampEngineAPI
import SwiftUI

/// The RGB histogram with Lightroom's clipping indicators and drag-to-adjust regions,
/// and the capture summary under it.
///
/// The histogram arrives about 30 times a second while a photo renders. Its channels are an
/// image made off the main thread, shown in a layer of their own; the well and summary under
/// them and the indicators over them are drawn only when the photo, the clipping overlay or
/// the hovered region changes, without touching SwiftUI.
final class HistogramGraphView: LayerDrawnView, NSViewToolTipOwner {
    typealias Region = HistogramView.Region

    static let graphHeight: CGFloat = 104
    private static let spacing: CGFloat = 6
    private static let indicatorSize = CGSize(width: 14, height: 12)
    private nonisolated static let channelColors = [
        RGBA(red: 0.95, green: 0.25, blue: 0.25),
        RGBA(red: 0.25, green: 0.9, blue: 0.35),
        RGBA(red: 0.3, green: 0.45, blue: 1.0),
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
    private var readout: [String]?
    private var regionValue = 0.0

    /// What the drawn layers last showed, so an update that changes neither draws nothing.
    private struct Content: Equatable {
        var region: Region?
        /// Nil while the readout takes the summary's place.
        var summary: [String]?
    }

    /// The readout changes as the pointer moves, so it's drawn over the graph rather than with it.
    private struct Overlay: Equatable {
        var region: Region?
        var regionValue: Double
        var showClipping: Bool
        var shadowsClipped: Bool
        var highlightsClipped: Bool
        var readout: [String]?
    }

    private var content: Content?
    private var overlay: Overlay?

    /// The channels image asked for last; one that finishes after a newer request is dropped.
    private struct Channels: Equatable {
        var histogram: Histogram
        var size: CGSize
        var scale: CGFloat
    }

    private var channels: Channels?

    init(model: EditorModel) {
        self.model = model
        super.init(frame: .zero)
        addImageAndOverlayLayers()
        setAccessibilityIdentifier("histogram")
    }

    /// One adjustable region per slider the graph drags, at its span of the graph.
    override func accessibilityChildren() -> [Any]? {
        Region.allCases.map { region in
            let spec = region.parameter.spec
            let element = NSAccessibilityElement()
            element.setAccessibilityParent(self)
            element.setAccessibilityRole(.slider)
            element.setAccessibilityLabel(spec.label)
            element.setAccessibilityIdentifier("histogram.\(region.parameter.rawValue)")
            element.setAccessibilityValue(spec.formatted(model.value(region.parameter)))
            let width = bounds.width
            let graph = CGRect(
                x: width * region.span.lowerBound, y: isFlipped ? 0 : bounds.height - Self.graphHeight,
                width: width * (region.span.upperBound - region.span.lowerBound), height: Self.graphHeight,
            )
            element.setAccessibilityFrameInParentSpace(graph)
            return element
        }
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
            readout = model.pixelReadout.map {
                EditorModel.readoutParts($0, lab: model.showsLabReadout, approximate: model.readoutIsApproximate)
            }
            showClipping = model.showClipping
            regionValue = region.map { model.value($0.parameter) } ?? 0
            update()
        }
    }

    private func update() {
        let content = Content(region: shownRegion, summary: readout == nil ? summary : nil)
        if content != self.content {
            self.content = content
            setNeedsContentDisplay()
        }
        let overlay = Overlay(
            region: shownRegion, regionValue: regionValue, showClipping: showClipping,
            shadowsClipped: histogram.shadowsClipped, highlightsClipped: histogram.highlightsClipped,
            readout: readout,
        )
        if overlay != self.overlay {
            if overlay.region != self.overlay?.region {
                updateToolTips()
            }
            self.overlay = overlay
            setNeedsOverlayDisplay()
        }
        updateChannels()
    }

    override func layout() {
        super.layout()
        updateToolTips()
        updateChannels()
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

    private var channelsRect: CGRect {
        CGRect(x: 2, y: 14, width: bounds.width - 4, height: Self.graphHeight - 18)
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

        if readout == nil {
            drawLine(summary, y: graph.maxY + Self.spacing, scale: scale)
        }
    }

    override func drawOverlay(in _: CGRect) {
        drawIndicator(clipped: histogram.shadowsClipped, color: .systemBlue, trailing: false)
        drawIndicator(clipped: histogram.highlightsClipped, color: .systemRed, trailing: true)
        if let readout {
            drawLine(readout, y: Self.graphHeight + Self.spacing, scale: backingScale, color: Palette.value.nsColor)
        }
        if let region = shownRegion {
            let spec = region.parameter.spec
            TextLine.draw(
                "\(spec.label)  \(spec.formatted(regionValue))", font: Self.captionFont, color: Palette.value.nsColor,
                in: CGRect(x: 0, y: 4, width: bounds.width, height: indicatorRowHeight), alignment: .center,
                scale: backingScale,
            )
        }
    }

    private func updateChannels() {
        let rect = channelsRect
        let request = Channels(histogram: histogram, size: rect.size, scale: backingScale)
        guard request != channels else { return }
        channels = request
        Task { [weak self] in
            let image = await Task.detached(priority: .userInitiated) {
                Self.channelsImage(request.histogram, size: request.size, scale: request.scale)
            }.value
            guard let self, channels == request else { return }
            let size = image.map { CGSize(width: CGFloat($0.width), height: CGFloat($0.height)) } ?? .zero
            let frame = CGRect(
                x: rect.minX, y: rect.maxY - size.height / request.scale,
                width: size.width / request.scale, height: size.height / request.scale,
            )
            setImage(image, frame: frame)
        }
    }

    /// The channels at `size` points, top row first; nil for an empty histogram.
    private nonisolated static func channelsImage(_ histogram: Histogram, size: CGSize, scale: CGFloat) -> CGImage? {
        let bins = [histogram.red, histogram.green, histogram.blue]
        let peak = bins.flatMap { $0.dropFirst().dropLast() }.max() ?? 0
        guard peak > 0 else { return nil }
        let peakScale = sqrt(Double(peak))
        // SwiftUI adds the channels (plus-lighter) in sRGB; blending in the window's wider
        // color space would tint the overlaps. So they are composited in an sRGB bitmap.
        let width = Int((size.width * scale).rounded(.up)), height = Int((size.height * scale).rounded(.up))
        guard width > 0, height > 0, let space = CGColorSpace(name: CGColorSpace.sRGB),
              let bitmap = CGContext(
                  data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0, space: space,
                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue,
              )
        else { return nil }
        // Flipped, in points, like the view.
        bitmap.translateBy(x: 0, y: CGFloat(height))
        bitmap.scaleBy(x: scale, y: -scale)
        bitmap.setBlendMode(.plusLighter)
        for (channel, color) in zip(bins, channelColors) {
            let path = CGMutablePath()
            path.move(to: CGPoint(x: 0, y: size.height))
            for (index, count) in channel.enumerated() {
                let x = Double(index) / Double(channel.count - 1) * size.width
                let y = size.height - min(sqrt(Double(count)) / peakScale, 1) * size.height
                path.addLine(to: CGPoint(x: x, y: y))
            }
            path.addLine(to: CGPoint(x: size.width, y: size.height))
            path.closeSubpath()
            bitmap.addPath(path)
            bitmap.setFillColor(color.opacity(0.55).cgColor)
            bitmap.fillPath()
        }
        return bitmap.makeImage()
    }

    private func drawIndicator(clipped: Bool, color: NSColor, trailing: Bool) {
        let tint = clipped || showClipping ? color.usingColorSpace(.sRGB).map(RGBA.init) : Palette.tertiaryLabel
        guard let tint else { return }
        let frame = indicatorFrame(trailing: trailing)
        Symbol.draw(
            "arrowtriangle.up.fill", pointSize: 8, color: tint, centeredAt: CGPoint(x: frame.midX, y: frame.midY),
            rotation: trailing ? 45 : -45, scale: backingScale,
        )
    }

    /// The line under the graph: the capture summary, or the readout while the pointer is over the photo.
    private func drawLine(
        _ parts: [String],
        y: CGFloat,
        scale: CGFloat,
        color: NSColor = Palette.secondaryLabel.nsColor,
    ) {
        let parts = parts.isEmpty ? [" "] : parts
        let font = Self.captionFont
        let widths = parts.map { ceil(TextLine.width($0, font: font) * scale) / scale }
        let total = widths.reduce(0, +) + 12 * CGFloat(parts.count - 1)
        var x = PixelGrid.round((bounds.width - total) / 2, scale: scale)
        let height = TextLine.lineHeight(font)
        for (part, width) in zip(parts, widths) {
            TextLine.draw(
                part,
                font: font,
                color: color,
                in: CGRect(x: x, y: y, width: width, height: height),
                scale: scale,
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

    /// Lightroom Classic's histogram menu: the readout in L*a*b* rather than RGB.
    override func menu(for _: NSEvent) -> NSMenu? {
        let menu = NSMenu()
        let item = NSMenuItem(
            title: ShortcutAction.labReadout.title,
            action: #selector(toggleLabReadout),
            keyEquivalent: "",
        )
        item.target = self
        item.state = model.showsLabReadout ? .on : .off
        item.setAccessibilityIdentifier("histogram.labReadout")
        menu.addItem(item)
        return menu
    }

    @objc private func toggleLabReadout() {
        model.perform(.labReadout)
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
