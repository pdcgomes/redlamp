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
    public var strategy = FocusStackStrategy.auto
    public var showsDepth = false
    public private(set) var preview: FocusStackPreview?
    /// 0 ... 1 while merging, else nil.
    public private(set) var progress: Double?
    public private(set) var errorMessage: String?
    public private(set) var thumbnails: [URL: CGImage] = [:]

    @ObservationIgnored private let engine: any EditingEngine
    /// What `preview` was merged from.
    @ObservationIgnored private var merged: (strategy: FocusStackStrategy, excluded: Set<URL>)?

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
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    public var included: [URL] {
        frames.filter { !excluded.contains($0) }
    }

    /// Whether the settings differ from what the preview shows.
    public var hasChanges: Bool {
        guard let merged else { return true }
        return merged.strategy != strategy || merged.excluded != excluded
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
        let settings = (strategy: strategy, excluded: excluded)
        errorMessage = nil
        progress = 0
        defer { progress = nil }
        do {
            try FocusStackDocument(
                frames: included, excluded: frames.filter(excluded.contains), strategy: strategy, at: documentURL,
            ).write(to: documentURL)
            preview = try await engine.focusStack(at: documentURL, maxLongEdge: Self.previewLongEdge) { value in
                Task { @MainActor [weak self] in
                    if self?.progress != nil {
                        self?.progress = value
                    }
                }
            }
            merged = settings
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    public func loadThumbnail(for frame: URL) async {
        guard thumbnails[frame] == nil else { return }
        if let image = await engine.thumbnail(for: frame, maxPixelSize: 192) {
            thumbnails[frame] = image
        }
    }
}
