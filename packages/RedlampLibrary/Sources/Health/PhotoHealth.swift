import Foundation

/// What indexing found wrong with a photo's file, or has yet to read to know (LIB-40), from its one
/// read of the file's head and the end read some formats take. The index keeps it, in
/// `photo_health`, for the photos with something to say.
public struct PhotoHealth: Sendable, Hashable {
    public enum Damage: Sendable, Hashable {
        /// Reading it failed, for a reason other than its being gone or its volume away: what the
        /// reader said.
        case unreadable(String)
        case empty
        /// Its first bytes are no image format's, though its extension's formats have signatures.
        case unrecognised
        /// It ends before its data does: by `missing` bytes, or by an amount its format doesn't say.
        case endsEarly(missing: Int64?)

        /// Whether the reader was refused: permission denied, or an operation macOS doesn't permit
        /// Redlamp. The file may well be whole, so nothing is proposed for it.
        public var isForbidden: Bool {
            guard case let .unreadable(reason) = self else { return false }
            return Self.forbidden.contains(reason)
        }

        private static let forbidden: Set<String> = [
            String(cString: strerror(EACCES)), String(cString: strerror(EPERM)),
        ]
    }

    /// The file's size and modification date when it was read: the health stands for its photo while
    /// the photo's row has them.
    public var size: Int64
    public var modified: Date
    public var format: PhotoFormat
    public var damage: Damage?
    /// Its end is still to be read, in the background lane.
    public var endUnread: Bool
    /// The extension its format takes, in small letters, when its name's doesn't fit the format.
    public var proposedExtension: String?

    public init(
        size: Int64, modified: Date, format: PhotoFormat = .unknown, damage: Damage? = nil, endUnread: Bool = false,
        proposedExtension: String? = nil,
    ) {
        self.size = size
        self.modified = modified
        self.format = format
        self.damage = damage
        self.endUnread = endUnread
        self.proposedExtension = proposedExtension
    }

    /// Whether the index keeps it for a photo named `name`: there's damage, an end to read, or a
    /// format the name doesn't fit.
    public func isWorthKeeping(forName name: String) -> Bool {
        damage != nil || endUnread || !format.fits(name: name)
    }

    /// `damage`'s code in the `damage` column: 0 for none.
    var damageCode: Int {
        switch damage {
        case nil: 0
        case .unreadable: 1
        case .empty: 2
        case .unrecognised: 3
        case .endsEarly: 4
        }
    }

    static func damage(code: Int, missing: Int64?, reason: String?) -> Damage? {
        switch code {
        case 1: .unreadable(reason ?? "")
        case 2: .empty
        case 3: .unrecognised
        case 4: .endsEarly(missing: missing)
        default: nil
        }
    }
}

extension PhotoHealth.Damage: CustomStringConvertible {
    /// The reason in words: "can't be read: Input/output error", "empty", "ends 12.4 MB before its
    /// data does".
    public var description: String {
        switch self {
        case let .unreadable(reason): reason.isEmpty ? "can't be read" : "can't be read: \(reason)"
        case .empty: "empty"
        case .unrecognised: "doesn't start as any image does"
        case .endsEarly(missing: nil): "ends before its data does"
        case let .endsEarly(missing?): "ends \(Self.bytes(missing)) before its data does"
        }
    }

    /// `12.4 MB`, `3 KB`, `512 bytes`, whatever the locale.
    static func bytes(_ count: Int64) -> String {
        if count >= 1_000_000 {
            return String(format: "%.1f MB", locale: Locale(identifier: "en_US"), Double(count) / 1_000_000)
        }
        if count >= 1000 {
            return "\(count / 1000) KB"
        }
        return count == 1 ? "1 byte" : "\(count) bytes"
    }
}

extension PhotoHealth {
    /// The reader's words for an error reading a file: the POSIX error's own (`Input/output error`), or
    /// the error's description.
    static func reason(for error: any Error) -> String {
        if let error = error as? POSIXError {
            return String(cString: strerror(error.code.rawValue))
        }
        let error = error as NSError
        if error.domain == NSPOSIXErrorDomain {
            return String(cString: strerror(Int32(error.code)))
        }
        if let underlying = error.userInfo[NSUnderlyingErrorKey] as? NSError {
            return reason(for: underlying)
        }
        if error.domain == NSCocoaErrorDomain, error.code == CocoaError.fileReadNoPermission.rawValue {
            return String(cString: strerror(EACCES))
        }
        return error.localizedDescription
    }
}
