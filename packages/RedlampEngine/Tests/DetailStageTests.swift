import Foundation
import IOSurface
import Metal
import RedlampEngineAPI
import RedlampKernels
import RedlampMasking
import RedlampServices
import simd
import Testing
@testable import RedlampEngine

/// Flat synthetic sensors with exact Poisson–Gaussian noise, through the real session builder.
@Suite(.enabled(if: MTLCreateSystemDefaultDevice() != nil))
struct DetailStageTests {
    static let noise = NoiseModel(a: SIMD3(repeating: 4e-4), b: SIMD3(repeating: 2e-6))
    static let level: Float = 0.25

    let device: any MTLDevice
    let queue: any MTLCommandQueue
    let kernels: KernelLibrary

    init() throws {
        device = try #require(MTLCreateSystemDefaultDevice())
        queue = try #require(device.makeCommandQueue())
        kernels = try KernelLibrary(device: device)
    }

    static let calibrating = ProcessInfo.processInfo.environment["REDLAMP_CALIBRATE_NOISE"] == "1"

    /// The measured detail noise per scale must match `NoiseCalibration`, which is what the
    /// thresholds are scaled by. Slow (minutes), so it runs on request, after a demosaic or pyramid
    /// change: `TEST_RUNNER_REDLAMP_CALIBRATE_NOISE=1`. It prints the table to paste.
    @Test(.enabled(if: calibrating), arguments: [SensorKind.bayer, .xTrans, .linear])
    func `calibration matches the pipeline`(sensor: SensorKind) throws {
        let session = try makeSession(sensor, width: 2048, height: 1536)
        for level in 0 ... 2 {
            let measured = try measureScaleNoise(session, level: level)
            let table = NoiseCalibration.sigmas(sensor: sensor, level: level)
            let formatted = measured.map { String(format: "(%.4f, %.4f, %.4f)", $0.x, $0.y, $0.z) }
            print("calibration \(sensor) level \(level): [\(formatted.joined(separator: ", "))]")
            for scale in 0 ..< DenoiseSettings.scaleCount {
                for axis in 0 ..< 3 {
                    let ratio = measured[scale][axis] / table[scale][axis]
                    #expect(abs(ratio - 1) < 0.15, "\(sensor) level \(level) scale \(scale) axis \(axis): \(ratio)")
                }
            }
        }
    }

    @Test func `noise reduction removes noise and keeps the level`() throws {
        let session = try makeSession(.bayer, width: 1024, height: 768)
        var recipe = Self.unsharpened
        recipe[.noiseLuminance] = 60
        recipe[.noiseColor] = 50
        let before = try statistics(of: readLevel(session, level: 0))
        let after = try statistics(of: processed(session, recipe: recipe))
        for channel in 0 ..< 3 {
            #expect(abs(after.mean[channel] / before.mean[channel] - 1) < 0.01, "mean \(channel)")
            #expect(after.deviation[channel] < before.deviation[channel] * 0.4, "deviation \(channel)")
        }
    }

    @Test func `zero thresholds reproduce the pyramid`() throws {
        let session = try makeSession(.bayer, width: 512, height: 384)
        let source = try readLevel(session, level: 0)
        var nearlyOff = Self.unsharpened
        // Keeps the stage running with thresholds that remove nothing.
        nearlyOff[.noiseLuminance] = 0.001
        nearlyOff[.noiseColor] = 0
        let passed = try processed(session, recipe: nearlyOff)
        var worst: Float = 0
        for index in stride(from: 0, to: source.count, by: 7) {
            worst = max(worst, simd_abs(source[index] - passed[index]).max())
        }
        #expect(worst < 2e-3)
    }

    /// Tiles denoise with enough margin that seams can't show: small tiles must give the same
    /// still as one tile covering everything.
    @Test(.enabled(if: !EngineSmokeTests.fixtures.isEmpty))
    func `tiled stills match untiled`() async throws {
        let url = try #require(EngineSmokeTests.fixtures.first { SupportedFormats.isRaw($0) })
        var recipe = EditRecipe()
        recipe[.noiseLuminance] = 80
        recipe[.noiseColor] = 60
        recipe[.grainAmount] = 30
        recipe[.texture] = 40
        recipe[.clarity] = 30
        let request = StillRequest(recipe: recipe, maxLongEdge: 1500)
        var renders: [Data] = []
        for tile in [256, 4096] {
            let engine = try RedlampEngine(stillTile: tile)
            _ = try await engine.open(url)
            let image = try await engine.renderStill(request)
            try renders.append(#require(image.dataProvider?.data) as Data)
        }
        #expect(renders[0].count == renders[1].count)
        var worst = 0
        var differing = 0
        var rounding = 0
        for (a, b) in zip(renders[0], renders[1]) where a != b {
            worst = max(worst, abs(Int(a) - Int(b)))
            differing += 1
            rounding += abs(Int(a) - Int(b)) > 1 ? 1 : 0
        }
        // A lens correction moves each tile's sample positions by a rounding error, which now and
        // then tips a value two levels; a seam would be whole rows of them.
        #expect(
            worst <= 2 && rounding <= renders[0].count / 100_000,
            "largest difference \(worst) in \(differing) bytes",
        )
    }

