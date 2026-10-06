import Foundation

/// Photos shown as one (LIB-28): a raw beside its JPEG, a burst, a stack the user made, or frames
/// that look like a focus stack. The top photo stands for the others until the stack is opened.
public struct Stack: Sendable, Hashable {
    public enum Kind: String, Sendable, Hashable, CaseIterable, Codable {
        /// A raw and its JPEG or HEIC, or a JPEG and its HEIC: photos in one folder whose names
        /// differ only in their extension. The raw is on top.
        case pair
        /// Frames from one camera in one folder with one exposure length, each starting at most
        /// `StackFinder.burstGap` after the one before it ended.
        case burst
        /// Frames `StackDetector`'s capture rules take for a focus stack: suggested for merging once
        /// the app has confirmed them from their thumbnails, and never shown as one.
        case focus
        /// Photos the user stacked, from any folders.
        case manual
    }

    public let kind: Kind
    /// The top photo, then the others: a pair's raw, JPEG and HEIC; a focus suggestion's in name
    /// order; the others' by capture time. A raw and its JPEG are one photo in a burst, a
    /// suggestion or a manual stack, which holds the raw.
    public let photos: [Int64]
    /// A manual stack's ID, which each of its photos keeps.
    public let id: UUID?

    public init(kind: Kind, photos: [Int64], id: UUID? = nil) {
        precondition(!photos.isEmpty, "a stack has a photo")
        self.kind = kind
        self.photos = photos
        self.id = id
    }

    public var top: Int64 {
        photos[0]
    }
}
