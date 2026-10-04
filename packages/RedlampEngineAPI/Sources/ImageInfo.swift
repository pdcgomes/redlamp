import Foundation

public struct PixelSize: Codable, Sendable, Hashable {
    public var width: Int
    public var height: Int

    public init(width: Int, height: Int) {
        self.width = width
        self.height = height
    }

    public static let zero = PixelSize(width: 0, height: 0)

    public var longEdge: Int {
        max(width, height)
    }

    public var megapixels: Double {
        Double(width * height) / 1_000_000
    }

    public var aspectRatio: Double {
        height == 0 ? 1 : Double(width) / Double(height)
    }

    /// The largest size with this aspect ratio that fits inside `bounds`, never larger
    /// than `self`.
    public func fitted(within bounds: PixelSize) -> PixelSize {
        guard width > 0, height > 0, bounds.width > 0, bounds.height > 0 else { return .zero }
        let scale = min(Double(bounds.width) / Double(width), Double(bounds.height) / Double(height), 1)
        return PixelSize(
            width: max(1, Int((Double(width) * scale).rounded())),
            height: max(1, Int((Double(height) * scale).rounded())),
        )
    }
}

/// What the engine knows about an opened image.
public struct ImageInfo: Codable, Sendable, Hashable {
    public var url: URL
    /// Size after orientation is applied.
    public var pixelSize: PixelSize
    public var isRaw: Bool
    /// e.g. "Bayer RGGB", "X-Trans", "Linear DNG", "JPEG".
    public var sensorDescription: String
    public var make: String?
    public var model: String?
    public var lens: String?
    public var iso: Double?
    public var exposureTime: Double?
    public var aperture: Double?
    public var focalLength: Double?
    public var captureDate: Date?
    /// The camera's recorded white balance; `nil` for images that are not raw.
    public var asShotWhiteBalance: WhiteBalanceValue?
    /// The look of the camera profile the file embeds (a DNG's LookTable or tone curve), as a
    /// Base Look the engine can render while the photo is open.
    public var embeddedBaseLook: BaseLookReference?
    /// The process version the embedded look needs, when it relies on a stage older edits
    /// don't apply (ProRAW's tone curve on its gain table map, process 5).
    public var embeddedBaseLookProcess: Int?
    /// The lens correction the file carries (DNG opcodes or the maker's tags), applied by
    /// Enable Profile Corrections.
    public var lensCorrection: LensCorrection?
    /// What the raw decode measured, for the camera bench (CAM-14); nil for bitmaps.
    public var diagnostics: DecodeDiagnostics?

    public init(
        url: URL,
        pixelSize: PixelSize,
        isRaw: Bool,
        sensorDescription: String,
        make: String? = nil,
        model: String? = nil,
        lens: String? = nil,
        iso: Double? = nil,
        exposureTime: Double? = nil,
        aperture: Double? = nil,
        focalLength: Double? = nil,
        captureDate: Date? = nil,
        asShotWhiteBalance: WhiteBalanceValue? = nil,
    ) {
        self.url = url
        self.pixelSize = pixelSize
        self.isRaw = isRaw
        self.sensorDescription = sensorDescription
        self.make = make
        self.model = model
        self.lens = lens
        self.iso = iso
        self.exposureTime = exposureTime
        self.aperture = aperture
        self.focalLength = focalLength
        self.captureDate = captureDate
        self.asShotWhiteBalance = asShotWhiteBalance
    }

    public var fileName: String {
        url.lastPathComponent
    }

    public var supportsWhiteBalance: Bool {
        asShotWhiteBalance != nil
    }

    public var cameraName: String? {
        guard let model else { return make }
        guard let make, !model.localizedCaseInsensitiveContains(make) else { return model }
        return "\(make) \(model)"
    }

    /// Lightroom-style capture summary: `ISO 100   35 mm   f/2.8   1/250 s`.
    public var exposureSummary: [String] {
        var parts: [String] = []
        if let iso, iso > 0 {
            parts.append("ISO \(Int(iso.rounded()))")
        }
        if let focalLength, focalLength > 0 {
            parts.append("\(Int(focalLength.rounded())) mm")
        }
        if let aperture, aperture > 0 {
            parts.append(String(format: "ƒ/%.1f", aperture))
        }
        if let exposureTime, exposureTime > 0 {
            if exposureTime >= 1 {
                parts.append(String(format: "%.1f s", exposureTime))
            } else {
                parts.append("1/\(Int((1 / exposureTime).rounded())) s")
            }
        }
        return parts
    }
}
