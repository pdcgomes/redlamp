import Foundation
import Metal
import RedlampEngineAPI
import simd
import Testing
@testable import RedlampEngine

/// Process 11: Texture, Clarity and sharpening read one ladder of the noise-reduced luminance
/// (`Ladder`, `docs/plans/2026-10-03-detail-decomposition-design.md`).
@Suite(.enabled(if: MTLCreateSystemDefaultDevice() != nil))
struct DetailDecompositionTests {
    let base: DetailStageTests

    init() throws {
        base = try DetailStageTests()
    }

    static func process(_ version: Int, _ edit: (inout EditRecipe) -> Void = { _ in }) -> EditRecipe {
        var recipe = DetailStageTests.untouched
        recipe.processVersion = version
        edit(&recipe)
        return recipe
    }

    /// Noise reduction, sharpening, Texture and Clarity.
    static let everyPass = process(11) { recipe in
        recipe[.noiseLuminance] = 40
        recipe[.noiseColor] = 30
        recipe[.sharpenAmount] = 60
        recipe[.texture] = 30
        recipe[.clarity] = 25
    }

    static func smooth(_ x: Int, _ y: Int) -> Float {
        Float(0.2 + 0.1 * sin(Double(x) / 3) * cos(Double(y) / 5))
    }

    static func blocks(_ x: Int, _ y: Int) -> Float {
        (x / 7 + y / 5).isMultiple(of: 2) ? 0.04 : 0.7
    }

    // MARK: - Texture

    /// The log luminance along row 128 of a 1024-wide render.
    func logRow(_ pixels: [SIMD3<Float>], width: Int = 1024) -> [Float] {
        (0 ..< width).map { log2(max(pixels[128 * width + $0].y, 1e-6)) }
    }

    func spread(_ logs: ArraySlice<Float>) -> Float {
        let mean = logs.reduce(0, +) / Float(logs.count)
        return (logs.map { ($0 - mean) * ($0 - mean) }.reduce(0, +) / Float(logs.count)).squareRoot()
    }

    /// A dark and a bright half 3.3 stops apart, with Texture-sized stripes (6 px, ±0.1 stops) on
    /// both. Process 10's Texture takes the edge for detail and puts a dark band on its dark side
    /// and a bright one on its bright side; process 11's limit leaves a fraction of them for the
    /// same boost of the stripes.
    @Test func `texture puts little halo along a strong edge`() throws {
        let width = 1024
        let edge = width / 2
        let session = try base.makeSession(.bayer, width: width, height: 256, noiseScale: 0) { x, _ in
            Float((x < edge ? 0.05 : 0.5) * pow(2, 0.1 * sin(2 * .pi * Double(x) / 6)))
        }
        let source = try logRow(base.readLevel(session, level: 0))
        func measure(_ version: Int) throws -> (dark: Float, bright: Float, boost: Float) {
            let output = try logRow(base.processed(session, recipe: Self.process(version) { $0[.texture] = 100 }))
            /// The mean shift over each 6 px period beside the edge, against the far field.
            func shift(_ columns: Range<Int>) -> Float {
                columns.map { output[$0] - source[$0] }.reduce(0, +) / Float(columns.count)
            }
            let far = shift(edge - 300 ..< edge - 156)
            let dark = (0 ..< 3).map { shift(edge - 6 * ($0 + 1) ..< edge - 6 * $0) - far }.min()!
            let farBright = shift(edge + 156 ..< edge + 300)
            let bright = (0 ..< 3).map { shift(edge + 6 * $0 ..< edge + 6 * ($0 + 1)) - farBright }.max()!
            let boost = log2(spread(output[edge - 300 ..< edge - 156]) / spread(source[edge - 300 ..< edge - 156]))
            return (dark, bright, boost)
        }
        let before = try measure(10)
        let after = try measure(11)
        print("texture beside the edge: process 10 \(before), process 11 \(after)")
        #expect(after.boost > 0.4, "stripes boosted by \(after.boost) stops")
        #expect(abs(after.dark) / after.boost < abs(before.dark) / before.boost / 3, "dark side")
        #expect(abs(after.bright) / after.boost < abs(before.bright) / before.boost / 1.5, "bright side")
    }

