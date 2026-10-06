import Foundation
import Metal
import RedlampEngineAPI
import RedlampMasking
import simd
import Synchronization

/// Generative fill (RM-10): a Remove spot repainted by FLUX.2 [klein] 4B, which the app hands the
/// engine (`register(generativeFiller:)`), and kept with the edit as a bitmap in the photo's own
/// camera RGB, so it renders the same on every Mac, with the model or without.
public extension RedlampEngine {
    /// The model's manifest.
    internal static let generativeModelID = "flux2-klein-4b-fill"
    /// How Generative Remove fills a spot unless told otherwise.
    static let generativeDefaults = (prompt: "remove", reference: GenerativeFillReference.filled)

    /// What generative fill runs on, registered once at launch by a build that links a model.
    internal static let generativeFillerFactory = Mutex<GenerativeFillerFactory?>(nil)

    static func register(generativeFiller factory: @escaping GenerativeFillerFactory) {
        generativeFillerFactory.withLock { $0 = factory }
    }

    /// The model's folder: `REDLAMP_GENERATIVE_MODEL` (development, before the download is
    /// published), or the download once it's installed.
    internal func generativeModelDirectory() async -> URL? {
        if let path = ProcessInfo.processInfo.environment["REDLAMP_GENERATIVE_MODEL"], !path.isEmpty {
            return URL(fileURLWithPath: path)
        }
        guard let manifest = ModelCatalog.manifest(Self.generativeModelID) else { return nil }
        return await ModelStore.shared.location(of: manifest)
    }

    func generativeFillAvailability() async -> GenerativeFillAvailability {
        guard Self.generativeFillerFactory.withLock({ $0 }) != nil else {
            return .unavailable("This build has no generative model.")
        }
        if await generativeModelDirectory() != nil {
            return .ready
        }
        guard let manifest = ModelCatalog.manifest(Self.generativeModelID) else {
            return .unavailable("This build has no generative model.")
        }
        let info = await info(manifest)
        if let note = info.memoryNote {
            return .unavailable("Generative fill: \(note)")
        }
        guard manifest.isPublished, ModelCatalog.offered.contains(where: { $0.id == manifest.id }) else {
            return .unavailable("Generative fill's model isn't published yet.")
        }
        return .needsModel(info)
    }

    func generateFills(
        for spot: RetouchSpot, in recipe: EditRecipe, seeds: [Int], options: GenerativeFillOptions,
        progress: @escaping @Sendable (Double) -> Void,
    ) async throws -> [GeneratedFill] {
        guard let directory = await generativeModelDirectory() else {
            throw EngineError.generativeFillUnavailable("Generative fill's model isn't installed.")
        }
        guard let session = currentSession() else { throw EngineError.noImageOpen }
        let reference = options.reference ?? Self.generativeDefaults.reference
        let crop = try await withCheckedThrowingContinuation { continuation in
            renderQueue.async { [self] in
                continuation.resume(with: Result {
                    try generativeCrop(for: spot, in: recipe, session: session, reference: reference)
                })
            }
        }
        guard let crop else { return [] }
        let filler = try generativeFillerLoaded(from: directory)
        let prompt = options.prompt ?? Self.generativeDefaults.prompt
        let manifest = ModelCatalog.manifest(Self.generativeModelID)
        return try await Task.detached(priority: .userInitiated) {
            try seeds.enumerated().map { index, seed in
                let filled = try filler.fill(
                    image: crop.input, reference: crop.reference, mask: crop.mask, width: crop.width,
                    height: crop.height, seed: seed, prompt: prompt,
                ) { fraction in
                    progress((Double(index) + fraction) / Double(seeds.count))
                }
                return try crop.fill(
                    from: filled, seed: seed, prompt: prompt, model: manifest?.id ?? Self.generativeModelID,
                    version: manifest?.version ?? 1,
                )
            }
        }.value
    }

    func releaseGenerativeFill() async {
        let loaded = generativeFiller.withLock { loaded in
            defer { loaded = nil }
            return loaded
        }
        loaded?.filler.unload()
    }

    internal func generativeFillerLoaded(from directory: URL) throws -> any GenerativeFiller {
        if let loaded = generativeFiller.withLock({ $0 }), loaded.directory == directory {
            return loaded.filler
        }
        guard let factory = Self.generativeFillerFactory.withLock({ $0 }) else {
            throw EngineError.generativeFillUnavailable("This build has no generative model.")
        }
        let filler = try factory(directory)
        generativeFiller.withLock { $0 = (directory, filler) }
        return filler
    }

