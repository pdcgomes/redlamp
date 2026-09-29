import Foundation
import Metal
import RedlampColor
import RedlampEngineAPI
import RedlampKernels
import RedlampServices
import simd

/// GPU-resident state for the open image: the demosaiced, white-balanced camera RGB with
/// a full mip pyramid, plus the calibration needed to develop it. Immutable once built.
final class ImageSession: @unchecked Sendable {
    let info: ImageInfo
    let isRaw: Bool
    /// Camera RGB balanced by the as-shot multipliers, mipmapped, not yet oriented.
    let pyramid: any MTLTexture
    let orientation: Int
    let orientedSize: PixelSize
    let cameraToWorking: simd_float3x3
    let colorModel: CameraColorModel?
    /// As-shot multipliers, green = 1.
    let asShotMultipliers: SIMD3<Double>
    /// The as-shot multipliers the pyramid was balanced with (smallest channel = 1).
    let balanceMultipliers: SIMD3<Double>
    let baselineExposure: Double
    /// A small CPU copy of the pyramid (camera RGB) for white-balance and tone analysis.
    let analysis: AnalysisImage

    init(
        info: ImageInfo,
        decoded: DecodedImage,
        pyramid: any MTLTexture,
        colorModel: CameraColorModel?,
        balanceMultipliers: SIMD3<Double>,
        analysis: AnalysisImage,
    ) {
        self.info = info
        isRaw = decoded.isRaw
        self.pyramid = pyramid
        orientation = decoded.orientation
        orientedSize = decoded.orientedSize
        let cameraToSRGB = simd_double3x3(rowMajor: decoded.cameraToSRGB)
        cameraToWorking = (ColorMatrices.sRGBToRec2020 * cameraToSRGB).floatMatrix
        self.colorModel = colorModel
        asShotMultipliers = decoded.asShotMultipliers
        self.balanceMultipliers = balanceMultipliers
        baselineExposure = decoded.baselineExposure
        self.analysis = analysis
    }

    /// Per-channel gains that move the as-shot balance to the requested white balance.
    func whiteBalanceRatio(for recipe: EditRecipe) -> SIMD3<Double> {
        guard isRaw, recipe.whiteBalanceMode != .asShot, let colorModel else { return SIMD3(1, 1, 1) }
        let target = colorModel.multipliers(for: WhiteBalanceValue(
            temperature: recipe[.temperature],
            tint: recipe[.tint],
        ))
        return target / asShotMultipliers
    }
}

/// A downsampled CPU copy of the pyramid in camera RGB (balanced by the as-shot
/// multipliers, like the pyramid itself).
struct AnalysisImage: Sendable {
    let width: Int
    let height: Int
    let pixels: [SIMD3<Float>]

    func pixel(x: Int, y: Int) -> SIMD3<Float> {
        pixels[min(max(y, 0), height - 1) * width + min(max(x, 0), width - 1)]
    }
}

/// Maps oriented, normalised coordinates to source coordinates (mirrors `orient` in Develop.metal).
func sourceCoordinate(_ point: SIMD2<Double>, orientation: Int) -> SIMD2<Double> {
    switch orientation {
    case 3: SIMD2(1 - point.x, 1 - point.y)
    case 5: SIMD2(1 - point.y, point.x)
    case 6: SIMD2(point.y, 1 - point.x)
    default: point
    }
}
