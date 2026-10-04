import CoreGraphics
import Foundation
import Observation
import RedlampEngineAPI

/// The Stack workspace's state: which frames go in, how they are merged, and the result.
/// Every merge rewrites the document first, so what's shown is always what's saved.
@MainActor
@Observable
public final class StackWorkspaceModel: Identifiable {
    /// Long edge of the preview the workspace shows.
    static let previewLongEdge = 2048

    public let documentURL: URL
    /// Every frame, included or not, in name (capture) order.
    public private(set) var frames: [URL] = []
    public private(set) var excluded: Set<URL> = []
    /// Included frames the preview's merge left out because they couldn't be read.
    public private(set) var unreadable: Set<URL> = []
    public var strategy = FocusStackStrategy.auto
    public var showsDepth = false
    public private(set) var preview: FocusStackPreview?
    /// 0 ... 1 while merging, else nil.
    public private(set) var progress: Double?
    public private(set) var errorMessage: String?
    public private(set) var thumbnails: [URL: CGImage] = [:]

    /// Where a retouch stroke takes its pixels from.
    public enum BrushSource: Hashable {
        /// The frame sharpest where the stroke starts, from the depth map.
        case underCursor
        case frame(URL)
        case strategy(FocusStackStrategy)
    }

    public private(set) var strokes: [FocusStackStroke] = []
    public var isRetouching = false
    public var brushSource = BrushSource.underCursor
    /// Fraction of the image's long edge.
    public var brushRadius = 0.02
    /// 1: full strength to the edge; 0: fades from the centre.
    public var brushHardness = 0.5
    public var brushOpacity = 1.0

    /// `[` and `]` while retouching: the brush's size by about 15%, or with Shift its softness
    /// (hardness down for `]`, as a feather grows).
    func nudgeBrush(direction: Double, hardness: Bool) {
        scrollBrush(by: hardness ? direction * 2 : direction, hardness: hardness)
    }

    /// ⌘-scroll over the preview: the size by about 15% a notch, or the hardness by 0.05.
    func scrollBrush(by notches: Double, hardness: Bool) {
        if hardness {
            brushHardness = min(max(brushHardness - notches * 0.05, 0), 1)
        } else {
            brushRadius = min(max(brushRadius * pow(1.15, notches), 0.005), 0.1)
        }
    }

    @ObservationIgnored private let engine: any EditingEngine
    /// What `preview` was merged from.
    @ObservationIgnored private var merged: Settings?
    /// The preview's depth map, for "frame under cursor".
    @ObservationIgnored private var depthMap: DepthMap?

    private struct Settings: Equatable {
        var strategy: FocusStackStrategy
        var excluded: Set<URL>
        var strokes: [FocusStackStroke]
    }

    private struct DepthMap {
        let width: Int
        let height: Int
        let bytes: [UInt8]
    }

