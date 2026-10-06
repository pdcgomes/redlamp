import Foundation

/// Which way a photo is turned, from its size once its EXIF orientation is applied (LIB-41).
public enum PhotoOrientation: String, Sendable, Hashable, CaseIterable, Codable {
    case landscape, portrait, square

    /// The orientation of a photo `width` by `height` pixels upright; nil without both.
    public init?(width: Int?, height: Int?) {
        guard let width, let height, width > 0, height > 0 else { return nil }
        self = width > height ? .landscape : width < height ? .portrait : .square
    }
}

/// Photos' orientations by ID (LIB-41), from the sizes the index keeps for them upright: the column
/// store keeps their megapixels and their aspect, the same whichever way they're turned. A byte a
/// photo, for every ID up to the largest.
public struct PhotoOrientations: Sendable {
    /// By ID: 0 for none, else the orientation's place in `PhotoOrientation.allCases` and 1.
    private var codes = ContiguousArray<UInt8>()

    public init() {}

    public subscript(photo: Int64) -> PhotoOrientation? {
        get {
            let code = code(of: photo)
            return code == 0 ? nil : PhotoOrientation.allCases[Int(code) - 1]
        }
        set {
            guard photo >= 0 else { return }
            if photo >= codes.count {
                guard newValue != nil else { return }
                codes.append(contentsOf: repeatElement(0, count: Int(photo) + 1 - codes.count))
            }
            codes[Int(photo)] = newValue.flatMap { PhotoOrientation.allCases.firstIndex(of: $0) }
                .map { UInt8($0 + 1) } ?? 0
        }
    }

    /// Every photo's in `index`.
    public static func read(from index: LibraryIndex) async throws -> PhotoOrientations {
        try await index.read { try PhotoOrientations($0) }
    }

    /// Every photo's in `reader`'s index.
    init(_ reader: some IndexQueries) throws {
        var orientations = PhotoOrientations()
        try reader.database.cached("SELECT id, width, height FROM photos WHERE width > 0 AND height > 0 ORDER BY id")
            .forEachRow { row in
                orientations[row.int64(at: 0)] = PhotoOrientation(width: row.int(at: 1), height: row.int(at: 2))
            }
        self = orientations
    }

    /// `photo`'s orientation as `codes` keeps it.
    func code(of photo: Int64) -> UInt8 {
        photo >= 0 && photo < codes.count ? codes[Int(photo)] : 0
    }
}