    /// What the model is shown for `spot`: a square of the photo around it, read from the finest
    /// pyramid level where it fits in 1024 pixels with at least half the spot's size around it
    /// (two and a half times its size when that fits, and at least 512 pixels), with the spots
    /// before it in; the spot's shape over it; and the `reference` the model looks at. Nil when the
    /// spot misses the photo.
    internal func generativeCrop(
        for spot: RetouchSpot, in recipe: EditRecipe, session base: ImageSession, reference: GenerativeFillReference,
    ) throws -> GenerativeCrop? {
        let index = recipe.spots.firstIndex { $0.id == spot.id } ?? recipe.spots.count
        var before = recipe
        before.spots = Array(recipe.spots[..<index])
        let pyramid = base.pyramid
        guard let placement = retouch.place(
            spot, orientation: base.orientation, width: pyramid.width, height: pyramid.height,
        ) else { return nil }
        let side = Double(max(placement.size.x, placement.size.y))
        let level = min(max(Int(ceil(log2(side * 1.5 / 1024))), 0), pyramid.mipmapLevelCount - 1)
        let scale = 1 << level
        let levelWidth = pyramid.width >> level, levelHeight = pyramid.height >> level
        let edge = min(max(Int(side * 2.5) / scale, 512), 1024)
        let width = min(edge, levelWidth) / 16 * 16, height = min(edge, levelHeight) / 16 * 16
        guard width >= 64, height >= 64 else { return nil }
        let center = SIMD2(
            Double(placement.origin.x) + Double(placement.size.x) / 2,
            Double(placement.origin.y) + Double(placement.size.y) / 2,
        ) / Double(scale)
        let origin = SIMD2(
            min(max(Int(center.x) - width / 2, 0), levelWidth - width),
            min(max(Int(center.y) - height / 2, 0), levelHeight - height),
        )
        let camera = try readCrop(of: before, base: base, level: level, origin: origin, width: width, height: height)
        var referenceCamera: [Float]? = switch reference {
        case .photo: camera
        case .none: nil
        case .filled, .softened: try readCrop(
                of: Self.withFilledSpot(spot, before), base: base, level: level, origin: origin, width: width,
                height: height,
            )
        }
        var hole = [Bool](repeating: false, count: width * height)
        for y in 0 ..< height {
            for x in 0 ..< width {
                let centre = (SIMD2(Float(origin.x + x), Float(origin.y + y)) + 0.5) * Float(scale)
                hole[y * width + x] = placement.covers(centre, reach: placement.radius)
            }
        }
        if reference == .softened, let filled = referenceCamera {
            referenceCamera = GenerativeCrop.blurred(filled, inside: hole, width: width, height: height, radius: 24)
        }
        return GenerativeCrop(
            camera: camera, reference: referenceCamera, hole: hole, width: width, height: height, origin: origin,
            scale: scale, spotBox: (placement.origin, placement.size),
            photoSize: PixelSize(width: pyramid.width, height: pyramid.height), cameraToWorking: base.cameraToWorking,
        )
    }

    /// `recipe` with `spot` after its spots, filled from the photo around it.
    private static func withFilledSpot(_ spot: RetouchSpot, _ recipe: EditRecipe) -> EditRecipe {
        var filled = recipe
        var classical = spot
        classical.fill = nil
        filled.spots.append(classical)
        return filled
    }

    /// The photo as `recipe`'s spots leave it, `width` × `height` texels of pyramid `level` from
    /// `origin`, linear camera RGB.
    private func readCrop(
        of recipe: EditRecipe, base: ImageSession, level: Int, origin: SIMD2<Int>, width: Int, height: Int,
    ) throws -> [Float] {
        guard let commands = queue.makeCommandBuffer() else { throw EngineError.gpuUnavailable }
        let buffer = try encoding(commands) {
            let pyramid = try retouch.session(for: recipe, base: base, commands: commands).pyramid
            guard let buffer = device.makeBuffer(length: width * height * 8, options: .storageModeShared),
                  let blit = commands.makeBlitCommandEncoder()
            else { throw EngineError.gpuUnavailable }
            blit.copy(
                from: pyramid, sourceSlice: 0, sourceLevel: level,
                sourceOrigin: MTLOrigin(x: origin.x, y: origin.y, z: 0),
                sourceSize: MTLSize(width: width, height: height, depth: 1), to: buffer, destinationOffset: 0,
                destinationBytesPerRow: width * 8, destinationBytesPerImage: width * height * 8,
            )
            blit.endEncoding()
            return buffer
        }
        try finish(commands)
        let halves = buffer.contents().assumingMemoryBound(to: Float16.self)
        return (0 ..< width * height * 3).map { Float(halves[($0 / 3) * 4 + $0 % 3]) }
    }
}

