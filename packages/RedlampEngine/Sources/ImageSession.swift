import Foundation
import Metal
import RedlampColor
import RedlampEngineAPI
import RedlampKernels
import RedlampMasking
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
    /// Balanced camera RGB to linear Rec. 2020 at the as-shot white balance, by the calibration its
    /// raw revision takes the photo with.
    let cameraToWorking: simd_float3x3
    /// DNG calibrations, when the file has them, and the as-shot colour temperature they imply.
    let dngColor: DNGColorCalibration?
    let asShotTemperature: Double
    let colorModel: CameraColorModel?
    /// The first raw revision that develops with the camera's colour matrix
    /// (`DecodedImage.colorMatrixRevision`). `colorModel` is the photo's, for its As Shot white balance,
    /// Auto and the picker, but only edits from this revision render with it.
    let colorMatrixRevision: RawRevision
    /// As-shot multipliers, green = 1.
    let asShotMultipliers: SIMD3<Double>
    /// The as-shot multipliers the pyramid was balanced with (smallest channel = 1).
    let balanceMultipliers: SIMD3<Double>
    let baselineExposure: Double
    /// A small CPU copy of the pyramid (camera RGB) for white-balance and tone analysis.
    let analysis: AnalysisImage
    /// Sensor noise in pyramid units (after the balance multipliers).
    let noise: NoiseModel
    let sensor: SensorKind
    /// Hot photosites replaced before demosaicing.
    let repairedPixels: Int
    /// Dehaze's airlight and haze map (see `Haze`), in the pyramid's camera RGB.
    let airlight: SIMD3<Float>
    let hazeMap: any MTLTexture
    /// The refined haze map (process 8): a guided filter's coefficients (see `Haze.Refined`).
    let refinedHaze: any MTLTexture
    /// The added-haze map (process 18): a guided filter's coefficients (see `Haze.added`).
    let addedHaze: any MTLTexture
    /// Edge-aware Highlights and Shadows' base: a guided filter's coefficients (see `ToneBase`).
    let toneBase: any MTLTexture
    /// Edge-aware Clarity's base: a guided filter's coefficients (see `ClarityBase`).
    let clarityBase: any MTLTexture
    /// The light halation and bloom spread (see `Glow`), mipmapped.
    let glowSource: any MTLTexture
    /// The same, boosting only small lights (process 3).
    let glowLights: any MTLTexture
    /// The gain maps' gain per camera channel, which scaled the sensor noise (see `NoiseGain`).
    let noiseGain: any MTLTexture
    /// The DNG's embedded camera profile, and its HueSatMaps on the GPU when it has some.
    let dngProfile: DNGProfile?
    let hueSatMaps: HueSatMaps?
    /// The profile's ProfileGainTableMap on the GPU (process 5).
    let gainTableMap: GainTableMapTexture?
    /// The profile's look baked into a Base Look (`EmbeddedLook`).
    let embeddedLook: BaseLookDefinition?
    /// The mattes the file carries, found while the session was built so they're never probed on the main thread.
    let embeddedMattes: Set<EmbeddedMatte>
    /// The user's lens profiles as the photo's edits can name them (LNS-15); nil for a photo that
    /// isn't raw, or without the user's profiles.
    let lensProfiles: LensProfileResolver?
    /// The raw revision its pyramid was built at (`RawRevision`).
    let rawRevision: RawRevision
    /// The raw revisions whose stages build the photo's pyramid differently from the revision
    /// before (`SessionBuilder.pyramid`); empty when every revision builds the same one.
    let rawChanges: Set<RawRevision>
    /// What another raw revision builds a different pyramid from, kept for the photo's edits at
    /// that revision (`RevisionStage`); nil when every revision builds the same one.
    let rawSource: RawSource?
    private let chromaticAberration: LateralChromaticAberration.Cache
    /// The session this one copies with Heal and Clone spots in its pyramid (see `RetouchStage`).
    private let retouchedFrom: ImageSession?
    /// The session this one builds again at an older raw revision (see `RevisionStage`).
    private let variantOf: ImageSession?

    /// The decoded image, and the noise model the photo's pyramid was built with.
    struct RawSource {
        let decoded: DecodedImage
        let noise: NoiseModel
    }

    /// The photo as opened, without spots: at an older raw revision, its variant.
    var original: ImageSession {
        retouchedFrom ?? self
    }

    /// The photo as opened at the current raw revision: the same for its variants and their
    /// retouched copies.
    var photo: ImageSession {
        original.variantOf ?? original
    }

    /// Whether an edit at `revision` renders from this session's pixels: no revision between the
    /// two changes the photo.
    func serves(_ revision: RawRevision) -> Bool {
        let original = original
        return original.builtRevision(for: revision) == original.builtRevision(for: original.rawRevision)
    }

    /// The earliest revision that builds the pyramid `revision` builds for the photo.
    private func builtRevision(for revision: RawRevision) -> RawRevision {
        rawChanges.filter { $0 <= revision }.max() ?? .first
    }

    init(
        info: ImageInfo,
        decoded: DecodedImage,
        pyramid: any MTLTexture,
        rawRevision: RawRevision,
        rawChanges: Set<RawRevision>,
        rawSource: RawSource?,
        colorModel: CameraColorModel?,
        balanceMultipliers: SIMD3<Double>,
        analysis: AnalysisImage,
        noise: NoiseModel,
        repairedPixels: Int,
        airlight: SIMD3<Float>,
        hazeMap: any MTLTexture,
        refinedHaze: any MTLTexture,
        addedHaze: any MTLTexture,
        toneBase: any MTLTexture,
        clarityBase: any MTLTexture,
        glowSource: any MTLTexture,
        glowLights: any MTLTexture,
        noiseGain: any MTLTexture,
        hueSatMaps: HueSatMaps? = nil,
        gainTableMap: GainTableMapTexture? = nil,
        embeddedLook: BaseLookDefinition? = nil,
        embeddedMattes: Set<EmbeddedMatte>,
        lensProfiles: LensProfileResolver? = nil,
    ) {
        self.embeddedMattes = embeddedMattes
        self.lensProfiles = lensProfiles
        self.rawRevision = rawRevision
        self.rawChanges = rawChanges
        self.rawSource = rawSource
        self.noiseGain = noiseGain
        dngProfile = decoded.isRaw ? decoded.dngProfile : nil
        self.hueSatMaps = decoded.isRaw ? hueSatMaps : nil
        self.gainTableMap = decoded.isRaw ? gainTableMap : nil
        self.embeddedLook = decoded.isRaw ? embeddedLook : nil
        self.repairedPixels = repairedPixels
        self.airlight = airlight
        self.hazeMap = hazeMap
        self.refinedHaze = refinedHaze
        self.addedHaze = addedHaze
        self.toneBase = toneBase
        self.clarityBase = clarityBase
        self.glowSource = glowSource
        self.glowLights = glowLights
        self.noise = noise.scaled(by: SIMD3<Float>(balanceMultipliers))
        sensor = SensorKind(decoded.layout)
        self.info = info
        isRaw = decoded.isRaw
        self.pyramid = pyramid
        orientation = decoded.orientation
        orientedSize = decoded.orientedSize
        let calibration = ImageSession.calibration(decoded)
        dngColor = calibration.dngColor
        asShotTemperature = calibration.asShotTemperature
        cameraToWorking = calibration.cameraToWorking
        self.colorModel = colorModel
        colorMatrixRevision = decoded.colorMatrixRevision
        asShotMultipliers = decoded.asShotMultipliers
        self.balanceMultipliers = balanceMultipliers
        baselineExposure = decoded.baselineExposure
        self.analysis = analysis
        chromaticAberration = LateralChromaticAberration.Cache()
        retouchedFrom = nil
        variantOf = nil
    }

    /// `photo` built again at another raw revision from `decoded`, the photo as that revision takes
    /// it: `pyramid`, and the maps made from it, in place of its own. The calibration is `decoded`'s,
    /// which differs from the photo's only for a camera whose colour matrix came at a revision
    /// between them (`RawRevision.fifth`); the colour model and the embedded profile are the
    /// photo's; what is measured from its pixels (the airlight, the chromatic aberration) is its
    /// own, and so is `noise`, which differs from the photo's only for a raw the camera balanced
    /// (`RawRevision.fourth`) or a small raw whose white level was measured (`RawRevision.sixth`).
    init(
        variantOf photo: ImageSession, decoded: DecodedImage, revision: RawRevision, noise: NoiseModel,
        pyramid: any MTLTexture, maps: ImageMaps,
    ) {
        info = photo.info
        isRaw = photo.isRaw
        self.pyramid = pyramid
        orientation = photo.orientation
        orientedSize = photo.orientedSize
        let calibration = ImageSession.calibration(decoded)
        cameraToWorking = calibration.cameraToWorking
        dngColor = calibration.dngColor
        asShotTemperature = calibration.asShotTemperature
        colorModel = photo.colorModel
        colorMatrixRevision = photo.colorMatrixRevision
        asShotMultipliers = photo.asShotMultipliers
        balanceMultipliers = photo.balanceMultipliers
        baselineExposure = photo.baselineExposure
        analysis = maps.analysis
        self.noise = noise.scaled(by: SIMD3<Float>(photo.balanceMultipliers))
        sensor = photo.sensor
        repairedPixels = photo.repairedPixels
        airlight = maps.airlight
        hazeMap = maps.hazeMap
        refinedHaze = maps.refinedHaze
        addedHaze = maps.addedHaze
        toneBase = maps.toneBase
        clarityBase = maps.clarityBase
        glowSource = maps.glowSource
        glowLights = maps.glowLights
        noiseGain = photo.noiseGain
        dngProfile = photo.dngProfile
        hueSatMaps = photo.hueSatMaps
        gainTableMap = photo.gainTableMap
        embeddedLook = photo.embeddedLook
        embeddedMattes = photo.embeddedMattes
        lensProfiles = photo.lensProfiles
        rawRevision = revision
        rawChanges = photo.rawChanges
        rawSource = nil
        chromaticAberration = LateralChromaticAberration.Cache()
        retouchedFrom = nil
        variantOf = photo
    }

    /// `session` with `pyramid` in place of its own, and `maps` made from it in place of the
    /// photo's (without them, the photo's: what a spot replaced lives on in them). The airlight,
    /// the noise model and the calibration are the photo's.
    init(retouching session: ImageSession, pyramid: any MTLTexture, maps: ImageMaps? = nil) {
        let original = session.original
        let maps = maps ?? original.maps
        info = original.info
        isRaw = original.isRaw
        self.pyramid = pyramid
        orientation = original.orientation
        orientedSize = original.orientedSize
        cameraToWorking = original.cameraToWorking
        dngColor = original.dngColor
        asShotTemperature = original.asShotTemperature
        colorModel = original.colorModel
        colorMatrixRevision = original.colorMatrixRevision
        asShotMultipliers = original.asShotMultipliers
        balanceMultipliers = original.balanceMultipliers
        baselineExposure = original.baselineExposure
        analysis = maps.analysis
        noise = original.noise
        sensor = original.sensor
        repairedPixels = original.repairedPixels
        airlight = original.airlight
        hazeMap = maps.hazeMap
        refinedHaze = maps.refinedHaze
        addedHaze = maps.addedHaze
        toneBase = maps.toneBase
        clarityBase = maps.clarityBase
        glowSource = maps.glowSource
        glowLights = maps.glowLights
        noiseGain = original.noiseGain
        dngProfile = original.dngProfile
        hueSatMaps = original.hueSatMaps
        gainTableMap = original.gainTableMap
        embeddedLook = original.embeddedLook
        embeddedMattes = original.embeddedMattes
        lensProfiles = original.lensProfiles
        rawRevision = original.rawRevision
        rawChanges = original.rawChanges
        rawSource = nil
        chromaticAberration = original.chromaticAberration
        retouchedFrom = original
        variantOf = nil
    }

    /// The lens correction `recipe` renders with, before its switch and amounts: the profile it
    /// names where that's on this Mac and fits the photo (LNS-15), else the photo's own. Under
    /// Default and Auto a correction the file carries comes first, as it does without a name.
    func lensCorrection(for recipe: EditRecipe) -> LensCorrection? {
        guard let choice = recipe.lensProfileChoice, choice.namesProfile, let lensProfiles,
              choice.setup == .custom || info.lensCorrection.map({ $0.source == .profile }) != false,
              let named = lensProfiles.correction(for: choice)
        else { return info.lensCorrection }
        return named
    }

    /// The maps made from its pixels.
    var maps: ImageMaps {
        ImageMaps(
            analysis: analysis, airlight: airlight, hazeMap: hazeMap, refinedHaze: refinedHaze, addedHaze: addedHaze,
            toneBase: toneBase, clarityBase: clarityBase, glowSource: glowSource, glowLights: glowLights,
        )
    }

    /// What the session holds: each of its textures once, its analysis copy and its raw source.
    var allocatedBytes: Int {
        var textures: [any MTLTexture] = [
            pyramid, hazeMap, refinedHaze, addedHaze, toneBase, clarityBase, glowSource, glowLights, noiseGain,
        ]
        textures += [hueSatMaps?.cool, hueSatMaps?.warm, gainTableMap?.texture].compactMap(\.self)
        var seen = Set<ObjectIdentifier>()
        return textures.filter { seen.insert(ObjectIdentifier($0)).inserted }.map(\.allocatedSize).reduce(0, +)
            + analysis.pixels.withUnsafeBytes(\.count) + (rawSource?.decoded.samples.withUnsafeBytes(\.count) ?? 0)
    }

    /// The stops added to Exposure: a DNG's BaselineExposure or, under Redlamp Reproduction, the
    /// edit's anchor (the typical one when it has none). A bitmap has neither. From process 16
    /// every look anchors a raw (CAM-29): Redlamp Reproduction at the anchor, every other look at
    /// its distance from the typical anchor plus `ExposureAnchor.lookStops`, with the photo's
    /// estimate when the edit has no anchor. Redlamp Reproduction's Amount mixes the two as it
    /// mixes Redlamp Color's curve in, so that Amount 0 renders as Redlamp Color. From process 19
    /// the stops the camera underexposed the photo by for its D-Range are added (CAM-35).
    func baseExposure(for recipe: EditRecipe) -> Double {
        guard recipe.processVersion >= 16 else {
            guard recipe.baseLook.isReproduction else { return baselineExposure }
            return isRaw ? recipe.exposureAnchor?.stops ?? ExposureAnchor.typicalStops : 0
        }
        guard isRaw else { return 0 }
        let anchor = recipe.exposureAnchor ?? ExposureAnchorTable.bundled.anchor(for: info) ?? .typical(for: nil)
        let shift = recipe.processVersion >= 19 ? info.exposureShift ?? 0 : 0
        let stops = anchor.stops(baseline: baselineExposure) + shift
        let lift = ExposureAnchor.typicalStops - ExposureAnchor.lookStops
        guard recipe.baseLook.isReproduction else { return stops - lift }
        return stops - (1 - min(max(recipe.baseLook.amount / 100, 0), 1)) * lift
    }

    /// Per-channel gains that move the as-shot balance to the requested white balance. An edit made
    /// before its camera had a colour matrix keeps the as-shot balance, as it rendered without one.
    func whiteBalanceRatio(for recipe: EditRecipe) -> SIMD3<Double> {
        guard isRaw, recipe.whiteBalanceMode != .asShot, recipe.rawRevision >= colorMatrixRevision, let colorModel
        else { return SIMD3(1, 1, 1) }
        let target = colorModel.multipliers(for: WhiteBalanceValue(
            temperature: recipe[.temperature],
            tint: recipe[.tint],
        ))
        return target / asShotMultipliers
    }

    /// What `decoded` develops with: its DNG calibrations, when the file has them, the as-shot colour
    /// temperature they imply, and balanced camera RGB to linear Rec. 2020 at the as-shot balance.
    private static func calibration(
        _ decoded: DecodedImage,
    ) -> (dngColor: DNGColorCalibration?, asShotTemperature: Double, cameraToWorking: simd_float3x3) {
        guard decoded.isRaw, let dngColor = decoded.dngColor else {
            let cameraToSRGB = simd_double3x3(rowMajor: decoded.cameraToSRGB)
            return (nil, 6504, (ColorMatrices.sRGBToRec2020 * cameraToSRGB).floatMatrix)
        }
        let neutral = 1 / decoded.asShotMultipliers
        let temperature = dngColor.temperature(ofNeutral: neutral / neutral.y)
        return (dngColor, temperature, dngColor.cameraToWorking(temperature: temperature))
    }

    /// Balanced camera RGB to linear Rec. 2020 for the recipe's white balance: DNG calibrations
    /// are interpolated by its colour temperature; other files have one matrix.
    func cameraToWorking(for recipe: EditRecipe) -> simd_float3x3 {
        guard let dngColor, recipe.whiteBalanceMode != .asShot else { return cameraToWorking }
        return dngColor.cameraToWorking(temperature: recipe[.temperature])
    }

    /// The photo's lateral chromatic aberration as measured from its edges, the first time an
    /// edit asks for it (Remove Chromatic Aberration without a profile that corrects it).
    func measuredChromaticAberration() -> LensCorrection? {
        guard isRaw else { return nil }
        return chromaticAberration.value { LateralChromaticAberration.estimate(self) }
    }

    /// How much of the coolest HueSatMap to use, interpolated as the matrices are.
    func hueSatWeight(for recipe: EditRecipe) -> Float {
        guard let dngColor else { return 1 }
        return Float(dngColor.weight(recipe.whiteBalanceMode == .asShot ? asShotTemperature : recipe[.temperature]))
    }
}