    init(documentURL: URL, engine: any EditingEngine) {
        self.documentURL = documentURL
        self.engine = engine
        do {
            let document = try FocusStackDocument.read(documentURL)
            excluded = Set(document.excludedURLs(at: documentURL))
            frames = (document.frameURLs(at: documentURL) + excluded).sorted {
                $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending
            }
            strategy = document.strategy
            strokes = document.retouch ?? []
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    public var included: [URL] {
        frames.filter { !excluded.contains($0) }
    }

    /// Whether the settings differ from what the preview shows.
    public var hasChanges: Bool {
        merged != Settings(strategy: strategy, excluded: excluded, strokes: strokes)
    }

    public var isMerging: Bool {
        progress != nil
    }

    /// The preview's reference frame (the narrowest view, which sets the framing).
    public var referenceFrame: URL? {
        guard let preview, included.indices.contains(preview.report.reference) else { return nil }
        return included[preview.report.reference]
    }

    /// Includes or leaves out a frame; a stack keeps at least two.
    public func toggle(_ frame: URL) {
        if excluded.contains(frame) {
            excluded.remove(frame)
        } else if included.count > 2 {
            excluded.insert(frame)
        }
    }

    /// Saves the document and merges it, or reads the merge from the cache.
    public func merge() async {
        guard !isMerging else { return }
        let settings = Settings(strategy: strategy, excluded: excluded, strokes: strokes)
        errorMessage = nil
        progress = 0
        defer { progress = nil }
        do {
            var document = FocusStackDocument(
                frames: included, excluded: frames.filter(excluded.contains), strategy: strategy, at: documentURL,
            )
            document.retouch = strokes.isEmpty ? nil : strokes
            try document.write(to: documentURL)
            let preview = try await engine.focusStack(at: documentURL, maxLongEdge: Self.previewLongEdge) { value in
                Task { @MainActor [weak self] in
                    if self?.progress != nil {
                        self?.progress = value
                    }
                }
            }
            let frames = included
            self.preview = preview
            unreadable = Set((preview.report.failedFrames ?? []).compactMap { failed in
                frames.indices.contains(failed.index) ? frames[failed.index] : nil
            })
            if case let .frame(frame) = brushSource, unreadable.contains(frame) {
                brushSource = .underCursor
            }
            depthMap = Self.depthMap(preview.depth)
            merged = settings
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    // MARK: - Retouching

    /// The frame sharpest at `point` (oriented, normalised), from the preview's depth map: of the
    /// frames that could be read, the nearest in focus.
    public func frame(at point: CGPoint) -> URL? {
        guard let depth = depthMap, !included.isEmpty else { return nil }
        let x = min(max(Int(point.x * CGFloat(depth.width)), 0), depth.width - 1)
        let y = min(max(Int(point.y * CGFloat(depth.height)), 0), depth.height - 1)
        let position = Double(depth.bytes[y * depth.width + x]) / 255 * Double(included.count - 1)
        return included.indices
            .filter { !unreadable.contains(included[$0]) }
            .min { abs(Double($0) - position) < abs(Double($1) - position) }
            .map { included[$0] }
    }

    /// Adds a stroke along `points` (oriented, normalised) from the brush's source, and applies it.
    public func addStroke(_ points: [CGPoint]) async {
        guard let first = points.first, !isMerging else { return }
        let source: FocusStackStroke.Source
        switch brushSource {
        case .underCursor:
            guard let frame = frame(at: first) else { return }
            source = .frame(relativePath(frame))
        case let .frame(frame):
            guard !unreadable.contains(frame) else { return }
            source = .frame(relativePath(frame))
        case let .strategy(other):
            source = .strategy(other)
        }
        strokes.append(FocusStackStroke(
            source: source, radius: brushRadius, hardness: brushHardness, opacity: brushOpacity,
            points: points.map { SIMD2(Double($0.x), Double($0.y)) },
        ))
        await merge()
    }

    public func undoStroke() async {
        guard !strokes.isEmpty else { return }
        strokes.removeLast()
        await merge()
    }

    public func clearStrokes() async {
        guard !strokes.isEmpty else { return }
        strokes.removeAll()
        await merge()
    }

    /// A frame's path as the document stores it.
    private func relativePath(_ frame: URL) -> String {
        FocusStackDocument(frames: [frame], at: documentURL).frames[0]
    }

    private static func depthMap(_ image: CGImage) -> DepthMap? {
        var bytes = [UInt8](repeating: 0, count: image.width * image.height)
        guard let context = CGContext(
            data: &bytes, width: image.width, height: image.height, bitsPerComponent: 8, bytesPerRow: image.width,
            space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue,
        ) else {
            return nil
        }
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        return DepthMap(width: image.width, height: image.height, bytes: bytes)
    }

    public func loadThumbnail(for frame: URL) async {
        guard thumbnails[frame] == nil else { return }
        if let image = await engine.thumbnail(for: frame, maxPixelSize: 192) {
            thumbnails[frame] = image
        }
    }
}