/// A spot's surroundings as the model sees them, and the way back to the photo's camera RGB.
///
/// The model expects an ordinary sRGB picture, while the pyramid holds linear camera RGB. On the
/// way in the crop is converted to linear sRGB, scaled so its mean brightness sits at a quarter,
/// rolled off towards white (`x / (1 + x)`) and sRGB-encoded; the fill comes back the same way
/// reversed, so what the model leaves alone returns as it was, give or take 16 bits.
struct GenerativeCrop: Sendable {
    /// Rec. 2020 to sRGB primaries (D65), linear.
    static let rec2020ToSRGB = simd_float3x3(columns: (
        SIMD3(1.6605, -0.1246, -0.0182), SIMD3(-0.5876, 1.1329, -0.1006), SIMD3(-0.0728, -0.0083, 1.1187),
    ))

    let width: Int
    let height: Int
    /// Linear camera RGB, row by row.
    let camera: [Float]
    /// The model's input, sRGB-encoded 0…1, and the reference it looks at, if any.
    let input: [Float]
    let reference: [Float]?
    /// 1 where the model repaints: the spot, grown by 8 pixels so the latents' 16-pixel cells
    /// along its edge are repainted too.
    let mask: [Float]
    /// Where the crop's corner is, in the pyramid level's texels, and that level's scale.
    let origin: SIMD2<Int>
    let scale: Int
    let spotBox: (origin: SIMD2<Int>, size: SIMD2<Int>)
    let photoSize: PixelSize
    private let toSRGB: simd_float3x3
    private let exposure: Float

    init(
        camera: [Float], reference: [Float]?, hole: [Bool], width: Int, height: Int, origin: SIMD2<Int>, scale: Int,
        spotBox: (SIMD2<Int>, SIMD2<Int>), photoSize: PixelSize, cameraToWorking: simd_float3x3,
    ) {
        self.camera = camera
        self.width = width
        self.height = height
        self.origin = origin
        self.scale = scale
        self.spotBox = spotBox
        self.photoSize = photoSize
        let toSRGB = Self.rec2020ToSRGB * cameraToWorking
        self.toSRGB = toSRGB
        var sum = 0.0, count = 0
        for index in 0 ..< width * height where !hole[index] {
            let rgb = toSRGB * SIMD3(camera[index * 3], camera[index * 3 + 1], camera[index * 3 + 2])
            sum += Double(simd_dot(simd_max(rgb, .zero), SIMD3(0.2126, 0.7152, 0.0722)))
            count += 1
        }
        let exposure = Float(min(max(0.25 / max(sum / Double(max(count, 1)), 1e-6), 0.05), 100))
        self.exposure = exposure
        func shown(_ camera: [Float]) -> [Float] {
            var shown = [Float](repeating: 0, count: width * height * 3)
            for index in 0 ..< width * height {
                let rgb = simd_max(
                    toSRGB * SIMD3(camera[index * 3], camera[index * 3 + 1], camera[index * 3 + 2]), .zero,
                )
                let rolled = rgb * exposure / (1 + rgb * exposure)
                for channel in 0 ..< 3 {
                    shown[index * 3 + channel] = Self.encode(rolled[channel])
                }
            }
            return shown
        }
        let input = shown(camera)
        self.input = input
        self.reference = reference.map { $0 == camera ? input : shown($0) }
        mask = Self.grown(hole, width: width, height: height, by: 8)
    }

