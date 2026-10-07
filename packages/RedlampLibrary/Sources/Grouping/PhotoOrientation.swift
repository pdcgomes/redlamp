import Foundation

/// Which way a photo is turned, from its size once its EXIF orientation is applied (LIB-41): the size
/// the index keeps, which the indexer turns upright, so a raw shot on its side is portrait though its
/// sensor's frame is landscape. The column store keeps it for every photo (`ColumnStore.orientation`).
public enum PhotoOrientation: String, Sendable, Hashable, CaseIterable, Codable {
    case landscape, portrait, square

    /// The orientation of a photo `width` by `height` pixels upright; nil without both.
    public init?(width: Int?, height: Int?) {
        guard let width, let height, width > 0, height > 0 else { return nil }
        self = width > height ? .landscape : width < height ? .portrait : .square
    }

    /// Its code in the column store, after 0 for none: its place in `allCases` and 1.
    var code: UInt8 {
        switch self {
        case .landscape: 1
        case .portrait: 2
        case .square: 3
        }
    }

    /// The orientation of `code`; nil for none.
    init?(code: UInt8) {
        switch code {
        case 1: self = .landscape
        case 2: self = .portrait
        case 3: self = .square
        default: return nil
        }
    }
}