/// How the pyramid was reconstructed, which shapes its noise.
enum SensorKind: Sendable {
    case bayer
    case xTrans
    case linear
    case bitmap

    init(_ layout: DecodedImage.Layout) {
        switch layout {
        case let .mosaic(pattern), let .balancedCameraHalf(pattern?):
            self = pattern.width == 2 && pattern.height == 2 ? .bayer : .xTrans
        case .linearRGB, .balancedCameraHalf(nil): self = .linear
        case .linearSRGBHalf: self = .bitmap
        }
    }
}

/// What `SessionBuilder.maps` makes from a pyramid's pixels.
struct ImageMaps {
    let analysis: AnalysisImage
    let airlight: SIMD3<Float>
    let hazeMap: any MTLTexture
    let refinedHaze: any MTLTexture
    let addedHaze: any MTLTexture
    let toneBase: any MTLTexture
    let clarityBase: any MTLTexture
    let glowSource: any MTLTexture
    let glowLights: any MTLTexture
}

/// A downsampled CPU copy of the pyramid in camera RGB (balanced by the as-shot
/// multipliers, like the pyramid itself).
struct AnalysisImage: Sendable {
    let width: Int
    let height: Int
    let pixels: PackedRGB

    init(width: Int, height: Int, pixels: some Collection<SIMD3<Float>>) {
        self.width = width
        self.height = height
        self.pixels = PackedRGB(pixels)
    }

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

/// The inverse of `sourceCoordinate`.
func orientedCoordinate(_ point: SIMD2<Double>, orientation: Int) -> SIMD2<Double> {
    switch orientation {
    case 3: SIMD2(1 - point.x, 1 - point.y)
    case 5: SIMD2(point.y, 1 - point.x)
    case 6: SIMD2(1 - point.y, point.x)
    default: point
    }
}