    /// The model's fill as the edit keeps it: back to camera RGB, then stored for the spot's box
    /// and 16 pixels around it (in the photo's full-size pixels).
    func fill(from filled: [Float], seed: Int, prompt: String, model: String, version: Int) throws -> GeneratedFill {
        let inverse = toSRGB.inverse
        let margin = 16
        let low = SIMD2(
            max((spotBox.origin.x - margin) / scale - origin.x, 0), max(
                (spotBox.origin.y - margin) / scale - origin.y,
                0,
            ),
        )
        let high = SIMD2(
            min((spotBox.origin.x + spotBox.size.x + margin + scale - 1) / scale - origin.x, width),
            min((spotBox.origin.y + spotBox.size.y + margin + scale - 1) / scale - origin.y, height),
        )
        guard high.x > low.x, high.y > low.y else {
            throw EngineError.generativeFillUnavailable("The spot is outside the photo.")
        }
        let (columns, rows) = (high.x - low.x, high.y - low.y)
        var rgb = [Float](repeating: 0, count: columns * rows * 3)
        for row in 0 ..< rows {
            for column in 0 ..< columns {
                let source = ((low.y + row) * width + low.x + column) * 3
                let encoded = SIMD3(filled[source], filled[source + 1], filled[source + 2])
                let rolled = simd_min(
                    SIMD3(Self.decode(encoded.x), Self.decode(encoded.y), Self.decode(encoded.z)),
                    SIMD3(repeating: 0.995),
                )
                let linear = rolled / (1 - rolled) / exposure
                let camera = simd_max(inverse * linear, .zero)
                let target = (row * columns + column) * 3
                rgb[target] = camera.x
                rgb[target + 1] = camera.y
                rgb[target + 2] = camera.z
            }
        }
        let (png, peak) = try GeneratedFillCodec.encode(rgb, width: columns, height: rows)
        return GeneratedFill(
            bitmap: MaskBitmap(png: png, width: columns, height: rows), peak: peak,
            box: GeneratedFill.Box(
                x: (origin.x + low.x) * scale, y: (origin.y + low.y) * scale, width: columns * scale,
                height: rows * scale,
            ),
            photoSize: photoSize, model: model, modelVersion: version, seed: seed, prompt: prompt,
        )
    }

    static func encode(_ linear: Float) -> Float {
        let value = min(max(linear, 0), 1)
        return value <= 0.0031308 ? value * 12.92 : 1.055 * pow(value, 1 / 2.4) - 0.055
    }

    static func decode(_ encoded: Float) -> Float {
        let value = min(max(encoded, 0), 1)
        return value <= 0.04045 ? value / 12.92 : pow((value + 0.055) / 1.055, 2.4)
    }

    /// `rgb` (three values a pixel) box-blurred twice over `radius` pixels inside `hole`, grown by the
    /// radius and fading out over it, and as it was elsewhere.
    static func blurred(_ rgb: [Float], inside hole: [Bool], width: Int, height: Int, radius: Int) -> [Float] {
        func boxed(_ values: [Float], horizontal: Bool) -> [Float] {
            var out = values
            let (lines, length) = horizontal ? (height, width) : (width, height)
            for line in 0 ..< lines {
                for channel in 0 ..< 3 {
                    func at(_ position: Int) -> Int {
                        let p = min(max(position, 0), length - 1)
                        return ((horizontal ? line * width + p : p * width + line) * 3) + channel
                    }
                    var sum: Float = 0
                    for position in -radius ... radius {
                        sum += values[at(position)]
                    }
                    for position in 0 ..< length {
                        out[at(position)] = sum / Float(2 * radius + 1)
                        sum += values[at(position + radius + 1)] - values[at(position - radius)]
                    }
                }
            }
            return out
        }
        var soft = rgb
        for _ in 0 ..< 2 {
            soft = boxed(boxed(soft, horizontal: true), horizontal: false)
        }
        let weights = boxed(
            grown(hole, width: width, height: height, by: radius).flatMap { [$0, $0, $0] }, horizontal: true,
        )
        return rgb.indices.map { index in
            let weight = min(weights[index] * 2, 1)
            return rgb[index] * (1 - weight) + soft[index] * weight
        }
    }

    /// `hole` as 0 and 1, grown by `radius` pixels (a square, which the latents' cells are anyway).
    static func grown(_ hole: [Bool], width: Int, height: Int, by radius: Int) -> [Float] {
        var rows = [Bool](repeating: false, count: width * height)
        for y in 0 ..< height {
            for x in 0 ..< width where hole[y * width + x] {
                for nx in max(x - radius, 0) ... min(x + radius, width - 1) {
                    rows[y * width + nx] = true
                }
            }
        }
        var grown = [Float](repeating: 0, count: width * height)
        for x in 0 ..< width {
            for y in 0 ..< height where rows[y * width + x] {
                for ny in max(y - radius, 0) ... min(y + radius, height - 1) {
                    grown[ny * width + x] = 1
                }
            }
        }
        return grown
    }
}
