import Foundation
import RedlampEngineAPI

/// The file formats Redlamp exports: JPEG XL with libjxl (`JPEGXLEncoder`), since ImageIO reads it
/// but doesn't write it, and the rest with ImageIO.
public enum ExportFormat: String, Codable, Sendable, Hashable, CaseIterable {
    case jpeg, heic, avif, jxl, png, tiff, jxlLossless

    public static let lossy: [ExportFormat] = [.jpeg, .heic, .avif, .jxl]
    public static let lossless: [ExportFormat] = [.png, .tiff, .jxlLossless]

    public var name: String {
        switch self {
        case .jpeg: "JPEG"
        case .heic: "HEIC"
        case .avif: "AVIF"
        case .jxl, .jxlLossless: "JPEG XL"
        case .png: "PNG"
        case .tiff: "TIFF"
        }
    }

    public var fileExtension: String {
        switch self {
        case .jpeg: "jpg"
        case .heic: "heic"
        case .avif: "avif"
        case .jxl, .jxlLossless: "jxl"
        case .png: "png"
        case .tiff: "tif"
        }
    }

    public var typeIdentifier: String {
        switch self {
        case .jpeg: "public.jpeg"
        case .heic: "public.heic"
        case .avif: "public.avif"
        case .jxl, .jxlLossless: "public.jpeg-xl"
        case .png: "public.png"
        case .tiff: "public.tiff"
        }
    }

    public var isLossless: Bool {
        self == .png || self == .tiff || self == .jxlLossless
    }

    var isJPEGXL: Bool {
        self == .jxl || self == .jxlLossless
    }

    /// Bits per channel the file can hold. HEIC and AVIF store 10 bits from a 16-bit render.
    public var bitDepths: [Int] {
        switch self {
        case .jpeg: [8]
        case .heic, .avif: [8, 10]
        case .jxl, .png, .tiff, .jxlLossless: [8, 16]
        }
    }

    public var defaultBitDepth: Int {
        self == .tiff ? 16 : 8
    }

    /// ImageIO's AVIF encoder fails at quality 1.0, and files stop changing above 0.99. libjxl
    /// encodes quality 1.0 losslessly.
    var maximumQuality: Double {
        self == .avif || self == .jxl ? 0.99 : 1
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
    case ask, addNumber, overwrite, skip

    public var name: String {
        switch self {
        case .ask: "Ask"
        case .addNumber: "Add a Number"
        case .overwrite: "Overwrite"
        case .skip: "Skip"
        }
    }
}

/// What the exported files are called: a naming template in the grammar renaming and importing
/// share (LIB-25), which RedlampLibrary reads (`ExportNames`), the texts it asks for, and the
/// number its sequences start at. Settings never name a photo, so the same rule names every
/// photo it is applied to.
public struct ExportNaming: Sendable, Hashable {
    /// The original name with Redlamp's suffix, as exports were named before templates.
    public static let standard = "{name}-redlamp"

    public var template: String
    /// `{text}` and `{text:shoot}`, by their names ("" and "shoot").
    public var texts: [String: String]
    public var sequenceStart: Int

    public init(template: String = ExportNaming.standard, texts: [String: String] = [:], sequenceStart: Int = 1) {
        self.template = template
        self.texts = texts
        self.sequenceStart = sequenceStart
    }

    /// The original name followed by `suffix`, written as text.
    public static func original(suffix: String) -> ExportNaming {
        ExportNaming(template: "{name}" + escaped(suffix))
    }

    /// `name` for every photo, written as text; numbers tell the photos of a batch apart.
    public static func custom(_ name: String) -> ExportNaming {
        ExportNaming(template: escaped(name))
    }

    /// A brace in a template's text is doubled.
    static func escaped(_ text: String) -> String {
        text.replacingOccurrences(of: "{", with: "{{").replacingOccurrences(of: "}", with: "}}")
    }
}

extension ExportNaming: Codable {
    private enum CodingKeys: String, CodingKey {
        case template, texts, sequenceStart
        /// Before templates: the original name with `suffix`, or `customName` (`mode` "custom").
        case mode, suffix, customName
    }

    /// Settings saved before templates name files as they did then.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        func value<T: Decodable>(_ key: CodingKeys) -> T? {
            (try? container.decodeIfPresent(T.self, forKey: key)) ?? nil
        }
        if let template: String = value(.template) {
            self.init(template: template)
        } else if value(.mode) == "custom", let name: String = value(.customName),
                  !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            self = .custom(name)
        } else {
            self = .original(suffix: value(.suffix) ?? "-redlamp")
        }
        texts = value(.texts) ?? [:]
        sequenceStart = value(.sequenceStart) ?? 1
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(template, forKey: .template)
        if !texts.isEmpty {
            try container.encode(texts, forKey: .texts)
        }
        try container.encode(sequenceStart, forKey: .sequenceStart)
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
    /// Sharpening for the screen, applied when the export is reduced (EDT-28).
    public var sharpening: OutputSharpening = .off
    /// The border each photo is exported with (EDT-35).
    public var border: ExportBorder = .asEdited
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

    /// The size the sizing applies to for a photo of `size` pixels with `recipe`: the bordered
    /// canvas when the export draws a border, so a long edge is the file's.
    public func sizingSource(recipe: EditRecipe, size: PixelSize) -> PixelSize {
        let exported = border.apply(to: recipe)
        let layout = exported.borderLayout(imageSize: size)
        return layout.hasBorder ? layout.canvasSize : size
    }

    /// The still to render for a photo of `source` pixels, with the export's border.
    public func stillRequest(recipe: EditRecipe, source: URL, size: PixelSize) -> StillRequest {
        var request = StillRequest(
            recipe: border.apply(to: recipe),
            maxLongEdge: sizing.maxLongEdge(for: sizingSource(recipe: recipe, size: size)),
            colorSpace: colorSpace,
            bitsPerComponent: bitsPerComponent,
            purpose: .export,
        )
        request.outputSharpening = sharpening
        request.source = source
        return request
    }
}

extension ExportSettings: Codable {
    private enum CodingKeys: String, CodingKey {
        case format, quality, limitsFileSize, fileSizeLimitKB, tiffCompression, bitDepth, colorSpace, sizing
        case sharpening, border, metadata, destinationFolder, naming, existingFiles, revealInFinder
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
        sharpening = value(.sharpening, defaults.sharpening)
        border = value(.border, defaults.border)
        metadata = value(.metadata, defaults.metadata)
        destinationFolder = value(.destinationFolder, defaults.destinationFolder)
        naming = value(.naming, defaults.naming)
        existingFiles = value(.existingFiles, defaults.existingFiles)
        revealInFinder = value(.revealInFinder, defaults.revealInFinder)
    }
}
