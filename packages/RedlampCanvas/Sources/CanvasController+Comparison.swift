import CoreGraphics

/// Before/after geometry: side-by-side panes and the diagonal split.
public extension CanvasController {
    enum Comparison: Hashable, Sendable {
        case none
        /// Before and after in two panes (before left or top), each fitting the photo, zoomed
        /// and panned together.
        case sideBySide
        /// Before over after, cut by a line parallel to the visible photo's bottom-left to
        /// top-right diagonal. `position` moves it from the top-left corner (0) to the
        /// bottom-right one (1).
        case split(position: Double)
    }

    enum PaneAxis: Hashable, Sendable {
        /// Left and right.
        case horizontal
        /// Top and bottom.
        case vertical
    }

    /// Space between side-by-side panes, in points.
    static let paneGap: CGFloat = 8

    /// Side by side, the before pane (left or top).
    func comparisonStage(in bounds: CGSize) -> CGRect? {
        panes(in: bounds)?.comparison
    }

    /// Side by side, whichever arrangement shows the photo larger.
    func paneAxis(in bounds: CGSize) -> PaneAxis {
        let stage = fullStage(in: bounds)
        let width = Double(max(imageSize.width, 1))
        let height = Double(max(imageSize.height, 1))
        let across = min((stage.width - Self.paneGap) / 2 / width, stage.height / height)
        let stacked = min(stage.width / width, (stage.height - Self.paneGap) / 2 / height)
        return stacked > across ? .vertical : .horizontal
    }

    internal func panes(in bounds: CGSize) -> (comparison: CGRect, primary: CGRect)? {
        guard comparison == .sideBySide else { return nil }
        let stage = fullStage(in: bounds)
        switch paneAxis(in: bounds) {
        case .horizontal:
            let width = max((stage.width - Self.paneGap) / 2, 1)
            return (
                CGRect(x: stage.minX, y: stage.minY, width: width, height: stage.height),
                CGRect(x: stage.maxX - width, y: stage.minY, width: width, height: stage.height),
            )
        case .vertical:
            let height = max((stage.height - Self.paneGap) / 2, 1)
            return (
                CGRect(x: stage.minX, y: stage.minY, width: stage.width, height: height),
                CGRect(x: stage.minX, y: stage.maxY - height, width: stage.width, height: height),
            )
        }
    }

    /// Side by side, the photo's rectangle in the before pane, in view points.
    func comparisonImageRect(in bounds: CGSize) -> CGRect? {
        guard let panes = panes(in: bounds) else { return nil }
        return imageRect(in: bounds).offsetBy(
            dx: panes.comparison.minX - panes.primary.minX,
            dy: panes.comparison.minY - panes.primary.minY,
        )
    }

    /// The same spot of the photo in the after pane, for a point in the before pane, so
    /// clicks, pinches and wheel zooms there act on the point under the pointer.
    func primaryPoint(for viewPoint: CGPoint) -> CGPoint {
        guard let panes = panes(in: viewSize) else { return viewPoint }
        let inComparison = switch paneAxis(in: viewSize) {
        case .horizontal: viewPoint.x < panes.primary.minX
        case .vertical: viewPoint.y < panes.primary.minY
        }
        guard inComparison else { return viewPoint }
        return CGPoint(
            x: viewPoint.x + panes.primary.minX - panes.comparison.minX,
            y: viewPoint.y + panes.primary.minY - panes.comparison.minY,
        )
    }

    /// The part of the photo on screen, in view points.
    func visibleImageFrame(in bounds: CGSize) -> CGRect {
        imageRect(in: bounds).intersection(stage(in: bounds))
    }

    /// With a split comparison, the line's ends in view points, across the visible photo.
    func splitLine(in bounds: CGSize) -> (start: CGPoint, end: CGPoint)? {
        guard case let .split(position) = comparison else { return nil }
        let frame = visibleImageFrame(in: bounds)
        guard !frame.isNull, frame.width > 0, frame.height > 0 else { return nil }
        // Normalised to the visible frame, the line is u + v = 2 * position.
        let sum = 2 * min(max(position, 0), 1)
        let ends = sum <= 1
            ? (CGPoint(x: sum, y: 0), CGPoint(x: 0, y: sum))
            : (CGPoint(x: 1, y: sum - 1), CGPoint(x: sum - 1, y: 1))
        func place(_ point: CGPoint) -> CGPoint {
            CGPoint(x: frame.minX + point.x * frame.width, y: frame.minY + point.y * frame.height)
        }
        return (place(ends.0), place(ends.1))
    }

    /// The split position whose line passes through `viewPoint`.
    func splitPosition(through viewPoint: CGPoint) -> Double {
        let frame = visibleImageFrame(in: viewSize)
        guard !frame.isNull, frame.width > 0, frame.height > 0 else { return 0.5 }
        let u = (viewPoint.x - frame.minX) / frame.width
        let v = (viewPoint.y - frame.minY) / frame.height
        return min(max((u + v) / 2, 0), 1)
    }
}
