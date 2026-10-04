import CoreGraphics
import Foundation

/// A raw file's camera, raw mode and capture settings, as the file states them (CAM-14). Never
/// holds anything that identifies a person: no serial numbers, owner, GPS or capture time.
public struct RawFileIdentity: Codable, Sendable, Hashable {
    public var make: String?
    public var model: String?
    /// LibRaw's normalised names, spelled as its camera list spells them.
    public var normalizedMake: String?
    public var normalizedModel: String?
    public var lens: String?
    /// The camera's firmware, or the software that wrote the file.
    public var software: String?
    /// The file's extension, upper case.
    public var format: String
    /// LibRaw's unpacking routine, such as `sony_arw2_load_raw`: one per compression scheme.
    public var decoder: String?
    public var bitsPerSample: Int?
    /// The DNG version, for DNG files.
    public var dngVersion: Int?
    /// "Bayer RGGB", "X-Trans" or "linear".
    public var sensor: String?
    /// The sensor's full readout, and the image area inside it.
    public var rawSize: PixelSize
    public var imageSize: PixelSize
    public var iso: Double?
    public var exposureTime: Double?
    public var aperture: Double?
    public var focalLength: Double?
    /// LibRaw's orientation code: 0, 3, 5 or 6.
    public var orientation: Int
    /// The camera's white balance multipliers, green 1.
    public var asShotMultipliers: [Double]?
    /// The JPEG previews the file embeds.
    public var previews: [PixelSize]
    /// Why LibRaw wouldn't open the file, when it wouldn't.
    public var refusal: String?

    public init(
        make: String? = nil, model: String? = nil, normalizedMake: String? = nil, normalizedModel: String? = nil,
        lens: String? = nil, software: String? = nil, format: String, decoder: String? = nil,
        bitsPerSample: Int? = nil, dngVersion: Int? = nil, sensor: String? = nil, rawSize: PixelSize = .zero,
        imageSize: PixelSize = .zero, iso: Double? = nil, exposureTime: Double? = nil, aperture: Double? = nil,
        focalLength: Double? = nil, orientation: Int = 0, asShotMultipliers: [Double]? = nil,
        previews: [PixelSize] = [], refusal: String? = nil,
    ) {
        self.make = make
        self.model = model
        self.normalizedMake = normalizedMake
        self.normalizedModel = normalizedModel
        self.lens = lens
        self.software = software
        self.format = format
        self.decoder = decoder
        self.bitsPerSample = bitsPerSample
        self.dngVersion = dngVersion
        self.sensor = sensor
        self.rawSize = rawSize
        self.imageSize = imageSize
        self.iso = iso
        self.exposureTime = exposureTime
        self.aperture = aperture
        self.focalLength = focalLength
        self.orientation = orientation
        self.asShotMultipliers = asShotMultipliers
        self.previews = previews
        self.refusal = refusal
    }

    /// The camera as people know it: LibRaw's normalised names, else the file's own.
    public var camera: String {
        let make = normalizedMake ?? make ?? "Unknown"
        let model = normalizedModel ?? model ?? "camera"
        return model.localizedCaseInsensitiveContains(make) ? model : "\(make) \(model)"
    }
}

/// Lines along each edge of the image area that stay at the black level while the image
/// inside doesn't: a strip the decoder left empty, such as the Sony A1 II's (CAM-13).
public struct DarkEdges: Codable, Sendable, Hashable {
    public var top: Int
    public var bottom: Int
    public var left: Int
    public var right: Int

    public init(top: Int = 0, bottom: Int = 0, left: Int = 0, right: Int = 0) {
        self.top = top
        self.bottom = bottom
        self.left = left
        self.right = right
    }

    public var widest: Int {
        max(top, bottom, left, right)
    }
}

/// What a decode measured beyond what development needs, for the camera bench to judge.
/// Raw units throughout. Nothing in rendering reads these.
public struct DecodeMeasurements: Codable, Sendable, Hashable {
    /// The black level LibRaw states, averaged over the CFA positions.
    public var black: Double
    /// The masked margins' level and noise, where the sensor has margins that look masked.
    public var opticalBlack: Double?
    public var opticalBlackNoise: Double?
    /// The 0.1th percentile of the image's photosites: far below the black level when the
    /// stated black is too high.
    public var darkPercentile: Double?
    /// LibRaw's white level, and where the photosites clip (CAM-02's clip spike).
    public var nominalWhite: Double
    public var white: Double
    /// The share of photosites at the clip point.
    public var clippedShare: Double?
    public var darkEdges: DarkEdges?

    public init(
        black: Double, opticalBlack: Double? = nil, opticalBlackNoise: Double? = nil, darkPercentile: Double? = nil,
        nominalWhite: Double, white: Double, clippedShare: Double? = nil, darkEdges: DarkEdges? = nil,
    ) {
        self.black = black
        self.opticalBlack = opticalBlack
        self.opticalBlackNoise = opticalBlackNoise
        self.darkPercentile = darkPercentile
        self.nominalWhite = nominalWhite
        self.white = white
        self.clippedShare = clippedShare
        self.darkEdges = darkEdges
    }
}

/// A raw decode's identity and measurements, carried in its `ImageInfo`.
public struct DecodeDiagnostics: Codable, Sendable, Hashable {
    public var identity: RawFileIdentity
    public var measurements: DecodeMeasurements

    public init(identity: RawFileIdentity, measurements: DecodeMeasurements) {
        self.identity = identity
        self.measurements = measurements
    }
}

/// Reads what a raw file says about itself without developing it, for the camera bench.
public protocol RawFileInspecting: Sendable {
    /// The file's camera, raw mode and capture settings, without unpacking its sensor data. A
    /// file LibRaw refuses still gets what its EXIF says, with the refusal; nil for files
    /// that aren't raw.
    func identify(_ url: URL) -> RawFileIdentity?

    /// The largest JPEG the file embeds, which is the camera's own rendering, upright and at
    /// most `maxLongEdge` on its long edge.
    func cameraPreview(of url: URL, maxLongEdge: Int) -> CGImage?
}