    @Test func `texture works on medium detail and not on large`() throws {
        func gain(period: Double, texture: Double) throws -> Float {
            let session = try base.makeSession(.bayer, width: 1024, height: 256, noiseScale: 0) { x, _ in
                Float(0.2 * pow(2, 0.5 * sin(2 * .pi * Double(x) / period)))
            }
            let output = try logRow(base.processed(session, recipe: Self.process(11) { $0[.texture] = texture }))
            let source = try logRow(base.readLevel(session, level: 0))
            return spread(output[128 ..< 896]) / spread(source[128 ..< 896])
        }
        #expect(try gain(period: 6, texture: 100) > 1.2)
        #expect(try gain(period: 6, texture: -100) < 0.85)
        #expect(try abs(gain(period: 128, texture: 100) - 1) < 0.05)
    }

    /// Texture reads the noise-reduced luminance, so for each stop it boosts texture by (noise-free
    /// stripes, without noise reduction) it puts back less of the noise noise reduction took out
    /// than process 10, which read the pyramid.
    @Test func `texture puts less noise back after noise reduction`() throws {
        let flat = try base.makeSession(.bayer, width: 768, height: 512)
        let stripes = try base.makeSession(.bayer, width: 1024, height: 256, noiseScale: 0) { x, _ in
            Float(0.2 * pow(2, 0.1 * sin(2 * .pi * Double(x) / 6)))
        }
        func recipe(_ version: Int, texture: Double) -> EditRecipe {
            Self.process(version) { recipe in
                recipe[.noiseLuminance] = 60
                recipe[.texture] = texture
            }
        }
        let denoised = try base.statistics(of: base.processed(flat, recipe: recipe(10, texture: 0))).deviation.y
        let source = try logRow(base.readLevel(stripes, level: 0))
        func perStop(_ version: Int) throws -> (noise: Float, boost: Float) {
            let noise = try base.statistics(of: base.processed(flat, recipe: recipe(version, texture: 100))).deviation.y
            let output = try logRow(base.processed(stripes, recipe: Self.process(version) { $0[.texture] = 100 }))
            let boost = log2(spread(output[128 ..< 896]) / spread(source[128 ..< 896]))
            return (log2(noise / denoised) / boost, boost)
        }
        let before = try perStop(10)
        let after = try perStop(11)
        print("noise growth (stops) per stop of texture after Luminance 60: process 10 \(before), process 11 \(after)")
        #expect(after.noise < before.noise * 0.8, "process 11 \(after), process 10 \(before)")
    }

    @Test func `a mask's texture only works inside it`() throws {
        let session = try base.makeSession(.bayer, width: 768, height: 256, noiseScale: 0) { x, _ in
            Float(0.2 * pow(2, 0.5 * sin(2 * .pi * Double(x) / 6)))
        }
        let recipe = Self.process(11) { $0.masks = [base.leftHalf(.localTexture, 100)] }
        let before = try logRow(base.readLevel(session, level: 0), width: 768)
        let after = try logRow(base.processed(session, recipe: recipe), width: 768)
        let inside = spread(after[64 ..< 300]) / spread(before[64 ..< 300])
        let outside = spread(after[468 ..< 704]) / spread(before[468 ..< 704])
        #expect(inside > 1.2, "inside \(inside)")
        #expect(abs(outside - 1) < 0.02, "outside \(outside)")
    }

    // MARK: - Clarity

    /// As `edge-aware clarity puts no bands along an edge`, in the ladder's luminance.
    @Test func `clarity puts no bands along an edge`() throws {
        let width = 1024
        let edge = width / 2
        let session = try base.makeSession(.bayer, width: width, height: 256, noiseScale: 0) { x, _ in
            Float((x < edge ? 0.05 : 0.5) * pow(2, 0.15 * sin(2 * .pi * Double(x) / 48)))
        }
        let source = try logRow(base.readLevel(session, level: 0))
        func measure(_ version: Int) throws -> (bright: Float, dark: Float, gain: Float) {
            let output = try logRow(base.processed(session, recipe: Self.process(version) { $0[.clarity] = 100 }))
            func shift(_ columns: Range<Int>) -> Float {
                columns.map { output[$0] - source[$0] }.reduce(0, +) / Float(columns.count)
            }
            let far = 124 ..< 316
            return (
                shift(edge + 4 ..< edge + 52) - shift(edge + 188 ..< edge + 380),
                shift(edge - 52 ..< edge - 4) - shift(far),
                spread(output[far]) / spread(source[far]),
            )
        }
        let perLevel = try measure(8)
        let ladder = try measure(11)
        print("clarity beside the edge: per level \(perLevel), process 11 \(ladder)")
        #expect(ladder.gain > 1.1, "stripes: \(ladder.gain)")
        let perStop = { (band: Float, gain: Float) in abs(band) / log2(gain) }
        #expect(perStop(ladder.bright, ladder.gain) < perStop(perLevel.bright, perLevel.gain) / 3, "\(ladder)")
        #expect(perStop(ladder.dark, ladder.gain) < perStop(perLevel.dark, perLevel.gain) / 3, "\(ladder)")
    }

