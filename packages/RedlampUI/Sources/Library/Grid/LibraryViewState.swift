import AppKit
import Foundation
import Observation

/// How the grid's cells look, cycled by J as in Lightroom Classic.
public enum GridCellStyle: String, CaseIterable, Sendable, Codable {
    /// The thumbnail and its badges.
    case compact
    /// The photo's name, date and camera settings above the thumbnail, and its badges below it.
    case expanded
    /// Thumbnails alone.
    case none

    /// J's next style: compact, expanded, none, and round again.
    public var next: GridCellStyle {
        switch self {
        case .compact: .expanded
        case .expanded: .none
        case .none: .compact
        }
    }

    public var title: String {
        switch self {
        case .compact: "Compact"
        case .expanded: "Expanded"
        case .none: "Thumbnails Only"
        }
    }
}

/// The grid's thumbnail size: a cell's width in points.
public enum GridSize {
    public static let range: ClosedRange<Double> = 80 ... 400
    public static let standard: Double = 124
    /// The sizes = and - step through.
    static let steps: [Double] = [80, 96, 112, 124, 144, 168, 196, 228, 264, 304, 352, 400]

    static func larger(than size: Double) -> Double {
        steps.first { $0 > size + 0.5 } ?? range.upperBound
    }

    static func smaller(than size: Double) -> Double {
        steps.last { $0 < size - 0.5 } ?? range.lowerBound
    }
}

/// The loupe's zoom: the whole photo, or one of its pixels to one of the screen's.
public enum LoupeZoom: String, Sendable {
    case fit
    case actual

    public var title: String {
        switch self {
        case .fit: "Fit"
        case .actual: "1:1"
        }
    }
}

/// The Library module's view: the grid's thumbnail size and cell style and the loupe's zoom, and each
/// source's view as it was last left (its size, cell style, the photo at the top of the grid and the
/// selection), for the 25 latest sources, as Lightroom Classic remembers them, and across launches.
@MainActor
@Observable
public final class LibraryViewState {
    public internal(set) var thumbnailSize = GridSize.standard
    public internal(set) var cellStyle = GridCellStyle.compact
    public internal(set) var loupeZoom = LoupeZoom.fit
    /// The photo at the top of the grid as it was last scrolled.
    @ObservationIgnored var topPhoto: URL?
    /// Where a source's grid goes back to when it's shown: set as the source's view is restored, and
    /// taken by the grid.
    var restoredTop: URL?
    /// Shows photos in Finder; the regression suite counts them instead.
    @ObservationIgnored @_spi(Harness) public var revealInFinder: @MainActor ([URL]) -> Void = { urls in
        NSWorkspace.shared.activateFileViewerSelecting(urls)
    }

    @ObservationIgnored private var views: [SourceView] = []
    @ObservationIgnored private let defaults: UserDefaults?

    static let keptSources = 25
    /// The photos of a source's selection it keeps; a larger selection keeps its first ones.
    static let keptSelection = 2000
    private static let viewsKey = "library.views"
    private static let sizeKey = "library.thumbnailSize"
    private static let styleKey = "library.cellStyle"

    /// A source's view as it was left. Photos are kept by path, so the view outlives the photos' IDs.
    struct SourceView: Codable, Equatable {
        var source: String
        var size: Double
        var style: GridCellStyle
        var top: String?
        var selected: [String]
        var active: String?
    }

    init(defaults: UserDefaults?) {
        self.defaults = defaults
        guard let defaults else { return }
        if defaults.object(forKey: Self.sizeKey) != nil {
            thumbnailSize = min(
                max(defaults.double(forKey: Self.sizeKey), GridSize.range.lowerBound),
                GridSize.range.upperBound,
            )
        }
        cellStyle = defaults.string(forKey: Self.styleKey).flatMap(GridCellStyle.init) ?? .compact
        if let data = defaults.data(forKey: Self.viewsKey),
           let saved = try? JSONDecoder().decode([SourceView].self, from: data) {
            views = saved
        }
    }

    func setThumbnailSize(_ size: Double) {
        let size = min(max(size, GridSize.range.lowerBound), GridSize.range.upperBound)
        guard size != thumbnailSize else { return }
        thumbnailSize = size
        defaults?.set(size, forKey: Self.sizeKey)
    }

    func setCellStyle(_ style: GridCellStyle) {
        guard style != cellStyle else { return }
        cellStyle = style
        defaults?.set(style.rawValue, forKey: Self.styleKey)
    }

    func setLoupeZoom(_ zoom: LoupeZoom) {
        guard zoom != loupeZoom else { return }
        loupeZoom = zoom
    }

    /// Keeps `source`'s view as it's left: the grid as it is, and these photos selected.
    func remember(_ source: String, selection: [URL], active: URL?) {
        let view = SourceView(
            source: source, size: thumbnailSize, style: cellStyle, top: topPhoto?.path,
            selected: selection.prefix(Self.keptSelection).map(\.path), active: active?.path,
        )
        views.removeAll { $0.source == source }
        views.append(view)
        if views.count > Self.keptSources {
            views.removeFirst(views.count - Self.keptSources)
        }
        topPhoto = nil
        save()
    }

    /// `source`'s view as it was left, its size and cell style shown again, and the grid going back to
    /// its top photo; nil for a source not seen lately.
    func restore(_ source: String) -> SourceView? {
        guard let view = views.last(where: { $0.source == source }) else { return nil }
        setThumbnailSize(view.size)
        setCellStyle(view.style)
        restoredTop = view.top.map { URL(fileURLWithPath: $0) }
        return view
    }

    private func save() {
        guard let defaults, let data = try? JSONEncoder().encode(views) else { return }
        defaults.set(data, forKey: Self.viewsKey)
    }
}
