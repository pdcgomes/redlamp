import Foundation

public enum SupportedFormats {
    public static let rawExtensions: Set<String> = [
        "3fr", "arw", "cr2", "cr3", "crw", "dcr", "dng", "erf", "fff", "iiq", "kdc", "mef",
        "mos", "mrw", "nef", "nrw", "orf", "pef", "raf", "raw", "rw2", "rwl", "sr2", "srf", "srw",
    ]

    public static let bitmapExtensions: Set<String> = ["jpg", "jpeg", "heic", "heif", "png", "tif", "tiff"]

    public static func isRaw(_ url: URL) -> Bool {
        rawExtensions.contains(url.pathExtension.lowercased())
    }

    /// A focus stack document (`FocusStackDocument`).
    public static func isStack(_ url: URL) -> Bool {
        url.pathExtension.lowercased() == FocusStackDocument.fileExtension
    }

    public static func isSupported(_ url: URL) -> Bool {
        isSupported(extension: url.pathExtension.lowercased())
    }

    /// `ext` lowercased.
    public static func isSupported(extension ext: String) -> Bool {
        rawExtensions.contains(ext) || bitmapExtensions.contains(ext) || ext == FocusStackDocument.fileExtension
    }
}