    // MARK: - Sharpening

    /// The separator keeps only the ladder's detail that stands out of the noise, so on a flat
    /// patch sharpening leaves the noise as it was.
    @Test func `sharpening leaves flat noise as it was`() throws {
        let session = try base.makeSession(.bayer, width: 512, height: 384)
        let before = try base.statistics(of: base.readLevel(session, level: 0)).deviation
        for (detail, masking) in [(0.0, 0.0), (25, 0), (100, 0), (25, 100)] {
            let recipe = Self.process(11) { recipe in
                recipe[.sharpenAmount] = 100
                recipe[.sharpenDetail] = detail
                recipe[.sharpenMasking] = masking
            }
            let after = try base.statistics(of: base.processed(session, recipe: recipe)).deviation
            for channel in 0 ..< 3 {
                let ratio = after[channel] / before[channel]
                #expect(abs(ratio - 1) < 0.02, "Detail \(detail), Masking \(masking), channel \(channel): \(ratio)")
            }
        }
    }

    /// As `deconvolution restores a blurred edge better than unsharp masking`, on the ladder's
    /// separator.
    @Test func `deconvolution restores a blurred edge better than unsharp masking`() throws {
        let sigma = 1.2
        func step(_ x: Int, blurred: Bool) -> Float {
            let t = Double(x) + 0.5 - 256
            let edge = blurred ? 0.5 * (1 + erf(t / (sigma * 2.0.squareRoot()))) : (t > 0 ? 1 : 0)
            return Float(0.1 + 0.3 * edge)
        }
        let sharp = try base.readLevel(
            base.makeSession(.bayer, width: 512, height: 64, noiseScale: 0) { x, _ in step(x, blurred: false) },
            level: 0,
        )
        let soft = try base
            .makeSession(.bayer, width: 512, height: 64, noiseScale: 0) { x, _ in step(x, blurred: true) }
        func error(_ pixels: [SIMD3<Float>]) -> Float {
            let differences = (236 ... 276).map { pixels[32 * 512 + $0].y - sharp[32 * 512 + $0].y }
            return (differences.map { $0 * $0 }.reduce(0, +) / Float(differences.count)).squareRoot()
        }
        func sharpened(detail: Double) throws -> Float {
            try error(base.processed(soft, recipe: Self.process(11) { recipe in
                recipe[.sharpenAmount] = 100
                recipe[.sharpenRadius] = sigma / 0.8
                recipe[.sharpenDetail] = detail
            }))
        }
        let input = try error(base.readLevel(soft, level: 0))
        let unsharp = try sharpened(detail: 0)
        let deconvolved = try sharpened(detail: 100)
        #expect(unsharp < input, "unsharp \(unsharp), input \(input)")
        #expect(deconvolved < unsharp * 0.95, "deconvolved \(deconvolved), unsharp \(unsharp)")
    }

    // MARK: - Caches

