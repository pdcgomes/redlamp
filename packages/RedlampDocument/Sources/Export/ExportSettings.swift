import Foundation
import RedlampEngineAPI

/// The file formats Redlamp exports, all written by ImageIO.
public enum ExportFormat: String, Codable, Sendable, Hashable, CaseIterable {
    case jpeg, heic, avif, png, tiff

    public static let lossy: [ExportFormat] = [.jpeg, .heic, .avif]
    public static let lossless: [ExportFormat] = [.png, .tiff]

    public var name: String {
        switch self {
        case .jpeg: "JPEG"
        case .heic: "HEIC"
        case .avif: "AVIF"
        case .png: "PNG"
        case .tiff: "TIFF"
        }
    }

    public var fileExtension: String {
        switch self {
        case .jpeg: "jpg"
        case .heic: "heic"
        case .avif: "avif"
        case .png: "png"
        case .tiff: "tif"
        }
    }

    public var typeIdentifier: String {
        switch self {
        case .jpeg: "public.jpeg"
        case .heic: "public.heic"
        case .avif: "public.avif"
        case .png: "public.png"
        case .tiff: "public.tiff"
        }
    }

    public var isLossless: Bool {
        self == .png || self == .tiff
    }

    /// Bits per channel the file can hold. HEIC and AVIF store 10 bits from a 16-bit render.
    public var bitDepths: [Int] {
        switch self {
        case .jpeg: [8]
        case .heic, .avif: [8, 10]
        case .png, .tiff: [8, 16]
        }
    }

    public var defaultBitDepth: Int {
        self == .tiff ? 16 : 8
    }

    /// ImageIO's AVIF encoder fails at quality 1.0, and files stop changing above 0.99.
    var maximumQuality: Double {
        self == .avif ? 0.99 : 1
    }
}

public enum TIFFCompression: String, Codable, Sendable, Hashable, CaseIterable {
    case none, lzw, zip

    public var name: String {
        switch self {
        case .none: "None"
        case .lzw: "LZW"
        case .zip: "ZIP"
        }
    }

    /// The TIFF Compression tag.
    var tag: Int {
        switch self {
        case .none: 1
        case .lzw: 5
        case .zip: 8
        }
    }
}

public enum ExportMetadataPolicy: String, Codable, Sendable, Hashable, CaseIterable {
    case all, allExceptLocation, none

    public var name: String {
        switch self {
        case .all: "All"
        case .allExceptLocation: "All Except Location"
        case .none: "None"
        }
    }
}

public enum ExistingFilePolicy: String, Codable, Sendable, Hashable, CaseIterable {
    case ask, addNumber, overwrite

    public var name: String {
        switch self {
        case .ask: "Ask"
        case .addNumber: "Add a Number"
        case .overwrite: "Overwrite"
        }
    }
}

/// What the exported file is called. Settings never name a photo, so the same rule names
/// every photo it is applied to.
public struct ExportNaming: Codable, Sendable, Hashable {
    public enum Mode: String, Codable, Sendable, Hashable, CaseIterable {
        case original, custom

        public var name: String {
            switch self {
            case .original: "Original Name"
            case .custom: "Custom Name"
            }
        }
    }

    public var mode: Mode = .original
    public var suffix = "-redlamp"
    public var customName = ""

    public init(mode: Mode = .original, suffix: String = "-redlamp", customName: String = "") {
        self.mode = mode
        self.suffix = suffix
        self.customName = customName
    }

    /// The file name without its extension.
    public func baseName(for source: URL) -> String {
        let original = source.deletingPathExtension().lastPathComponent
        switch mode {
        case .original:
            return Self.sanitized(original + suffix) ?? original
        case .custom:
            return Self.sanitized(customName) ?? original
        }
    }

    /// Whether the rule makes a usable name (a custom name needs some text).
    public var isValid: Bool {
        mode == .original || Self.sanitized(customName) != nil
    }

    /// Slashes and colons can't be in a file name, and a leading dot would hide the file.
    static func sanitized(_ name: String) -> String? {
        var cleaned = name.replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: "-")
        cleaned = cleaned.trimmingCharacters(in: .whitespacesAndNewlines)
        while cleaned.hasPrefix(".") {
            cleaned.removeFirst()
        }
        return cleaned.isEmpty ? nil : cleaned
    }
}

/// Everything the Export dialog sets.
public struct ExportSettings: Sendable, Hashable {
    public var format: ExportFormat = .jpeg
    /// 0–100, for the lossy formats.
    public var quality = 90
    public var limitsFileSize = false
    public var fileSizeLimitKB = 500
    public var tiffCompression: TIFFCompression = .zip
    public var bitDepth = 8
    public var colorSpace: OutputColorSpace = .sRGB
    public var sizing = ExportSizing()
    public var metadata: ExportMetadataPolicy = .all
    /// nil exports next to the original.
    public var destinationFolder: URL?
    public var naming = ExportNaming()
    public var existingFiles: ExistingFilePolicy = .ask
    public var revealInFinder = true

    public init() {}

    /// Changes the format, keeping the bit depth if the new format can hold it.
    public mutating func setFormat(_ format: ExportFormat) {
        self.format = format
        if !format.bitDepths.contains(bitDepth) {
            bitDepth = format.defaultBitDepth
        }
    }

    /// The bit depth the file will have.
    public var effectiveBitDepth: Int {
        format.bitDepths.contains(bitDepth) ? bitDepth : format.defaultBitDepth
    }

    /// The render's bits per component: 16 for anything deeper than 8.
    public var bitsPerComponent: Int {
        effectiveBitDepth > 8 ? 16 : 8
    }

    public var appliesFileSizeLimit: Bool {
        limitsFileSize && !format.isLossless
    }

    /// The still to render for a photo of `source` pixels.
    public func stillRequest(recipe: EditRecipe, source: URL, size: PixelSize) -> StillRequest {
        var request = StillRequest(
            recipe: recipe,
            maxLongEdge: sizing.maxLongEdge(for: size),
            colorSpace: colorSpace,
            bitsPerComponent: bitsPerComponent,
            purpose: .export,
        )
        request.source = source
        return request
    }
}

extension ExportSettings: Codable {
    private enum CodingKeys: String, CodingKey {
        case format, quality, limitsFileSize, fileSizeLimitKB, tiffCompression, bitDepth, colorSpace, sizing
        case metadata, destinationFolder, naming, existingFiles, revealInFinder
    }

    /// Missing or unreadable keys (from older or newer versions) take their defaults, so saved
    /// presets survive new settings.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        func value<T: Decodable>(_ key: CodingKeys, _ fallback: T) -> T {
            (try? container.decodeIfPresent(T.self, forKey: key)) ?? fallback
        }
        let defaults = ExportSettings()
        format = value(.format, defaults.format)
        quality = min(max(value(.quality, defaults.quality), 0), 100)
        limitsFileSize = value(.limitsFileSize, defaults.limitsFileSize)
        fileSizeLimitKB = max(1, value(.fileSizeLimitKB, defaults.fileSizeLimitKB))
        tiffCompression = value(.tiffCompression, defaults.tiffCompression)
        bitDepth = value(.bitDepth, defaults.bitDepth)
        colorSpace = value(.colorSpace, defaults.colorSpace)
        sizing = value(.sizing, defaults.sizing)
        metadata = value(.metadata, defaults.metadata)
        destinationFolder = value(.destinationFolder, defaults.destinationFolder)
        naming = value(.naming, defaults.naming)
        existingFiles = value(.existingFiles, defaults.existingFiles)
        revealInFinder = value(.revealInFinder, defaults.revealInFinder)
    }
}
