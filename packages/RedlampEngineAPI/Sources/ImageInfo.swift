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
    /// e.g. "Bayer RGGB", "X-Trans", "Linear DNG", "Small raw", "JPEG".
    public var sensorDescription: String
    public var make: String?
    public var model: String?
    public var lens: String?
    public var iso: Double?
    public var exposureTime: Double?
    public var aperture: Double?
    public var focalLength: Double?
    /// The frame's crop factor: 35 mm film's diagonal over the frame's (1 for full frame, about 1.5
    /// for APS-C, 2 for Four Thirds), following a crop mode; nil where the file doesn't tell. A lens
    /// profile made on another body is scaled by it (LNS-14).
    public var cropFactor: Double?
    /// The maker's number for the lens where its maker note gives one (Nikon's LensIDNumber), which
    /// matches a lens profile when the file doesn't name the lens (LNS-14).
    public var lensID: Int?
    /// The lens's focal lengths, shortest and longest, in millimetres, where the maker note gives them.
    public var lensFocalRange: ClosedRange<Double>?
    /// LibRaw's canonical name for the camera, as its camera list spells it: one name for a body sold
    /// under several (Canon's EOS 600D, Rebel T3i and Kiss X5). Nil where LibRaw gives none.
    public var canonicalMake: String?
    public var canonicalModel: String?
    public var captureDate: Date?
    /// The camera's recorded white balance; `nil` for images that are not raw.
    public var asShotWhiteBalance: WhiteBalanceValue?
    /// The look of the camera profile the file embeds (a DNG's LookTable or tone curve), as a
    /// Base Look the engine can render while the photo is open.
    public var embeddedBaseLook: BaseLookReference?
    /// The process version the embedded look needs, when it relies on a stage older edits
    /// don't apply (ProRAW's tone curve on its gain table map, process 5).
    public var embeddedBaseLookProcess: Int?
    /// The lens correction the file carries (DNG opcodes or the maker's tags), else the user's lens
    /// profile for the photo's lens, applied by Enable Profile Corrections from its process version.
    public var lensCorrection: LensCorrection?
    /// A raw's BaselineExposure (0 when it states none), which an estimated exposure anchor
    /// carries when it renders (`ExposureAnchor.stops(baseline:)`); nil for bitmaps.
    public var baselineExposure: Double?
    /// The stops the camera underexposed the raw by for a setting that brightens its own JPEG back
    /// by as much: Fujifilm's DR200 and DR400, one and two stops (CAM-35). Added to every look's
    /// exposure from process 19; nil where the file states none.
    public var exposureShift: Double?
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
        Self.cameraName(make: make, model: model)
    }

    /// A camera's name from the make and model its files state: the model, after the make
    /// unless the model already names it.
    public static func cameraName(make: String?, model: String?) -> String? {
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
