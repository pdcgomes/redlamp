import Foundation
import RedlampEngineAPI
import RedlampServices

/// Everything but the pixels, as stored in `stack.json`.
struct StackMetadata: Codable {
    var width: Int
    var height: Int
    /// "bitmap", "linear" or a CFA description; `patternColors` holds a mosaic's pattern.
    var source: String
    var patternWidth: Int?
    var patternHeight: Int?
    var patternColors: [UInt8]?
    var asShotMultipliers: [Double]
    var cameraToSRGB: [Double]
    var xyzToCamera: [Double]?
    var orientation: Int
    var baselineExposure: Double
    var noiseA: [Float]?
    var noiseB: [Float]?
    var sensorDescription: String
    var make: String?
    var model: String?
    var lens: String?
    var iso: Double?
    var exposureTime: Double?
    var aperture: Double?
    var focalLength: Double?
    var captureDate: Date?
    var report: FocusStackReport
    var depthWidth: Int
    var depthHeight: Int
    var crop: PixelRect
    var frameWidth: Int
    var frameHeight: Int
    var referencePath: String
    var alignment: StackAlignment

    init(_ stack: MergedStack) {
        let decoded = stack.decoded
        width = decoded.width
        height = decoded.height
        switch decoded.layout {
        case let .balancedCameraHalf(pattern?), let .mosaic(pattern):
            source = pattern.description
            patternWidth = pattern.width
            patternHeight = pattern.height
            patternColors = pattern.colors
        case .balancedCameraHalf(nil), .linearRGB:
            source = "linear"
        case .linearSRGBHalf:
            source = "bitmap"
        }
        let multipliers = decoded.asShotMultipliers
        asShotMultipliers = [multipliers.x, multipliers.y, multipliers.z]
        cameraToSRGB = decoded.cameraToSRGB
        xyzToCamera = decoded.xyzToCamera
        orientation = decoded.orientation
        baselineExposure = decoded.baselineExposure
        if let noise = decoded.noiseProfile {
            noiseA = [noise.a.x, noise.a.y, noise.a.z]
            noiseB = [noise.b.x, noise.b.y, noise.b.z]
        }
        let info = decoded.info
        sensorDescription = info.sensorDescription
        make = info.make
        model = info.model
        lens = info.lens
        iso = info.iso
        exposureTime = info.exposureTime
        aperture = info.aperture
        focalLength = info.focalLength
        captureDate = info.captureDate
        report = stack.report
        depthWidth = stack.depthWidth
        depthHeight = stack.depthHeight
        crop = stack.crop
        frameWidth = stack.frameWidth
        frameHeight = stack.frameHeight
        referencePath = stack.referenceURL.path
        alignment = stack.alignment
    }

    func decoded(samples: [UInt16], url: URL) -> DecodedImage {
        let layout: DecodedImage.Layout = switch source {
        case "bitmap": .linearSRGBHalf
        case "linear": .balancedCameraHalf(nil)
        default: .balancedCameraHalf(patternColors.map {
                CFAPattern(width: patternWidth ?? 2, height: patternHeight ?? 2, colors: $0)
            })
        }
        let pixelSize = orientation == 5 || orientation == 6
            ? PixelSize(width: height, height: width)
            : PixelSize(width: width, height: height)
        let info = ImageInfo(
            url: url, pixelSize: pixelSize, isRaw: source != "bitmap", sensorDescription: sensorDescription,
            make: make, model: model, lens: lens, iso: iso, exposureTime: exposureTime, aperture: aperture,
            focalLength: focalLength, captureDate: captureDate,
        )
        var decoded = DecodedImage(
            width: width, height: height, layout: layout, samples: samples, blackLevels: [0, 0, 0], whiteLevel: 1,
            asShotMultipliers: SIMD3(asShotMultipliers[0], asShotMultipliers[1], asShotMultipliers[2]),
            cameraToSRGB: cameraToSRGB, xyzToCamera: xyzToCamera, orientation: orientation,
            baselineExposure: baselineExposure, info: info,
        )
        if let noiseA, let noiseB {
            decoded.noiseProfile = NoiseModel(
                a: SIMD3(noiseA[0], noiseA[1], noiseA[2]), b: SIMD3(noiseB[0], noiseB[1], noiseB[2]),
            )
        }
        return decoded
    }
}