    /// A region at 1:1 carries enough margin that its texels are the full render's, at the
    /// strongest settings, whose filters reach furthest.
    @Test func `a region renders what the whole frame renders there`() throws {
        let (width, height) = (640, 480)
        let session = try makeSession(.bayer, width: width, height: height) { x, y in
            Float(0.2 + 0.1 * sin(Double(x) / 3) * cos(Double(y) / 5))
        }
        var recipe = Self.untouched
        recipe[.noiseLuminance] = 100
        recipe[.noiseColor] = 100
        let stage = DetailStage(device: device, kernels: kernels)
        /// The texels, where they start in the frame, and their row length.
        func render(
            _ region: ImageRect,
            _ size: PixelSize,
        ) throws -> (texels: [SIMD3<Float>], x: Int, y: Int, width: Int) {
            let commands = try #require(queue.makeCommandBuffer())
            let output = try #require(try stage.process(
                recipe, session: session, region: region, outputSize: size, commands: commands, cache: false,
            ))
            commands.commit()
            commands.waitUntilCompleted()
            let texture = output.texture
            let texels = try readBack(texture, level: 0, width: texture.width, height: texture.height)
            let x = Int((output.area.x * Float(width)).rounded()), y = Int((output.area.y * Float(height)).rounded())
            return (texels, x, y, texture.width)
        }
        let full = try render(.full, session.orientedSize)
        let region = try render(ImageRect(x: 0.4, y: 0.4, width: 0.2, height: 0.2), PixelSize(width: 128, height: 96))
        #expect(region.x > 0 && region.width < width)
        var worst: Float = 0
        for y in 192 ..< 288 {
            for x in 256 ..< 384 {
                let inRegion = region.texels[(y - region.y) * region.width + x - region.x]
                worst = max(worst, simd_abs(inRegion - full.texels[y * full.width + x]).max())
            }
        }
        #expect(worst < 1e-3, "largest difference \(worst)")
    }

    // MARK: - Sharpening

    /// Noise reduction and sharpening both off.
    static let untouched: EditRecipe = {
        var recipe = EditRecipe()
        recipe[.noiseColor] = 0
        recipe[.sharpenAmount] = 0
        return recipe
    }()

    static let unsharpened: EditRecipe = {
        var recipe = EditRecipe()
        recipe[.sharpenAmount] = 0
        return recipe
    }()

    @Test func `sharpening overshoots an edge and keeps the level`() throws {
        let session = try makeSession(.bayer, width: 512, height: 256, noiseScale: 0) { x, _ in x < 256 ? 0.1 : 0.4 }
        var recipe = Self.untouched
        recipe[.sharpenAmount] = 100
        let before = try readLevel(session, level: 0)
        let after = try processed(session, recipe: recipe)
        let row = 128 * 512
        // The dark side of the step gets darker and the bright side brighter; flat areas far
        // from it don't change. (Extremes, because demosaicing already ripples at a hard step.)
        let dark = { (pixels: [SIMD3<Float>]) in (250 ... 255).map { pixels[row + $0].y }.min()! }
        let bright = { (pixels: [SIMD3<Float>]) in (256 ... 261).map { pixels[row + $0].y }.max()! }
        #expect(dark(after) < dark(before) * 0.97)
        #expect(bright(after) > bright(before) * 1.02)
        #expect(abs(after[row + 100].y / before[row + 100].y - 1) < 0.002)
        let mean = { (pixels: [SIMD3<Float>]) in pixels.reduce(SIMD3<Float>.zero, +).y / Float(pixels.count) }
        #expect(abs(mean(after) / mean(before) - 1) < 0.01)
    }

    @Test func `the stage is skipped when nothing needs it`() throws {
        let session = try makeSession(.bayer, width: 256, height: 256)
        let stage = DetailStage(device: device, kernels: kernels)
        let commands = try #require(queue.makeCommandBuffer())
        let output = try stage.process(
            Self.untouched, session: session, region: .full, outputSize: session.orientedSize, commands: commands,
        )
        #expect(output == nil)
        #expect(!DetailStage.isActive(Self.untouched))
    }

    // MARK: - Texture and Clarity

    /// A neutral scene whose log luminance is a vertical-stripe sinusoid of `period` pixels.
    private func stripes(period: Double) throws -> ImageSession {
        try makeSession(.bayer, width: 768, height: 256, noiseScale: 0) { x, _ in
            Float(0.2 * pow(2, 0.5 * sin(2 * .pi * Double(x) / period)))
        }
    }

    /// The stripes' amplitude in stops, away from the borders.
    private func amplitude(_ pixels: [SIMD3<Float>]) -> Float {
        let logs = (128 ..< 640).map { log2(pixels[128 * 768 + $0].y) }
        let mean = logs.reduce(0, +) / Float(logs.count)
        return (logs.map { ($0 - mean) * ($0 - mean) }.reduce(0, +) / Float(logs.count)).squareRoot()
    }

    private func gain(_ session: ImageSession, _ recipe: EditRecipe) throws -> Float {
        try amplitude(processed(session, recipe: recipe)) / amplitude(readLevel(session, level: 0))
    }

    @Test func `texture works on medium detail`() throws {
        var more = Self.untouched
        more[.texture] = 100
        var less = Self.untouched
        less[.texture] = -100
        let medium = try stripes(period: 6)
        #expect(try gain(medium, more) > 1.2)
        #expect(try gain(medium, less) < 0.85)
        #expect(try abs(gain(stripes(period: 128), more) - 1) < 0.05)
    }

    @Test func `clarity works on larger detail`() throws {
        var recipe = Self.untouched
        recipe[.clarity] = 100
        #expect(try gain(stripes(period: 48), recipe) > 1.1)
    }

    /// A dark and a bright half, 3.3 stops apart, both with Clarity-sized stripes (48 px, ±0.15
    /// stops). Per-level Clarity takes the edge for detail and brightens the bright side beside it
    /// and darkens the dark side; edge-aware Clarity (process 9) boosts the stripes at least as
    /// much and leaves the edge mostly alone.
    @Test func `edge-aware clarity puts no bands along an edge`() throws {
        let width = 1024
        let edge = width / 2
        let session = try makeSession(.bayer, width: width, height: 256, noiseScale: 0) { x, _ in
            Float((x < edge ? 0.05 : 0.5) * pow(2, 0.15 * sin(2 * .pi * Double(x) / 48)))
        }
        let source = try readLevel(session, level: 0)
        func measure(process: Int) throws -> (bright: Float, dark: Float, gain: Float) {
            var recipe = Self.untouched
            recipe.processVersion = process
            recipe[.clarity] = 100
            let output = try processed(session, recipe: recipe)
            func shift(_ columns: Range<Int>) -> Float {
                columns.map { log2(output[128 * width + $0].y) - log2(source[128 * width + $0].y) }
                    .reduce(0, +) / Float(columns.count)
            }
            func spread(_ pixels: [SIMD3<Float>], _ columns: Range<Int>) -> Float {
                let logs = columns.map { log2(pixels[128 * width + $0].y) }
                let mean = logs.reduce(0, +) / Float(logs.count)
                return (logs.map { ($0 - mean) * ($0 - mean) }.reduce(0, +) / Float(logs.count)).squareRoot()
            }
            let far = 124 ..< 316
            return (
                shift(edge + 4 ..< edge + 52) - shift(edge + 188 ..< edge + 380),
                shift(edge - 52 ..< edge - 4) - shift(far),
                spread(output, far) / spread(source, far),
            )
        }
        let perLevel = try measure(process: 8)
        let edgeAware = try measure(process: 9)
        print("clarity beside the edge: per level \(perLevel), edge-aware \(edgeAware)")
        #expect(perLevel.bright > 0.05 && perLevel.dark < -0.05, "per-level Clarity bands the edge: \(perLevel)")
        #expect(edgeAware.gain >= perLevel.gain, "stripes: \(edgeAware.gain), per level \(perLevel.gain)")
        /// The bands for each stop of the stripes' boost, so a stronger gain isn't an excuse.
        func perBoost(_ band: Float, _ gain: Float) -> Float {
            abs(band) / log2(gain)
        }
        #expect(
            perBoost(edgeAware.bright, edgeAware.gain) < perBoost(perLevel.bright, perLevel.gain) / 3,
            "bright side: \(edgeAware), per level \(perLevel)",
        )
        #expect(
            perBoost(edgeAware.dark, edgeAware.gain) < perBoost(perLevel.dark, perLevel.gain) / 3,
            "dark side: \(edgeAware), per level \(perLevel)",
        )
    }

    // MARK: - Masks

    /// A mask covering the left 45% of the photo, fading out by 55%.
    func leftHalf(_ parameter: ParameterID, _ value: Double) -> MaskLayer {
        let gradient = LinearMask(start: ImagePoint(x: 0.45, y: 0.5), end: ImagePoint(x: 0.55, y: 0.5))
        return MaskLayer(
            name: "Left",
            components: [MaskComponent(shape: .linear(gradient))],
            adjustments: [parameter: value],
        )
    }

    private func amplitude(_ pixels: [SIMD3<Float>], columns: Range<Int>) -> Float {
        let logs = columns.map { log2(pixels[128 * 768 + $0].y) }
        let mean = logs.reduce(0, +) / Float(logs.count)
        return (logs.map { ($0 - mean) * ($0 - mean) }.reduce(0, +) / Float(logs.count)).squareRoot()
    }

    @Test func `a mask's texture only works inside it`() throws {
        let session = try stripes(period: 6)
        var recipe = Self.untouched
        recipe.masks = [leftHalf(.localTexture, 100)]
        let before = try readLevel(session, level: 0)
        let after = try processed(session, recipe: recipe)
        let inside = amplitude(after, columns: 64 ..< 300) / amplitude(before, columns: 64 ..< 300)
        let outside = amplitude(after, columns: 468 ..< 704) / amplitude(before, columns: 468 ..< 704)
        #expect(inside > 1.2, "inside \(inside)")
        #expect(abs(outside - 1) < 0.02, "outside \(outside)")
    }

    @Test func `a mask's noise reduction only works inside it`() throws {
        let session = try makeSession(.bayer, width: 768, height: 256)
        var recipe = Self.untouched
        recipe.masks = [leftHalf(.localNoise, 100)]
        let after = try processed(session, recipe: recipe)
        let deviation = { (columns: Range<Int>) -> Float in
            let values = (32 ..< 224).flatMap { y in columns.map { after[y * 768 + $0].y } }
            let mean = values.reduce(0, +) / Float(values.count)
            return (values.map { ($0 - mean) * ($0 - mean) }.reduce(0, +) / Float(values.count)).squareRoot()
        }
        let inside = deviation(32 ..< 300)
        let outside = deviation(468 ..< 736)
        #expect(inside < outside * 0.6, "inside \(inside), outside \(outside)")
    }

    // MARK: - Caches

    /// Process 10: noise reduction, sharpening, Texture and Clarity, before they shared a ladder.
    static let everyPassBeforeLadder: EditRecipe = {
        var recipe = untouched
        recipe.processVersion = 10
        recipe[.noiseLuminance] = 40
        recipe[.noiseColor] = 30
        recipe[.sharpenAmount] = 60
        recipe[.texture] = 30
        recipe[.clarity] = 25
        return recipe
    }()

    /// Before process 11, dragging sharpening, Texture or Clarity reads the noise-reduced source
    /// the last render kept, as process 11's ladder does, so noise is reduced only when its own
    /// settings or a mask's Noise change; each drag renders what a fresh stage renders, whole and
    /// in tiles.
    @Test(arguments: [false, true])
    func `drags before process 11 keep the noise-reduced source`(tiled: Bool) throws {
        let session = try makeSession(.bayer, width: 1024, height: 768) { x, y in
            Float(0.2 + 0.1 * sin(Double(x) / 3) * cos(Double(y) / 5))
        }
        let stage = DetailStage(device: device, kernels: kernels)
        if tiled {
            stage.scratchBudget = 118 * 300_000
        }
        var recipe = Self.everyPassBeforeLadder
        recipe.masks = [leftHalf(.localClarity, 40)]
        _ = try processAndRead(stage, session, recipe)
        let drags: [(ParameterID, Double, keepsSource: Bool)] = [
            (.texture, 60, true), (.clarity, -30, true), (.sharpenAmount, 120, true), (.sharpenDetail, 80, true),
            (.sharpenMasking, 40, true), (.sharpenRadius, 2, true), (.noiseLuminance, 55, false),
            (.texture, -40, true), (.noiseColor, 10, false),
        ]
        for (parameter, value, keepsSource) in drags {
            recipe[parameter] = value
            let before = stage.noiseReductions
            let cached = try processAndRead(stage, session, recipe).texels
            if tiled {
                #expect(stage.tileCount >= 2, "\(parameter): \(stage.tileCount) tile")
            }
            let fresh = try processAndRead(DetailStage(device: device, kernels: kernels), session, recipe).texels
            let differing = EngineMemoryTests.differing(cached, fresh)
            #expect(differing == 0, "\(parameter): \(differing) texels differ")
            let reductions = stage.noiseReductions - before
            #expect(keepsSource ? reductions == 0 : reductions > 0, "\(parameter): \(reductions) noise reductions")
        }
        #expect(stage.ladderCache.heldTextures.count == 1)
        recipe.masks[0][.localNoise] = 50
        let before = stage.noiseReductions
        let cached = try processAndRead(stage, session, recipe).texels
        let fresh = try processAndRead(DetailStage(device: device, kernels: kernels), session, recipe).texels
        #expect(EngineMemoryTests.differing(cached, fresh) == 0, "a mask's Noise")
        #expect(stage.noiseReductions > before, "a mask's Noise")
    }

    /// A Noise drag before process 11 writes its noise-reduced source over the one it replaces, so
    /// each tick makes only its output, as before the source was kept, and holds one source.
    @Test func `noise drags before process 11 reuse the kept source`() throws {
        let session = try makeSession(.bayer, width: 1024, height: 768) { x, y in
            Float(0.2 + 0.1 * sin(Double(x) / 3) * cos(Double(y) / 5))
        }
        let stage = DetailStage(device: device, kernels: kernels)
        var recipe = Self.everyPassBeforeLadder
        _ = try processAndRead(stage, session, recipe)
        for luminance in [45.0, 50, 55] {
            recipe[.noiseLuminance] = luminance
            let before = stage.allocated.count
            let cached = try processAndRead(stage, session, recipe).texels
            #expect(stage.allocated.count - before == 1, "Luminance \(luminance) made more than its output")
            #expect(stage.ladderCache.heldTextures.count == 1)
            let fresh = try processAndRead(DetailStage(device: device, kernels: kernels), session, recipe).texels
            #expect(EngineMemoryTests.differing(cached, fresh) == 0, "Luminance \(luminance)")
        }
    }

    /// Moving to another photo lets go of what the stage kept for the one before, and of its
    /// session, even when the new photo needs none of the stage.
    @Test func `moving to another photo lets go of the last one's textures and session`() throws {
        let stage = DetailStage(device: device, kernels: kernels)
        weak var first: ImageSession?
        try autoreleasepool {
            let session = try makeSession(.bayer, width: 640, height: 480) { x, y in
                Float(0.2 + 0.1 * sin(Double(x) / 3) * cos(Double(y) / 5))
            }
            first = session
            _ = try processAndRead(stage, session, Self.everyPassBeforeLadder)
        }
        #expect(!stage.ladderCache.heldTextures.isEmpty)
        let other = try makeSession(.bayer, width: 512, height: 384)
        let commands = try #require(queue.makeCommandBuffer())
        let output = try stage.process(
            Self.untouched, session: other, region: .full, outputSize: other.orientedSize, commands: commands,
        )
        commands.commit()
        commands.waitUntilCompleted()
        #expect(output == nil)
        #expect(stage.ladderCache.heldTextures.isEmpty && stage.cachedOutputs.isEmpty)
        #expect(first == nil, "the first photo's session is still held")
    }

    /// A crop's angle or a transform dragged a little moves the work area by a few texels: a
    /// cached render whose area covers the new one serves it, with the texels a fresh render
    /// makes there.
    @Test(arguments: [10, EditRecipe.currentProcessVersion])
    func `a work area inside a cached one is served from it`(process: Int) throws {
        let session = try makeSession(.bayer, width: 2048, height: 1536) { x, y in
            Float(0.2 + 0.1 * sin(Double(x) / 3) * cos(Double(y) / 5))
        }
        var recipe = Self.everyPassBeforeLadder
        recipe.processVersion = process
        recipe.crop = CropRect(left: 0.3, top: 0.3, right: 0.7, bottom: 0.7)
        recipe[.cropAngle] = 2
        let size = PixelSize(width: 820, height: 614)
        func work(_ recipe: EditRecipe) -> DetailStage.WorkArea {
            let geometry = GeometryMap(
                recipe: recipe, imageSize: session.orientedSize, lens: session.info.lensCorrection,
            )
            return DetailStage.workArea(session: session, geometry: geometry, region: .full, outputSize: size)
        }
        let stage = DetailStage(device: device, kernels: kernels)
        let first = try processAndRead(stage, session, recipe, outputSize: size)
        for (parameter, value) in [(ParameterID.cropAngle, 2.1), (.transformVertical, 1)] {
            var nudged = recipe
            nudged[parameter] = value
            let area = work(nudged)
            #expect(area != work(recipe) && area.level == 0, "\(parameter) leaves the work area as it was")
            let served = try processAndRead(stage, session, nudged, outputSize: size)
            withKnownIssue("PIPE-02: the stage caches only the exact work area") {
                #expect(served.output.texture === first.output.texture, "\(parameter) rendered again")
            }
            let fresh = try processAndRead(
                DetailStage(device: device, kernels: kernels), session, nudged, outputSize: size, cache: false,
            )
            func texel(
                _ read: (texels: [SIMD3<Float>], output: DetailStage.Output),
                _ x: Int,
                _ y: Int,
            ) -> SIMD3<Float> {
                let x0 = Int((read.output.area.x * Float(session.pyramid.width)).rounded())
                let y0 = Int((read.output.area.y * Float(session.pyramid.height)).rounded())
                return read.texels[(y - y0) * read.output.texture.width + x - x0]
            }
            var worst: Float = 0
            let low = area.origin &+ DetailStage.margin, high = area.origin &+ area.size &- DetailStage.margin
            for y in stride(from: low.y, to: high.y, by: 3) {
                for x in stride(from: low.x, to: high.x, by: 3) {
                    worst = max(worst, simd_abs(texel(served, x, y) - texel(fresh, x, y)).max())
                }
            }
            #expect(worst < 1e-3, "\(parameter): largest difference \(worst)")
        }
    }

    /// Noise reduction reads only the masks that set Noise, and only that amount, so dragging a
    /// mask's Texture, Clarity or Sharpness reads the kept source or ladder; its Noise doesn't.
    @Test(arguments: [10, EditRecipe.currentProcessVersion])
    func `a mask's other amounts leave noise reduction alone`(process: Int) throws {
        let session = try makeSession(.bayer, width: 640, height: 480) { x, y in
            Float(0.2 + 0.1 * sin(Double(x) / 3) * cos(Double(y) / 5))
        }
        let stage = DetailStage(device: device, kernels: kernels)
        var recipe = Self.everyPassBeforeLadder
        recipe.processVersion = process
        var noise = leftHalf(.localNoise, 40)
        noise[.localTexture] = 20
        recipe.masks = [noise, leftHalf(.localClarity, 30)]
        _ = try processAndRead(stage, session, recipe)
        let drags: [(mask: Int, ParameterID, Double, reduces: Bool)] = [
            (1, .localClarity, 60, false), (1, .localTexture, -30, false), (1, .localSharpness, 40, false),
            (0, .localTexture, 50, false), (0, .localNoise, 60, true),
        ]
        for (mask, parameter, value, reduces) in drags {
            recipe.masks[mask][parameter] = value
            let before = stage.noiseReductions
            let cached = try processAndRead(stage, session, recipe).texels
            let reductions = stage.noiseReductions - before
            #expect(reduces ? reductions > 0 : reductions == 0, "\(parameter): \(reductions) noise reductions")
            let fresh = try processAndRead(DetailStage(device: device, kernels: kernels), session, recipe).texels
            #expect(EngineMemoryTests.differing(cached, fresh) == 0, "\(parameter)")
        }
    }

    /// A process 10 render's kept source doesn't hide process 11's ladder for the same area.
    @Test func `switching between processes 10 and 11 keeps both`() throws {
        let session = try makeSession(.bayer, width: 640, height: 480) { x, y in
            Float(0.2 + 0.1 * sin(Double(x) / 3) * cos(Double(y) / 5))
        }
        let stage = DetailStage(device: device, kernels: kernels)
        var kept = Self.everyPassBeforeLadder
        var ladder = kept
        ladder.processVersion = 11
        _ = try processAndRead(stage, session, kept)
        _ = try processAndRead(stage, session, ladder)
        ladder[.texture] = 60
        kept[.texture] = 60
        for recipe in [ladder, kept] {
            let before = stage.noiseReductions
            let cached = try processAndRead(stage, session, recipe).texels
            #expect(stage.noiseReductions == before, "process \(recipe.processVersion)")
            let fresh = try processAndRead(DetailStage(device: device, kernels: kernels), session, recipe).texels
            #expect(EngineMemoryTests.differing(cached, fresh) == 0, "process \(recipe.processVersion)")
        }
    }

    /// A render that fails after taking back the area's kept source leaves nothing that serves the
    /// half-written texture: the next renders reduce noise afresh and match a fresh stage.
    @Test(arguments: [false, true])
    func `a render failing after it took the kept source back leaves no entry for it`(onGPU: Bool) throws {
        let session = try makeSession(.bayer, width: 640, height: 480) { x, y in
            Float(0.2 + 0.1 * sin(Double(x) / 3) * cos(Double(y) / 5))
        }
        let stage = DetailStage(device: device, kernels: kernels)
        let before = Self.everyPassBeforeLadder
        var after = before
        after[.noiseLuminance] = 50
        _ = try processAndRead(stage, session, before)
        let commands = try #require(queue.makeCommandBuffer())
        _ = try #require(try stage.process(
            after, session: session, region: .full, outputSize: session.orientedSize, commands: commands,
        ))
        if onGPU {
            commands.commit()
            commands.waitUntilCompleted()
            stage.forget(commands)
        } else {
            stage.abandon(commands)
        }
        #expect(stage.ladderCache.heldTextures.isEmpty)
        // The render before the failure may still serve its own output, which its commands finished.
        for (recipe, failed) in [(after, true), (before, false)] {
            let reductions = stage.noiseReductions
            let cached = try processAndRead(stage, session, recipe).texels
            if failed {
                #expect(stage.noiseReductions > reductions, "the failed render's settings")
            }
            let fresh = try processAndRead(DetailStage(device: device, kernels: kernels), session, recipe).texels
            #expect(EngineMemoryTests.differing(cached, fresh) == 0, "failed: \(failed)")
        }
    }

    /// From process 13 an AI mask's edges are refined to the photo's (`MaskEdges`), so a photo
    /// moved from process 12 to 13 renders its masks' detail afresh rather than from what the
    /// stage kept at 12 (PIPE-16).
    @Test func `moving an AI mask from process 12 to 13 renders its detail afresh`() throws {
        let session = try makeSession(.bayer, width: 512, height: 384) { x, _ in x < 268 ? 0.05 : 0.4 }
        let gray = GrayMask(width: 128, height: 96, pixels: (0 ..< 128 * 96).map { $0 % 128 < 64 ? 255 : 0 })
        var mask = try MaskLayer(name: "Subject", components: [MaskComponent(shape: .ai(AIMask(
            kind: .subject, provider: "test", revision: 1, analysisHash: "0", center: ImagePoint(x: 0.25, y: 0.5),
            bitmap: #require(gray.bitmap()),
        )))])
        mask[.localNoise] = 80
        mask[.localSharpness] = 60
        var recipe = Self.everyPassBeforeLadder
        recipe.processVersion = 12
        recipe.masks = [mask]
        func frame(_ engine: RedlampEngine, _ recipe: EditRecipe) throws -> [SIMD3<Float>] {
            let size = session.orientedSize
            let frame = try engine.renderFrame(
                RenderRequest(recipe: recipe, targetSize: size, generation: 0), session: session,
            )
            IOSurfaceLock(frame.surface, .readOnly, nil)
            defer { IOSurfaceUnlock(frame.surface, .readOnly, nil) }
            let rowBytes = IOSurfaceGetBytesPerRow(frame.surface)
            let base = IOSurfaceGetBaseAddress(frame.surface)
            return (0 ..< size.height).flatMap { y in
                let row = (base + y * rowBytes).assumingMemoryBound(to: Float16.self)
                return (0 ..< size.width).map { x in
                    SIMD3(Float(row[x * 4]), Float(row[x * 4 + 1]), Float(row[x * 4 + 2]))
                }
            }
        }
        let engine = try RedlampEngine()
        let twelve = try frame(engine, recipe)
        recipe.processVersion = 13
        let cached = try frame(engine, recipe)
        let cold = try frame(RedlampEngine(), recipe)
        #expect(EngineMemoryTests.differing(twelve, cold) > 0, "process 13 refines the mask")
        let differing = EngineMemoryTests.differing(cached, cold)
        #expect(differing == 0, "\(differing) texels differ from a cold render at 13")
    }

    /// With the noise-reduced source kept, tiles overlap by only what sharpening and local contrast
    /// read of it, and a halo short of that shows.
    @Test func `a halo short of the kept source's reach shows`() throws {
        let session = try makeSession(.bayer, width: 641, height: 479) { x, y in
            (x / 7 + y / 5).isMultiple(of: 2) ? 0.04 : 0.7
        }
        var newRadius = Self.everyPassBeforeLadder
        newRadius[.sharpenRadius] = 1.5
        let whole = try processAndRead(DetailStage(device: device, kernels: kernels), session, newRadius)
        let tiled = DetailStage(device: device, kernels: kernels)
        tiled.scratchBudget = 118 * 200_000
        _ = try processAndRead(tiled, session, Self.everyPassBeforeLadder)
        let work = DetailStage.WorkArea(level: 0, origin: .zero, size: SIMD2(641, 479))
        let measures = SharpenMeasures(separation: tiled.sharpenCache.separation(session, work))
        #expect(measures.separation != nil)
        let passes = try #require(DetailStage.passes(newRadius, session: session, level: 0, masks: .none))
        let halo = passes.halo(level: 0, measures: measures, denoised: true)
        #expect(halo < passes.halo(level: 0, measures: measures))
        // Half the deconvolution's reach falls below half-float precision; less than one blur's doesn't.
        tiled.haloShortfall = halo - 4
        let before = tiled.noiseReductions
        let tiles = try processAndRead(tiled, session, newRadius)
        #expect(tiled.noiseReductions == before && tiled.tileCount > 1)
        #expect(EngineMemoryTests.differing(whole.texels, tiles.texels) > 0, "halo \(halo)")
    }

    /// At Luminance 0, masks bound for Texture, Clarity or Sharpness change how noise reduction
    /// runs, so what the stage kept from a render without them isn't read once one is added.
    @Test(arguments: [10, EditRecipe.currentProcessVersion])
    func `adding a mask that leaves noise alone renders what a fresh stage renders`(process: Int) throws {
        let session = try makeSession(.bayer, width: 640, height: 480) { x, y in
            Float(0.2 + 0.1 * sin(Double(x) / 3) * cos(Double(y) / 5))
        }
        let stage = DetailStage(device: device, kernels: kernels)
        var recipe = Self.untouched
        recipe.processVersion = process
        recipe[.noiseColor] = 30
        recipe[.sharpenAmount] = 60
        _ = try processAndRead(stage, session, recipe)
        recipe.masks = [leftHalf(.localTexture, 50)]
        let cached = try processAndRead(stage, session, recipe).texels
        let fresh = try processAndRead(DetailStage(device: device, kernels: kernels), session, recipe).texels
        #expect(EngineMemoryTests.differing(cached, fresh) == 0)
    }

    // MARK: - Sensor cleanup

    @Test func `hot pixels are repaired`() throws {
        var random = SeededRandom(seed: 3)
        let hot = (0 ..< 40).map { _ in
            SIMD2(8 + Int(random.uniform() * 1000), 8 + Int(random.uniform() * 740))
        }
        let session = try makeSession(.bayer, width: 1024, height: 768, spikes: hot.map { ($0, 0.9) })
        #expect(session.repairedPixels == hot.count)
        let pixels = try readLevel(session, level: 0)
        for point in hot {
            let value = pixels[point.y * 1024 + point.x]
            #expect(value.max() < Self.level * 1.5, "\(point): \(value)")
        }
    }

    @Test func `clean noise and real highlights are left alone`() throws {
        #expect(try makeSession(.bayer, width: 1024, height: 768).repairedPixels == 0)
        #expect(try makeSession(.xTrans, width: 1024, height: 768).repairedPixels == 0)
        // A small highlight lights its neighbours too.
        let highlight = (-1 ... 1).flatMap { dy in (-1 ... 1).map { dx in (SIMD2(500 + dx, 400 + dy), Float(0.9)) } }
        #expect(try makeSession(.bayer, width: 1024, height: 768, spikes: highlight).repairedPixels == 0)
    }

    // MARK: - Highlights

    /// Bayer RGGB colour at a photosite.
    private static func bayerColor(_ x: Int, _ y: Int) -> Int {
        [0, 1, 1, 2][(y % 2) * 2 + x % 2]
    }

    @Test func `a clipped channel is rebuilt from its neighbours`() throws {
        // A reddish highlight (R:G:B = 1.25:1:0.8) whose red goes past the sensor's clip.
        let ratios: [Float] = [1.25, 1, 0.8]
        let session = try makeSession(.bayer, width: 512, height: 384, noiseScale: 0) { x, y in
            let r2 = Float((x - 256) * (x - 256) + (y - 192) * (y - 192))
            let level = 0.95 * exp(-r2 / (2 * 60 * 60))
            return min(ratios[Self.bayerColor(x, y)] * level, 1)
        }
        let centre = try readLevel(session, level: 0)[192 * 512 + 256]
        #expect(abs(centre.x / (1.25 * 0.95) - 1) < 0.05, "red \(centre.x)")
        #expect(abs(centre.x / centre.y / 1.25 - 1) < 0.05, "red to green \(centre.x / centre.y)")
    }

    @Test func `fully clipped areas stay neutral`() throws {
        let session = try makeSession(.bayer, width: 512, height: 384, noiseScale: 0, asShot: SIMD3(2, 1, 1.5)) {
            x, y in
            let r2 = Float((x - 256) * (x - 256) + (y - 192) * (y - 192))
            return min(2 * exp(-r2 / (2 * 40 * 40)), 1)
        }
        let centre = try readLevel(session, level: 0)[192 * 512 + 256]
        let neutral = HighlightModel.clipFraction * 2
        #expect(abs(centre.x / neutral - 1) < 0.01 && abs(centre.y / neutral - 1) < 0.01, "\(centre)")
        #expect(abs(centre.z / neutral - 1) < 0.01, "\(centre)")
    }

    // MARK: - Gain maps

    @Test func `gain maps scale the mosaic before demosaicing`() throws {
        // Gains 1 at the left edge to 2 at the right, on every photosite.
        let ramp = GainMap(
            top: 0, left: 0, bottom: 256, right: 512, plane: 0, planes: 1, rowPitch: 1, columnPitch: 1,
            pointsV: 1, pointsH: 2, spacingV: 1, spacingH: 1, originV: 0, originH: 0, mapPlanes: 1, gains: [1, 2],
        )
        let session = try makeSession(.bayer, width: 512, height: 256, noiseScale: 0, gainMaps: [ramp])
        let pixels = try readLevel(session, level: 0)
        for x in [128, 384] {
            let expected = Self.level * (1 + Float(x) / 512)
            #expect(abs(pixels[128 * 512 + x].y / expected - 1) < 0.02, "x \(x): \(pixels[128 * 512 + x].y)")
        }
    }

    @Test func `the noise gain follows each channel's maps`() {
        // One map per Bayer site, as phones write them: R x2, greens x1.5 and x1.7, B x3.
        let maps = zip([(0, 0), (0, 1), (1, 0), (1, 1)], [Float(2), 1.5, 1.7, 3]).map { site, gain in
            GainMap(
                top: site.0, left: site.1, bottom: 64, right: 96, plane: 0, planes: 1, rowPitch: 2, columnPitch: 2,
                pointsV: 1, pointsH: 1, spacingV: 1, spacingH: 1, originV: 0, originH: 0, mapPlanes: 1,
                gains: [gain],
            )
        }
        let field = NoiseGain.field(
            maps,
            width: 96,
            height: 64,
            pattern: CFAPattern(width: 2, height: 2, colors: [0, 1, 1, 2]),
        )
        #expect(field.width == 64 && field.height == 43)
        for gain in field.gains {
            #expect(abs(gain.x - 2) < 1e-5 && abs(gain.y - 1.6) < 1e-5 && abs(gain.z - 3) < 1e-5, "\(gain)")
        }
        let none = NoiseGain.field([], width: 96, height: 64, pattern: nil)
        #expect(none.gains == [SIMD4(1, 1, 1, 1)])
    }

    /// Lens shading amplifies the sensor noise with the signal; noise reduction must remove as
    /// much of it where the gain is high as where there is none.
    @Test func `noise reduction keeps up with gain-mapped noise`() throws {
        let (width, height) = (1024, 512)
        let right = GainMap(
            top: 0, left: width / 2, bottom: height, right: width, plane: 0, planes: 1, rowPitch: 1, columnPitch: 1,
            pointsV: 1, pointsH: 1, spacingV: 1, spacingH: 1, originV: 0, originH: 0, mapPlanes: 1, gains: [3],
        )
        let session = try makeSession(.bayer, width: width, height: height, gainMaps: [right])
        var recipe = Self.unsharpened
        recipe[.noiseLuminance] = 40
        let before = try readLevel(session, level: 0)
        let after = try processed(session, recipe: recipe)
        func remaining(_ columns: Range<Int>) -> Float {
            let rows = 32 ..< height - 32
            let pick = { (pixels: [SIMD3<Float>]) in rows.flatMap { y in columns.map { pixels[y * width + $0] } } }
            return statistics(of: pick(after)).deviation.y / statistics(of: pick(before)).deviation.y
        }
        let plain = remaining(32 ..< width / 2 - 64)
        let shaded = remaining(width / 2 + 64 ..< width - 32)
        #expect(plain < 0.6)
        #expect(abs(shaded / plain - 1) < 0.15, "noise left: \(plain) plain, \(shaded) behind a 3x gain")
    }

    // MARK: - Banding

    @Test func `banding offsets are subtracted before demosaicing`() throws {
        let (width, height) = (256, 256)
        let offsets = (0 ..< height).map { Float(($0 * 7919) % 13) - 6 }
        let banded = { (_: Int, y: Int) in Self.level + offsets[y] / (16383 - 512) }
        func rowSpread(_ session: ImageSession) throws -> Float {
            let pixels = try readLevel(session, level: 0)
            let means = (8 ..< height - 8).map { y in
                (8 ..< width - 8).reduce(Float(0)) { $0 + pixels[y * width + $1].y } / Float(width - 16)
            }
            return (means.max() ?? 0) - (means.min() ?? 0)
        }
        let plain = try rowSpread(makeSession(.bayer, width: width, height: height, noiseScale: 0, signal: banded))
        let corrected = try rowSpread(makeSession(
            .bayer, width: width, height: height, noiseScale: 0,
            banding: BandingCorrection(rows: offsets, columns: []), signal: banded,
        ))
        #expect(corrected < 0.2 * plain, "row spread \(corrected), was \(plain)")
    }

    // MARK: - Helpers

    /// `signal` is the scene per photosite (`level` by default), `noiseScale` scales the
    /// noise, and `spikes` overrides single photosites with a normalised value.
    func makeSession(
        _ sensor: SensorKind,
        width: Int,
        height: Int,
        noiseScale: Float = 1,
        asShot: SIMD3<Double> = SIMD3(1, 1, 1),
        gainMaps: [GainMap] = [],
        banding: BandingCorrection? = nil,
        profile: NoiseModel = DetailStageTests.noise,
        spikes: [(SIMD2<Int>, Float)] = [],
        signal: (Int, Int) -> Float = { _, _ in DetailStageTests.level },
    ) throws -> ImageSession {
        let layout: DecodedImage.Layout
        let channels: Int
        switch sensor {
        case .bayer:
            layout = .mosaic(CFAPattern(width: 2, height: 2, colors: [0, 1, 1, 2]))
            channels = 1
        case .xTrans:
            layout = .mosaic(CFAPattern(width: 6, height: 6, colors: [
                1, 1, 0, 1, 1, 2, 1, 1, 2, 1, 1, 0, 2, 0, 1, 0, 2, 1,
                1, 1, 2, 1, 1, 0, 1, 1, 0, 1, 1, 2, 0, 2, 1, 2, 0, 1,
            ]))
            channels = 1
        case .linear, .bitmap:
            layout = .linearRGB
            channels = 3
        }
        let black: Float = 512
        let white: Float = 16383
        // One black level per pattern position, as `SessionBuilder` reads them.
        let blackCount = if case let .mosaic(pattern) = layout {
            pattern.width * pattern.height
        } else {
            3
        }
        var random = SeededRandom(seed: 7)
        func raw(_ value: Float) -> UInt16 {
            UInt16(min(max(black + value * (white - black), 0), 65535).rounded())
        }
        var samples = (0 ..< width * height * channels).map { index in
            let value = signal((index / channels) % width, (index / channels) / width)
            let sigma = (Self.noise.a.x * value + Self.noise.b.x).squareRoot() * noiseScale
            return raw(value + sigma * random.gaussian())
        }
        for (point, value) in spikes {
            samples[(point.y * width + point.x) * channels] = raw(value)
        }
        var decoded = DecodedImage(
            width: width, height: height, layout: layout, samples: samples,
            blackLevels: [Float](repeating: black, count: blackCount), whiteLevel: white,
            asShotMultipliers: asShot, cameraToSRGB: [1, 0, 0, 0, 1, 0, 0, 0, 1], xyzToCamera: nil,
            orientation: 0, baselineExposure: 0,
            info: ImageInfo(
                url: URL(fileURLWithPath: "/synthetic.dng"), pixelSize: PixelSize(width: width, height: height),
                isRaw: true, sensorDescription: "synthetic",
            ),
        )
        decoded.noiseProfile = profile
        decoded.gainMaps = gainMaps
        decoded.banding = banding
        return try SessionBuilder(device: device, queue: queue, kernels: kernels).build(decoded)
    }

    /// One pyramid level read back as camera RGB.
    func readLevel(_ session: ImageSession, level: Int) throws -> [SIMD3<Float>] {
        let width = max(1, session.pyramid.width >> level)
        let height = max(1, session.pyramid.height >> level)
        return try readBack(session.pyramid, level: level, width: width, height: height)
    }

    func readBack(_ texture: any MTLTexture, level: Int, width: Int, height: Int) throws -> [SIMD3<Float>] {
        let commands = try #require(queue.makeCommandBuffer())
        let read = try encodeReadBack(texture, level: level, width: width, height: height, commands: commands)
        commands.commit()
        commands.waitUntilCompleted()
        return read()
    }

    /// Copies a level of `texture` out in `commands`; the result is read once they complete.
    func encodeReadBack(
        _ texture: any MTLTexture,
        level: Int = 0,
        width: Int,
        height: Int,
        commands: any MTLCommandBuffer,
    ) throws -> () -> [SIMD3<Float>] {
        let rowBytes = width * 8
        let buffer = try #require(device.makeBuffer(length: rowBytes * height, options: .storageModeShared))
        let blit = try #require(commands.makeBlitCommandEncoder())
        blit.copy(
            from: texture, sourceSlice: 0, sourceLevel: level, sourceOrigin: MTLOrigin(x: 0, y: 0, z: 0),
            sourceSize: MTLSize(width: width, height: height, depth: 1),
            to: buffer, destinationOffset: 0, destinationBytesPerRow: rowBytes,
            destinationBytesPerImage: rowBytes * height,
        )
        blit.endEncoding()
        return {
            let halves = buffer.contents().assumingMemoryBound(to: Float16.self)
            return (0 ..< width * height).map { index in
                SIMD3(Float(halves[index * 4]), Float(halves[index * 4 + 1]), Float(halves[index * 4 + 2]))
            }
        }
    }

    /// The stage's output texels, read back by the command buffer that rendered them: once it
    /// completes, a cached output may be reclaimed.
    func processAndRead(
        _ stage: DetailStage,
        _ session: ImageSession,
        _ recipe: EditRecipe,
        region: ImageRect = .full,
        outputSize: PixelSize? = nil,
        cache: Bool = true,
    ) throws -> (texels: [SIMD3<Float>], output: DetailStage.Output) {
        let commands = try #require(queue.makeCommandBuffer())
        let output = try #require(try stage.process(
            recipe, session: session, region: region, outputSize: outputSize ?? session.orientedSize,
            commands: commands, cache: cache,
        ))
        let texture = output.texture
        let read = try encodeReadBack(texture, width: texture.width, height: texture.height, commands: commands)
        commands.commit()
        commands.waitUntilCompleted()
        return (read(), output)
    }

    /// The whole image through the detail stage at full resolution.
    func processed(_ session: ImageSession, recipe: EditRecipe) throws -> [SIMD3<Float>] {
        try processAndRead(DetailStage(device: device, kernels: kernels), session, recipe).texels
    }

    func statistics(of pixels: [SIMD3<Float>]) -> (mean: SIMD3<Float>, deviation: SIMD3<Float>) {
        let count = Float(pixels.count)
        let mean = pixels.reduce(SIMD3<Float>.zero, +) / count
        let variance = pixels.reduce(SIMD3<Float>.zero) { $0 + ($1 - mean) * ($1 - mean) } / count
        return (mean, variance.squareRoot())
    }

    /// Stabilises and decomposes one level on the CPU, as the kernels do, and measures each
    /// scale's detail noise away from the borders.
    private func measureScaleNoise(_ session: ImageSession, level: Int) throws -> [SIMD3<Float>] {
        let width = max(1, session.pyramid.width >> level)
        let height = max(1, session.pyramid.height >> level)
        let a = session.noise.a
        let b = session.noise.b
        var current = try readLevel(session, level: level).map { value in
            let f = 2 * ((a * value + b).squareRoot() - b.squareRoot()) / a
            return SIMD3(
                (f.x + f.y + f.z) * 0.57735027,
                (f.x - f.z) * 0.70710678,
                (f.x - 2 * f.y + f.z) * 0.40824829,
            )
        }
        let weights: [Float] = [1, 4, 6, 4, 1].map { $0 / 16 }
        var sigmas: [SIMD3<Float>] = []
        for scale in 0 ..< DenoiseSettings.scaleCount {
            let step = 1 << scale
            var rows = current
            for y in 0 ..< height {
                for x in 0 ..< width {
                    var sum = SIMD3<Float>.zero
                    for i in -2 ... 2 {
                        let column = min(max(x + i * step, 0), width - 1)
                        sum += weights[i + 2] * current[y * width + column]
                    }
                    rows[y * width + x] = sum
                }
            }
            var coarse = rows
            var squares = SIMD3<Float>.zero
            var count: Float = 0
            let border = 2 * (step * 2 - 1) + 4
            for y in 0 ..< height {
                for x in 0 ..< width {
                    var sum = SIMD3<Float>.zero
                    for i in -2 ... 2 {
                        let row = min(max(y + i * step, 0), height - 1)
                        sum += weights[i + 2] * rows[row * width + x]
                    }
                    coarse[y * width + x] = sum
                    if x >= border, x < width - border, y >= border, y < height - border {
                        let detail = current[y * width + x] - sum
                        squares += detail * detail
                        count += 1
                    }
                }
            }
            sigmas.append((squares / count).squareRoot())
            current = coarse
        }
        return sigmas
    }
}

/// xorshift64* with Box–Muller, so tests are reproducible.
private struct SeededRandom {
    var state: UInt64

    init(seed: UInt64) {
        state = seed
    }

    mutating func next() -> UInt64 {
        state ^= state >> 12
        state ^= state << 25
        state ^= state >> 27
        return state &* 2_685_821_657_736_338_717
    }

    mutating func uniform() -> Float {
        Float(next() >> 40) / Float(1 << 24)
    }

    mutating func gaussian() -> Float {
        let u1 = max(uniform(), 1e-7)
        return (-2 * log(u1)).squareRoot() * cos(2 * .pi * uniform())
    }
}
