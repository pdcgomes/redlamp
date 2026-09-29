import CoreGraphics
import Observation
import RedlampEngineAPI

/// Zoom and pan state for an image canvas, in Lightroom's terms.
@MainActor
@Observable
public final class CanvasController {
    public enum Zoom: Hashable, Sendable {
        case fit
        case fill
        /// Screen pixels per image pixel (1 = 100%).
        case scale(Double)

        public static let oneToOne = Zoom.scale(1)
        public static let twoToOne = Zoom.scale(2)
    }

    public var zoom: Zoom = .fit {
        didSet { changed() }
    }

    /// The normalised image point shown at the centre of the view.
    public var center = CGPoint(x: 0.5, y: 0.5) {
        didSet { changed() }
    }

    public var imageSize: PixelSize = .zero {
        didSet {
            if imageSize != oldValue {
                changed()
            }
        }
    }

    public private(set) var viewSize: CGSize = .zero
    public private(set) var backingScale: CGFloat = 2

    /// Bumped on every change so views can observe one value.
    public private(set) var revision = 0

    /// Called when the resolution the engine should render at changes.
    @ObservationIgnored public var onRenderSizeChange: ((PixelSize) -> Void)?
    @ObservationIgnored private var lastRenderSize = PixelSize.zero

    public init() {}

    // MARK: - Geometry

    private var viewPixels: CGSize {
        CGSize(width: viewSize.width * backingScale, height: viewSize.height * backingScale)
    }

    public var fitScale: Double {
        guard imageSize.width > 0, viewPixels.width > 0 else { return 1 }
        return min(
            Double(viewPixels.width) / Double(imageSize.width),
            Double(viewPixels.height) / Double(imageSize.height),
        )
    }

    public var fillScale: Double {
        guard imageSize.width > 0, viewPixels.width > 0 else { return 1 }
        return max(
            Double(viewPixels.width) / Double(imageSize.width),
            Double(viewPixels.height) / Double(imageSize.height),
        )
    }

    /// Screen pixels per image pixel at the current zoom.
    public var pixelScale: Double {
        switch zoom {
        case .fit: fitScale
        case .fill: fillScale
        case let .scale(value): value
        }
    }

    public var zoomPercent: Int {
        Int((pixelScale * 100).rounded())
    }

    public var isZoomedIn: Bool {
        pixelScale > fitScale + 1e-6
    }

    /// The image resolution the engine needs to render for the current view.
    public var renderSize: PixelSize {
        guard imageSize.width > 0 else { return .zero }
        let scale = min(pixelScale, 1)
        return PixelSize(
            width: max(1, Int((Double(imageSize.width) * scale).rounded(.up))),
            height: max(1, Int((Double(imageSize.height) * scale).rounded(.up))),
        )
    }

    /// The image's rectangle in view points.
    public func imageRect(in bounds: CGSize) -> CGRect {
        let scale = pixelScale / backingScale
        let width = Double(imageSize.width) * scale
        let height = Double(imageSize.height) * scale
        let clamped = clampedCenter(width: width, height: height, bounds: bounds)
        return CGRect(
            x: bounds.width / 2 - clamped.x * width,
            y: bounds.height / 2 - clamped.y * height,
            width: width,
            height: height,
        )
    }

    /// The visible part of the image, normalised (for the navigator).
    public var visibleImageRect: CGRect {
        let rect = imageRect(in: viewSize)
        guard rect.width > 0, rect.height > 0 else { return CGRect(x: 0, y: 0, width: 1, height: 1) }
        let visible = rect.intersection(CGRect(origin: .zero, size: viewSize))
        return CGRect(
            x: (visible.minX - rect.minX) / rect.width,
            y: (visible.minY - rect.minY) / rect.height,
            width: visible.width / rect.width,
            height: visible.height / rect.height,
        )
    }

    /// Normalised image coordinates for a point in the view, if it lies on the image.
    public func imagePoint(for viewPoint: CGPoint) -> CGPoint? {
        let rect = imageRect(in: viewSize)
        guard rect.contains(viewPoint), rect.width > 0 else { return nil }
        return CGPoint(x: (viewPoint.x - rect.minX) / rect.width, y: (viewPoint.y - rect.minY) / rect.height)
    }

    private func clampedCenter(width: Double, height: Double, bounds: CGSize) -> CGPoint {
        func clamp(_ value: Double, extent: Double, available: Double) -> Double {
            guard extent > available else { return 0.5 }
            let half = available / 2 / extent
            return min(max(value, half), 1 - half)
        }
        return CGPoint(
            x: clamp(center.x, extent: width, available: bounds.width),
            y: clamp(center.y, extent: height, available: bounds.height),
        )
    }

    // MARK: - Interaction

    public func updateView(size: CGSize, backingScale: CGFloat) {
        guard size != viewSize || backingScale != self.backingScale else { return }
        viewSize = size
        self.backingScale = backingScale
        changed()
    }

    /// Lightroom's click-to-zoom: fit ↔ 100% centred on the clicked point.
    public func toggleZoom(at viewPoint: CGPoint?) {
        if isZoomedIn {
            zoom = .fit
            center = CGPoint(x: 0.5, y: 0.5)
        } else {
            if let viewPoint, let point = imagePoint(for: viewPoint) {
                center = point
            }
            zoom = .oneToOne
        }
    }

    public func pan(byPoints delta: CGSize) {
        let rect = imageRect(in: viewSize)
        guard rect.width > 0 else { return }
        let current = CGPoint(
            x: (viewSize.width / 2 - rect.minX) / rect.width,
            y: (viewSize.height / 2 - rect.minY) / rect.height,
        )
        center = CGPoint(x: current.x - delta.width / rect.width, y: current.y - delta.height / rect.height)
    }

    public func magnify(by factor: Double, at viewPoint: CGPoint) {
        let anchor = imagePoint(for: viewPoint)
        let newScale = min(max(pixelScale * factor, fitScale), 8)
        zoom = abs(newScale - fitScale) < 1e-4 ? .fit : .scale(newScale)
        if let anchor, isZoomedIn {
            let rect = imageRect(in: viewSize)
            let offset = CGPoint(
                x: (viewPoint.x - viewSize.width / 2) / rect.width,
                y: (viewPoint.y - viewSize.height / 2) / rect.height,
            )
            center = CGPoint(x: anchor.x - offset.x, y: anchor.y - offset.y)
        }
    }

    private func changed() {
        revision &+= 1
        let size = renderSize
        if size != lastRenderSize, size.width > 0 {
            lastRenderSize = size
            onRenderSizeChange?(size)
        }
    }
}