    /// Every drag renders what a fresh stage renders; those the ladder serves make only the output.
    @Test func `drags render what a fresh stage renders`() throws {
        let session = try base.makeSession(.bayer, width: 512, height: 384, signal: Self.smooth)
        let stage = DetailStage(device: base.device, kernels: base.kernels)
        var recipe = Self.everyPass
        recipe.masks = [base.leftHalf(.localClarity, 40)]
        _ = try base.processAndRead(stage, session, recipe)
        let drags: [(ParameterID, Double, ladderServes: Bool)] = [
            (.texture, 60, true), (.clarity, -30, true), (.sharpenAmount, 120, true), (.sharpenDetail, 80, true),
            (.sharpenMasking, 40, true), (.sharpenRadius, 2, false), (.noiseLuminance, 55, false),
            (.texture, -40, true),
        ]
        for (parameter, value, ladderServes) in drags {
            recipe[parameter] = value
            let before = stage.allocated.count
            let cached = try base.processAndRead(stage, session, recipe).texels
            let fresh = try base.processAndRead(
                DetailStage(device: base.device, kernels: base.kernels),
                session,
                recipe,
            )
            let worst = zip(cached, fresh.texels).map { simd_abs($0 - $1).max() }.max() ?? 0
            #expect(worst == 0, "\(parameter): \(worst)")
            if ladderServes {
                #expect(stage.allocated.count - before == 1, "\(parameter) made more than its output")
            }
        }
    }

    /// Areas too large for their ladder keep the noise-reduced source: drags render what a fresh
    /// stage renders, whole and in tiles, and those that leave noise reduction alone make only the
    /// output once one has sized the scratch to their tiles.
    @Test(arguments: [false, true])
    func `drags over a large area render what a fresh stage renders`(tiled: Bool) throws {
        let session = try base.makeSession(.bayer, width: 1024, height: 768, signal: Self.smooth)
        let stage = DetailStage(device: base.device, kernels: base.kernels)
        stage.ladderCacheTexels = 0
        if tiled {
            stage.scratchBudget = 118 * 300_000
        }
        var recipe = Self.everyPass
        recipe.masks = [base.leftHalf(.localClarity, 40)]
        _ = try base.processAndRead(stage, session, recipe)
        #expect(stage.ladderCache.heldTextures.count == 1)
        let drags: [(ParameterID, Double, keepsSource: Bool)] = [
            (.texture, 60, true), (.clarity, -30, true), (.sharpenAmount, 120, true), (.sharpenMasking, 40, true),
            (.sharpenRadius, 2, false), (.noiseLuminance, 55, false), (.texture, -40, true),
        ]
        var settled = false
        for (parameter, value, keepsSource) in drags {
            recipe[parameter] = value
            let before = stage.allocated.count
            let cached = try base.processAndRead(stage, session, recipe).texels
            defer { settled = keepsSource }
            if tiled {
                #expect(stage.tileCount >= 2, "\(parameter): \(stage.tileCount) tile")
            }
            let fresh = try base.processAndRead(
                DetailStage(device: base.device, kernels: base.kernels),
                session,
                recipe,
            )
            let worst = zip(cached, fresh.texels).map { simd_abs($0 - $1).max() }.max() ?? 0
            #expect(worst == 0, "\(parameter): \(worst)")
            if keepsSource, settled || !tiled {
                #expect(stage.allocated.count - before == 1, "\(parameter) made more than its output")
            }
        }
    }

    // MARK: - Tiles and regions

    /// Tiles overlap by as much as the passes read, from scratch and from the caches, so they
    /// render exactly what one pass over the work area does.
    @Test func `tiled work areas render what one pass renders`() throws {
        var widest = Self.everyPass
        widest[.noiseLuminance] = 100
        widest[.sharpenRadius] = 3
        widest[.sharpenMasking] = 50
        var softened = Self.everyPass
        softened.masks = [base.leftHalf(.localSharpness, -100)]
        var unevenNoise = Self.everyPass
        unevenNoise.masks = [base.leftHalf(.localNoise, -100)]
        var newRadius = Self.everyPass
        newRadius[.sharpenRadius] = 1.5
        var newTexture = newRadius
        newTexture[.texture] = 70
        newTexture.masks = [base.leftHalf(.localTexture, 30)]
        // In order, so the last two find the ladder cached, then the ladder and the analysis.
        let recipes = [
            ("every pass", Self.everyPass), ("widest", widest), ("softened", softened),
            ("uneven noise", unevenNoise), ("every pass again", Self.everyPass), ("new Radius", newRadius),
            ("new Texture", newTexture),
        ]
        let region = ImageRect(x: 0.13, y: 0.21, width: 0.74, height: 0.69)
        for (scene, signal) in [("smooth", Self.smooth), ("blocks", Self.blocks)] {
            let session = try base.makeSession(.bayer, width: 961, height: 719, signal: signal)
            let size = session.orientedSize
            let regionSize = PixelSize(
                width: Int(region.width * Double(size.width)), height: Int(region.height * Double(size.height)),
            )
            for (area, outputSize) in [(ImageRect.full, size), (region, regionSize)] {
                let tiled = DetailStage(device: base.device, kernels: base.kernels)
                tiled.scratchBudget = 118 * 300_000
                var tileCounts: [Int] = []
                for (name, recipe) in recipes {
                    let whole = try base.processAndRead(
                        DetailStage(device: base.device, kernels: base.kernels), session, recipe, region: area,
                        outputSize: outputSize,
                    )
                    let tiles = try base.processAndRead(tiled, session, recipe, region: area, outputSize: outputSize)
                    tileCounts.append(tiled.tileCount)
                    let differing = EngineMemoryTests.differing(whole.texels, tiles.texels)
                    #expect(differing == 0, "\(scene), \(area == .full ? "full" : "region"), \(name): \(differing)")
                }
                // With the ladder cached the passes need fewer scratch textures, so larger tiles.
                #expect(tileCounts.prefix(4).allSatisfy { $0 >= 2 } && tileCounts.contains { $0 >= 4 }, "\(tileCounts)")
            }
        }
    }

