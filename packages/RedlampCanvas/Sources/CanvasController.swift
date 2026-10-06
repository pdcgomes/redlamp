import CoreGraphics
import Observation
import RedlampEngineAPI

/// Space reserved around the stage for panels that float over the canvas, in points.
public struct StageInsets: Hashable, Sendable {
    public var leading: CGFloat
    public var trailing: CGFloat
    public var top: CGFloat
    public var bottom: CGFloat

    public init(leading: CGFloat = 0, trailing: CGFloat = 0, top: CGFloat = 0, bottom: CGFloat = 0) {
        self.leading = leading
        self.trailing = trailing
        self.top = top
        self.bottom = bottom
    }

    public static let zero = StageInsets()
}

/// Zoom and pan state for an image canvas, in Lightroom's terms.
///
/// Geometry is computed against the *stage*: the view minus `stageInsets`. The canvas
/// itself spans the whole window with panels floating over it, so resizing a panel never
/// moves or rescales the photo; only changing the insets (showing or hiding a panel) does.
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

    /// Lightroom Classic's zoom ratios (the Navigator menu and ⌘= / ⌘- steps).
    public static let zoomRatios: [Double] = [1 / 16, 1 / 8, 1 / 4, 1 / 3, 1 / 2, 1, 2, 3, 4, 8, 11]
    /// 11:1, Lightroom Classic's closest zoom.
    public static let maxScale = 11.0

    /// "1:4", "1:1", "11:1"…
    public static func ratioLabel(_ scale: Double) -> String {
        scale >= 1 ? "\(Int(scale.rounded())):1" : "1:\(Int((1 / scale).rounded()))"
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

    public var stageInsets = StageInsets.zero {
        didSet {
            if stageInsets != oldValue {
                changed()
            }
        }
    }

    /// How a before/after comparison shares the canvas with the photo.
    public var comparison = Comparison.none {
        didSet {
            if comparison != oldValue {
                changed()
            }
        }
    }

    public private(set) var viewSize: CGSize = .zero
    public private(set) var backingScale: CGFloat = 2

    /// Bumped on every change so views can observe one value.
    public private(set) var revision = 0

    /// What the engine should render for the current view.
    public struct RenderTarget: Hashable, Sendable {
        public var size: PixelSize
        /// `nil` renders the whole photo; otherwise only this part, at `size`.
        public var region: ImageRect?

        public init(size: PixelSize, region: ImageRect? = nil) {
            self.size = size
            self.region = region
        }
    }

    /// Called when the engine needs to render a different size or part of the photo.
    @ObservationIgnored public var onRenderSizeChange: ((PixelSize) -> Void)?
    /// Updated only when the view needs pixels the last target didn't cover, so panning inside
    /// the rendered margin doesn't re-render.
    @ObservationIgnored public private(set) var renderTarget = RenderTarget(size: .zero, region: nil)

    public init() {}

    // MARK: - Geometry

    /// The area the photo is fitted and centred in, for a view of `bounds` size: the whole
    /// stage, or side by side, the after pane (right or bottom).
    public func stage(in bounds: CGSize) -> CGRect {
        panes(in: bounds)?.primary ?? fullStage(in: bounds)
    }

    /// The view minus the insets.
    func fullStage(in bounds: CGSize) -> CGRect {
        CGRect(
            x: stageInsets.leading,
            y: stageInsets.top,
            width: max(bounds.width - stageInsets.leading - stageInsets.trailing, 1),
            height: max(bounds.height - stageInsets.top - stageInsets.bottom, 1),
        )
    }

    private var viewPixels: CGSize {
        let stage = stage(in: viewSize)
        return CGSize(width: stage.width * backingScale, height: stage.height * backingScale)
    }

    public var fitScale: Double {
        fitScale(for: imageSize)
    }

    private func fitScale(for size: PixelSize) -> Double {
        guard size.width > 0, viewPixels.width > 0 else { return 1 }
        return min(
            Double(viewPixels.width) / Double(size.width),
            Double(viewPixels.height) / Double(size.height),
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
        renderSize(for: imageSize, scale: pixelScale)
    }

    /// The resolution an image of `size` needs at Fit, before it is shown.
    public func fitRenderSize(for size: PixelSize) -> PixelSize {
        renderSize(for: size, scale: fitScale(for: size))
    }

    private func renderSize(for size: PixelSize, scale: Double) -> PixelSize {
        guard size.width > 0 else { return .zero }
        let scale = min(scale, 1)
        return PixelSize(
            width: max(1, Int((Double(size.width) * scale).rounded(.up))),
            height: max(1, Int((Double(size.height) * scale).rounded(.up))),
        )
    }

    /// The image's rectangle in view points.
    public func imageRect(in bounds: CGSize) -> CGRect {
        let scale = pixelScale / backingScale
        let width = Double(imageSize.width) * scale
        let height = Double(imageSize.height) * scale
        let stage = stage(in: bounds)
        let clamped = clampedCenter(width: width, height: height, stage: stage.size)
        return CGRect(
            x: stage.midX - clamped.x * width,
            y: stage.midY - clamped.y * height,
            width: width,
            height: height,
        )
    }

    /// The part of the image inside the stage, normalised (for the navigator).
    public var visibleImageRect: CGRect {
        let rect = imageRect(in: viewSize)
        guard rect.width > 0, rect.height > 0 else { return CGRect(x: 0, y: 0, width: 1, height: 1) }
        let visible = rect.intersection(stage(in: viewSize))
        return CGRect(
            x: (visible.minX - rect.minX) / rect.width,
            y: (visible.minY - rect.minY) / rect.height,
            width: visible.width / rect.width,
            height: visible.height / rect.height,
        )
    }

    /// Normalised image coordinates for a point in the view, if it lies on the image (in
    /// either pane).
    public func imagePoint(for viewPoint: CGPoint) -> CGPoint? {
        let viewPoint = primaryPoint(for: viewPoint)
        let rect = imageRect(in: viewSize)
        guard rect.contains(viewPoint), rect.width > 0 else { return nil }
        return CGPoint(x: (viewPoint.x - rect.minX) / rect.width, y: (viewPoint.y - rect.minY) / rect.height)
    }

    private func clampedCenter(width: Double, height: Double, stage: CGSize) -> CGPoint {
        clamped(center, width: width, height: height, stage: stage)
    }

    /// The closest point to `point` the stage can be centred on without showing past the image edges.
    private func clamped(_ point: CGPoint, width: Double, height: Double, stage: CGSize) -> CGPoint {
        func clamp(_ value: Double, extent: Double, available: Double) -> Double {
            guard extent > available else { return 0.5 }
            let half = available / 2 / extent
            return min(max(value, half), 1 - half)
        }
        return CGPoint(
            x: clamp(point.x, extent: width, available: stage.width),
            y: clamp(point.y, extent: height, available: stage.height),
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

    /// Zoom steps for ⌘= / ⌘-: Fit, then Lightroom's ratios up to 11:1.
    private var zoomSteps: [Double] {
        ([fitScale] + Self.zoomRatios.filter { $0 > fitScale + 1e-3 }).sorted()
    }

    /// `scale` limited to the range the wheel and pinch zoom through: Fit to 11:1.
    public func clampedScale(_ scale: Double) -> Double {
        min(max(scale, fitScale), Self.maxScale)
    }

    public func zoomIn() {
        guard let next = zoomSteps.first(where: { $0 > pixelScale + 1e-3 }) else { return }
        zoom = .scale(next)
    }

    public func zoomOut() {
        guard let previous = zoomSteps.last(where: { $0 < pixelScale - 1e-3 }) else { return }
        if abs(previous - fitScale) < 1e-3 {
            zoom = .fit
            center = CGPoint(x: 0.5, y: 0.5)
        } else {
            zoom = .scale(previous)
        }
    }

    public func pan(byPoints delta: CGSize) {
        let rect = imageRect(in: viewSize)
        let stage = stage(in: viewSize)
        guard rect.width > 0 else { return }
        let current = CGPoint(
            x: (stage.midX - rect.minX) / rect.width,
            y: (stage.midY - rect.minY) / rect.height,
        )
        center = CGPoint(x: current.x - delta.width / rect.width, y: current.y - delta.height / rect.height)
    }

    public func magnify(by factor: Double, at viewPoint: CGPoint) {
        zoom(toScale: pixelScale * factor, anchoredAt: viewPoint)
    }

    /// Zooms to `scale` (Fit to 11:1), keeping the image point under `viewPoint` where it is.
    public func zoom(toScale scale: Double, anchoredAt viewPoint: CGPoint) {
        let viewPoint = primaryPoint(for: viewPoint)
        let before = imageRect(in: viewSize)
        guard before.width > 0, before.height > 0 else { return }
        let anchor = CGPoint(
            x: (viewPoint.x - before.minX) / before.width,
            y: (viewPoint.y - before.minY) / before.height,
        )
        let newScale = clampedScale(scale)
        zoom = abs(newScale - fitScale) < 1e-4 ? .fit : .scale(newScale)
        guard isZoomedIn else { return }
        let rect = imageRect(in: viewSize)
        let stage = stage(in: viewSize)
        let wanted = CGPoint(
            x: anchor.x - (viewPoint.x - stage.midX) / rect.width,
            y: anchor.y - (viewPoint.y - stage.midY) / rect.height,
        )
        center = clamped(wanted, width: rect.width, height: rect.height, stage: stage.size)
    }

    /// Centres the stage on a normalised image point, as far as the image edges allow
    /// (dragging the Navigator's viewport).
    public func centerOn(_ point: CGPoint) {
        let rect = imageRect(in: viewSize)
        center = clamped(point, width: rect.width, height: rect.height, stage: stage(in: viewSize).size)
    }

    private func changed() {
        revision &+= 1
        let next = plannedRenderTarget()
        guard next.size.width > 0, next != renderTarget else { return }
        if next.region != nil, next.size == renderTarget.size, let current = renderTarget.region,
           Self.contains(current, visibleImageRect) {
            return
        }
        renderTarget = next
        onRenderSizeChange?(next.size)
    }
}

extension CanvasController {
    /// When zoomed in, only the visible part plus a margin of half the visible size each way,
    /// at the density the zoom needs. The region keeps its size while panning (it shifts
    /// rather than shrinks at the edges), and its origin sits on the output pixel grid, so
    /// successive regions line up exactly.
    func plannedRenderTarget() -> RenderTarget {
        let whole = RenderTarget(size: renderSize, region: nil)
        guard isZoomedIn, imageSize.width > 0 else { return whole }
        let visible = visibleImageRect
        let width = min(visible.width * 2, 1)
        let height = min(visible.height * 2, 1)
        guard width * height < 0.6 else { return whole }
        let density = min(pixelScale, 1)
        let columns = Double(imageSize.width) * density
        let rows = Double(imageSize.height) * density
        let size = PixelSize(width: Int((width * columns).rounded(.up)), height: Int((height * rows).rounded(.up)))
        func origin(_ center: Double, extent: Double, pixels: Double) -> Double {
            let start = min(max(center - extent / 2, 0), 1 - extent)
            return (start * pixels).rounded(.down) / pixels
        }
        let region = ImageRect(
            x: origin(visible.midX, extent: width, pixels: columns),
            y: origin(visible.midY, extent: height, pixels: rows),
            width: Double(size.width) / columns,
            height: Double(size.height) / rows,
        )
        return RenderTarget(size: size, region: region)
    }

    /// Output pixels rendered past each edge of the visible part during a continuous edit.
    public static let editGuard = 64

    /// While a slider is dragged: only the visible part plus `editGuard` output pixels each
    /// way, its origin on the output pixel grid, so each frame of the drag costs about what
    /// the screen shows. The margin target comes back once the edit ends.
    public func editRenderTarget() -> RenderTarget {
        let whole = RenderTarget(size: renderSize, region: nil)
        guard isZoomedIn, imageSize.width > 0 else { return whole }
        let visible = visibleImageRect
        let density = min(pixelScale, 1)
        let columns = Double(imageSize.width) * density
        let rows = Double(imageSize.height) * density
        let band = Double(Self.editGuard)
        func span(_ low: Double, _ high: Double, pixels: Double) -> (start: Double, count: Int) {
            let start = max((low * pixels).rounded(.down) - band, 0)
            let end = min((high * pixels).rounded(.up) + band, pixels)
            return (start, max(1, Int((end - start).rounded(.up))))
        }
        let x = span(visible.minX, visible.maxX, pixels: columns)
        let y = span(visible.minY, visible.maxY, pixels: rows)
        let size = PixelSize(width: x.count, height: y.count)
        guard x.start > 0 || y.start > 0 || size != whole.size else { return whole }
        let region = ImageRect(
            x: x.start / columns,
            y: y.start / rows,
            width: Double(size.width) / columns,
            height: Double(size.height) / rows,
        )
        return RenderTarget(size: size, region: region)
    }

    static func contains(_ region: ImageRect, _ visible: CGRect) -> Bool {
        let slack = 1e-6
        return visible.minX >= region.x - slack && visible.minY >= region.y - slack
            && visible.maxX <= region.x + region.width + slack && visible.maxY <= region.y + region.height + slack
    }
}