    /// Tiles overlapping by a few texels render something else, so the test above would notice a
    /// halo that fell short, fresh and with the ladder cached.
    @Test func `a halo short of the passes' reach shows`() throws {
        let session = try base.makeSession(.bayer, width: 641, height: 479, signal: Self.blocks)
        var newRadius = Self.everyPass
        newRadius[.sharpenRadius] = 1.5
        newRadius.masks = [base.leftHalf(.localTexture, 30)]
        let work = DetailStage.WorkArea(level: 0, origin: .zero, size: SIMD2(641, 479))
        for (name, recipe, before) in [("every pass", Self.everyPass, nil), ("new Radius", newRadius, Self.everyPass)] {
            let whole = try base.processAndRead(
                DetailStage(device: base.device, kernels: base.kernels),
                session,
                recipe,
            )
            let tiled = DetailStage(device: base.device, kernels: base.kernels)
            tiled.scratchBudget = 118 * 200_000
            var ladder: LadderMeasures?
            if let before {
                _ = try base.processAndRead(tiled, session, before)
                let key = LadderKey(
                    session: ObjectIdentifier(session), work: work, denoise: DenoiseSettings(recipe: recipe),
                    local: LocalDetail(recipe: recipe),
                )
                ladder = LadderMeasures(ladder: tiled.ladderCache.ladder(key))
                #expect(ladder?.ladder != nil, "\(name): the ladder is cached")
            }
            let passes = try #require(DetailStage.passes(recipe, session: session, level: 0, masks: .none))
            let halo = passes.halo(level: 0, measures: nil, ladder: ladder)
            tiled.haloShortfall = halo - 4
            let tiles = try base.processAndRead(tiled, session, recipe)
            #expect(tiled.tileCount > 1, "\(name)")
            #expect(EngineMemoryTests.differing(whole.texels, tiles.texels) > 0, "\(name), halo \(halo)")
        }
    }

    /// A region at 1:1 carries enough margin that its texels are the full render's.
    @Test func `a region renders what the whole frame renders there`() throws {
        let (width, height) = (640, 480)
        let session = try base.makeSession(.bayer, width: width, height: height, signal: Self.smooth)
        var recipe = Self.everyPass
        recipe[.noiseLuminance] = 100
        recipe[.noiseColor] = 100
        recipe[.texture] = 100
        recipe[.clarity] = 100
        recipe[.sharpenRadius] = 3
        let stage = DetailStage(device: base.device, kernels: base.kernels)
        func render(
            _ region: ImageRect,
            _ size: PixelSize,
        ) throws -> (texels: [SIMD3<Float>], x: Int, y: Int, width: Int) {
            let (texels, output) = try base.processAndRead(
                stage, session, recipe, region: region, outputSize: size, cache: false,
            )
            let x = Int((output.area.x * Float(width)).rounded()), y = Int((output.area.y * Float(height)).rounded())
            return (texels, x, y, output.texture.width)
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
}
