import Foundation
import Metal
import RedlampEngineAPI
import simd
import Testing
@testable import RedlampEngine

/// Memory budgets for the engine's caches, so later work can't quietly undo them (AUD-03).
@Suite(.enabled(if: MTLCreateSystemDefaultDevice() != nil))
struct EngineMemoryTests {
    /// What the detail stage may keep resident once a render has finished.
    static let idleBudget = 64 << 20
    /// The detail stage's scratch textures during any render.
    static let scratchBudget = 720 << 20

    let helpers: DetailStageTests

    init() throws {
        helpers = try DetailStageTests()
    }

    /// Noise reduction, sharpening, Texture and Clarity: every pass and cache of the stage.
    static let everyPass: EditRecipe = {
        var recipe = EditRecipe()
        recipe[.noiseLuminance] = 40
        recipe[.noiseColor] = 30
        recipe[.sharpenAmount] = 60
        recipe[.texture] = 30
        recipe[.clarity] = 25
        return recipe
    }()

    /// Every pass, with a mask whose negative Sharpness softens: the most scratch textures.
    var softened: EditRecipe {
        var recipe = Self.everyPass
        recipe.masks = [helpers.leftHalf(.localSharpness, -100)]
        return recipe
    }

    /// A smooth scene, and one of hard-edged blocks whose filters' reach shows at once.
    static func smooth(_ x: Int, _ y: Int) -> Float {
        Float(0.2 + 0.1 * sin(Double(x) / 3) * cos(Double(y) / 5))
    }

    static func blocks(_ x: Int, _ y: Int) -> Float {
        (x / 7 + y / 5).isMultiple(of: 2) ? 0.04 : 0.7
    }

    func render(
        _ stage: DetailStage,
        _ session: ImageSession,
        _ recipe: EditRecipe,
        region: ImageRect = .full,
        outputSize: PixelSize? = nil,
    ) throws -> any MTLTexture {
        let commands = try #require(helpers.queue.makeCommandBuffer())
        let output = try #require(try stage.process(
            recipe, session: session, region: region, outputSize: outputSize ?? session.orientedSize,
            commands: commands,
        ))
        commands.commit()
        commands.waitUntilCompleted()
        return output.texture
    }

    static func residentBytes(_ stage: DetailStage) -> Int {
        stage.heldTextures.filter { $0.setPurgeableState(.keepCurrent) == .nonVolatile }
            .reduce(0) { $0 + $1.allocatedSize }
    }

    /// Resident bytes once no command buffer holds the stage's textures and it has parked them.
    static func settledResidentBytes(_ stage: DetailStage) async throws -> Int {
        for _ in 0 ..< 150 where !stage.residency.isParked {
            try await Task.sleep(for: .milliseconds(20))
        }
        return residentBytes(stage)
    }

    /// Texels that differ; comparing the arrays themselves would describe their difference.
    static func differing(_ first: [SIMD3<Float>], _ second: [SIMD3<Float>]) -> Int {
        zip(first, second).count(where: { $0 != $1 }) + abs(first.count - second.count)
    }

    /// The output, sharpening and ladder caches.
    static func cachedTextures(_ stage: DetailStage) -> [any MTLTexture] {
        stage.sharpenCache.heldTextures + stage.ladderCache.heldTextures + stage.cachedOutputs
    }

    static func scratchBytes(_ stage: DetailStage) -> Int {
        let cached = Set(cachedTextures(stage).map(ObjectIdentifier.init))
        return stage.heldTextures.filter { !cached.contains(ObjectIdentifier($0)) }.reduce(0) { $0 + $1.allocatedSize }
    }

    /// Bytes the stage allocated during `body` besides the output, sharpening and ladder caches,
    /// all alive until its command buffer completes.
    func scratchAllocated(_ stage: DetailStage, _ body: () throws -> Void) rethrows -> Int {
        let before = stage.allocated.bytes
        try body()
        let cached = Self.cachedTextures(stage).reduce(0) { $0 + $1.allocatedSize }
        return stage.allocated.bytes - before - cached
    }

    // MARK: - Between renders

    @Test func `the detail stage keeps little resident between renders`() async throws {
        let session = try helpers.makeSession(.bayer, width: 6000, height: 4000)
        let stage = DetailStage(device: helpers.device, kernels: helpers.kernels)
        _ = try render(stage, session, Self.everyPass)
        let held = stage.heldTextures.reduce(0) { $0 + $1.allocatedSize }
        let resident = try await Self.settledResidentBytes(stage)
        #expect(resident <= Self.idleBudget, "\(resident >> 20) MB of \(held >> 20) MB resident after a 1:1 render")
    }

    /// A render that fails after the stage encoded into its command buffer drops the buffer
    /// uncommitted. The engine abandons it; one dropped without that stops counting once it is
    /// released.
    @Test func `a dropped command buffer leaves nothing resident`() async throws {
        let session = try helpers.makeSession(.bayer, width: 640, height: 480, signal: Self.smooth)
        for abandons in [true, false] {
            let stage = DetailStage(device: helpers.device, kernels: helpers.kernels)
            // Released at the end of the pool, not whenever the task's pool drains.
            try autoreleasepool {
                let commands = try #require(helpers.queue.makeCommandBuffer())
                _ = try stage.process(
                    Self.everyPass, session: session, region: .full, outputSize: session.orientedSize,
                    commands: commands,
                )
                if abandons {
                    stage.abandon(commands)
                }
            }
            if !abandons {
                var changed = Self.everyPass
                changed[.sharpenAmount] = 90
                _ = try render(stage, session, changed)
            }
            let resident = try await Self.settledResidentBytes(stage)
            #expect(stage.residency.isParked, "abandoned: \(abandons)")
            #expect(resident <= Self.idleBudget, "abandoned: \(abandons): \(resident >> 20) MB resident")
            if abandons {
                // Nothing it cached from the abandoned buffer, which never ran, is read.
                let again = try helpers.processAndRead(stage, session, Self.everyPass)
                let fresh = try helpers.processAndRead(
                    DetailStage(device: helpers.device, kernels: helpers.kernels), session, Self.everyPass,
                )
                #expect(Self.differing(again.texels, fresh.texels) == 0)
            }
        }
    }

    /// A command buffer that fails on the GPU leaves its textures unwritten: the engine has the
    /// stage forget what it cached from the buffer, as it does for one that never ran.
    @Test func `a command buffer that failed on the GPU leaves nothing cached`() throws {
        let session = try helpers.makeSession(.bayer, width: 640, height: 480, signal: Self.smooth)
        let stage = DetailStage(device: helpers.device, kernels: helpers.kernels)
        var clarity = DetailStageTests.untouched
        clarity[.clarity] = 25
        // An earlier render's output, which the failure must not take with it.
        _ = try render(stage, session, clarity)
        let kept = Set((stage.cachedOutputs + stage.sharpenCache.heldTextures).map(ObjectIdentifier.init))
        let commands = try #require(helpers.queue.makeCommandBuffer())
        _ = try stage.process(
            Self.everyPass, session: session, region: .full, outputSize: session.orientedSize, commands: commands,
        )
        commands.commit()
        commands.waitUntilCompleted()
        stage.forget(commands)
        let cached = Set((stage.cachedOutputs + stage.sharpenCache.heldTextures).map(ObjectIdentifier.init))
        #expect(cached == kept)
    }

    /// A command buffer can take the address of an earlier one that has been released; what the
    /// stage cached from the earlier one is not the later one's to forget.
    @Test func `a failed command buffer at an earlier one's address leaves its cache alone`() throws {
        let session = try helpers.makeSession(.bayer, width: 640, height: 480, signal: Self.smooth)
        let stage = DetailStage(device: helpers.device, kernels: helpers.kernels)
        var clarity = DetailStageTests.untouched
        clarity[.clarity] = 25
        let earlier = try autoreleasepool {
            let commands = try #require(helpers.queue.makeCommandBuffer())
            _ = try stage.process(
                clarity, session: session, region: .full, outputSize: session.orientedSize, commands: commands,
            )
            let handled = DispatchSemaphore(value: 0)
            commands.addCompletedHandler { _ in handled.signal() }
            commands.commit()
            handled.wait()
            return ObjectIdentifier(commands)
        }
        let kept = Set((stage.cachedOutputs + stage.sharpenCache.heldTextures).map(ObjectIdentifier.init))
        var reused: (any MTLCommandBuffer)?
        for _ in 0 ..< 1000 where reused == nil {
            try autoreleasepool {
                let commands = try #require(helpers.queue.makeCommandBuffer())
                if ObjectIdentifier(commands) == earlier {
                    reused = commands
                }
            }
        }
        let commands = try #require(reused, "no command buffer took the earlier one's address")
        _ = try stage.process(
            Self.everyPass, session: session, region: .full, outputSize: session.orientedSize, commands: commands,
        )
        commands.commit()
        commands.waitUntilCompleted()
        stage.forget(commands)
        let cached = Set((stage.cachedOutputs + stage.sharpenCache.heldTextures).map(ObjectIdentifier.init))
        #expect(cached == kept)
    }

    /// Textures an encoded command buffer uses stay resident until it completes, however many
    /// others complete meanwhile.
    @Test func `textures stay resident while a command buffer using them is in flight`() async throws {
        let session = try helpers.makeSession(.bayer, width: 640, height: 480, signal: Self.smooth)
        let stage = DetailStage(device: helpers.device, kernels: helpers.kernels)
        let pending = try #require(helpers.queue.makeCommandBuffer())
        _ = try stage.process(
            Self.everyPass, session: session, region: .full, outputSize: session.orientedSize, commands: pending,
        )
        let used = stage.heldTextures
        var changed = Self.everyPass
        changed[.sharpenAmount] = 90
        _ = try render(stage, session, changed)
        try await Task.sleep(for: .seconds(1))
        #expect(!stage.residency.isParked)
        #expect(used.allSatisfy { $0.setPurgeableState(.keepCurrent) == .nonVolatile })
        pending.commit()
        await pending.completed()
        let resident = try await Self.settledResidentBytes(stage)
        #expect(resident <= Self.idleBudget, "\(resident >> 20) MB resident")
    }

    // MARK: - During a render

    /// A whole 24 MP frame at 1:1 is processed in tiles, so the scratch textures stay the size of
    /// a tile; the cached output and sharpening analysis cover the frame, 18 bytes a texel.
    @Test func `the detail stage's memory during a 1:1 render is bounded`() throws {
        let session = try helpers.makeSession(.bayer, width: 6000, height: 4000)
        let stage = DetailStage(device: helpers.device, kernels: helpers.kernels)
        let allocated = try scratchAllocated(stage) { _ = try render(stage, session, softened) }
        let scratch = Self.scratchBytes(stage)
        let total = stage.heldTextures.reduce(0) { $0 + $1.allocatedSize }
        #expect(allocated <= Self.scratchBudget, "scratch allocated during the render: \(allocated >> 20) MB")
        #expect(scratch <= Self.scratchBudget, "scratch \(scratch >> 20) MB")
        #expect(total <= 1200 << 20, "\(total >> 20) MB in all")
    }

    /// Every scratch texture is made once, the size of the grid's largest tile, however many
    /// tiles there are.
    @Test func `a grid of tiles makes each scratch texture once`() throws {
        let session = try helpers.makeSession(.bayer, width: 6000, height: 4000)
        let stage = DetailStage(device: helpers.device, kernels: helpers.kernels)
        stage.scratchBudget = 118 * 1_500_000
        let recipe = softened
        let work = DetailStage.WorkArea(level: 0, origin: .zero, size: SIMD2(6000, 4000))
        let tiles = try DetailStage.tiles(
            work, halo: passes(session, recipe).halo(level: 0, measures: nil),
            limit: stage.tileLimit(passes(session, recipe), measures: nil),
        )
        #expect(Set(tiles.map(\.interior.origin.x)).count >= 3 && Set(tiles.map(\.interior.origin.y)).count >= 3)
        let allocated = try scratchAllocated(stage) { _ = try render(stage, session, recipe) }
        #expect(stage.tileCount == tiles.count)
        #expect(allocated <= stage.scratchBudget, "\(allocated >> 20) MB for \(tiles.count) tiles")
    }

    /// The tile limit counts the scratch textures the passes use, so it must name every one.
    @Test func `the scratch slots a render uses are the ones its passes count`() throws {
        let session = try helpers.makeSession(.bayer, width: 640, height: 480, signal: Self.smooth)
        var sharpenOnly = DetailStageTests.untouched
        sharpenOnly[.sharpenAmount] = 60
        var noiseOnly = DetailStageTests.untouched
        noiseOnly[.noiseLuminance] = 40
        var contrastOnly = DetailStageTests.untouched
        contrastOnly[.clarity] = 25
        var unevenNoise = Self.everyPass
        unevenNoise.masks = [helpers.leftHalf(.localNoise, -100)]
        let recipes = [
            ("every pass", Self.everyPass), ("softened", softened), ("sharpening", sharpenOnly), ("noise", noiseOnly),
            ("Clarity", contrastOnly), ("uneven noise", unevenNoise),
        ]
        for (name, recipe) in recipes {
            let predicted = try passes(session, recipe).scratchSlots(measures: nil)
            let stage = DetailStage(device: helpers.device, kernels: helpers.kernels)
            stage.scratchBudget = 150_000 * predicted.reduce(0) { $0 + $1.bytesPerTexel }
            _ = try render(stage, session, recipe)
            #expect(stage.tileCount > 1, "\(name)")
            #expect(stage.scratchSlots == predicted, "\(name)")
        }
    }

    /// A 24 MP frame at 1:1 after its Fit view, then a new Amount, as the editor renders them:
    /// as few tiles as the scratch the passes use allows, since each tile costs a little. Process
    /// 10: at process 11 the frame keeps its noise-reduced source out of the scratch budget
    /// (`DetailDecompositionTests`).
    @Test func `a 24 MP frame at 1:1 takes as few tiles as its passes' scratch allows`() throws {
        let session = try helpers.makeSession(.bayer, width: 6000, height: 4000)
        let stage = DetailStage(device: helpers.device, kernels: helpers.kernels)
        var recipe = Self.everyPass
        recipe.processVersion = 10
        _ = try render(stage, session, recipe, outputSize: PixelSize(width: 3000, height: 2000))
        _ = try render(stage, session, recipe)
        #expect(stage.tileCount == 4)
        var changed = recipe
        changed[.sharpenAmount] = 90
        _ = try render(stage, session, changed)
        #expect(stage.tileCount == 4)
        let scratch = Self.scratchBytes(stage)
        #expect(scratch <= Self.scratchBudget, "scratch \(scratch >> 20) MB")
    }

    /// A 20 MP view with noise reduction alone (few textures, so large tiles), then every pass
    /// (more textures, so smaller tiles), a noise drag with the analysis cached and a new Radius:
    /// textures made for larger tiles are not reused for smaller ones, which would take the
    /// scratch over the budget.
    @Test func `scratch made for larger tiles is not reused past the budget`() throws {
        let session = try helpers.makeSession(.bayer, width: 5400, height: 3700)
        let stage = DetailStage(device: helpers.device, kernels: helpers.kernels)
        var noiseOnly = DetailStageTests.untouched
        noiseOnly[.noiseLuminance] = 40
        var noise = Self.everyPass
        noise[.noiseLuminance] = 60
        var radius = noise
        radius[.sharpenRadius] = 1.5
        let recipes = [("noise alone", noiseOnly), ("every pass", Self.everyPass), ("noise", noise), ("radius", radius)]
        for (name, recipe) in recipes {
            _ = try render(stage, session, recipe)
            let scratch = Self.scratchBytes(stage)
            #expect(scratch <= Self.scratchBudget, "\(name), \(stage.tileCount) tiles: scratch \(scratch >> 20) MB")
        }
    }

    /// A tiled frame and a differently shaped area that fits in one pass, rendered in turn, as an
    /// export's tiles are between interactive renders: the textures are made for the first two.
    /// The area goes first, since the frame's render would serve it.
    @Test func `alternating work areas reuse the scratch textures`() throws {
        let session = try helpers.makeSession(.bayer, width: 4000, height: 3000)
        let stage = DetailStage(device: helpers.device, kernels: helpers.kernels)
        stage.scratchBudget = 118 * 3_000_000
        let wide = ImageRect(x: 0.1, y: 0.2, width: 0.475, height: 1250.0 / 3000)
        let wideSize = PixelSize(width: 1900, height: 1250)
        func both() throws {
            _ = try render(stage, session, Self.everyPass, region: wide, outputSize: wideSize)
            _ = try render(stage, session, Self.everyPass)
        }
        try both()
        let before = stage.allocated.count
        var changed = Self.everyPass
        for amount in [70.0, 80] {
            changed[.sharpenAmount] = amount
            _ = try render(stage, session, changed, region: wide, outputSize: wideSize)
            _ = try render(stage, session, changed)
        }
        // Each render makes its output and nothing else.
        #expect(stage.allocated.count - before == 4)
    }

    /// A Noise drag at Fit, a Before/After pan at 1:1 and an export's tiles write over the
    /// textures the stage let go of: once each has made its first few, they allocate nothing.
    @Test func `drags, a Before/After pan and still tiles recycle the stage's textures`() throws {
        let session = try helpers.makeSession(.bayer, width: 6000, height: 4000, signal: Self.smooth)
        let stage = DetailStage(device: helpers.device, kernels: helpers.kernels)
        func allocations(_ ticks: Int, warm: Int, _ tick: (Int) throws -> Void) rethrows -> Int {
            for index in 0 ..< warm {
                try tick(index)
            }
            let before = stage.allocated.count
            for index in warm ..< ticks {
                try tick(index)
            }
            return stage.allocated.count - before
        }
        var dragged = Self.everyPass
        let drag = try allocations(12, warm: 4) { index in
            dragged[.noiseLuminance] = 40 + Double(index)
            _ = try render(stage, session, dragged, outputSize: PixelSize(width: 2250, height: 1500))
        }
        var original = EditRecipe()
        original[.sharpenAmount] = 40
        original[.noiseColor] = 25
        let pan = try allocations(24, warm: 8) { index in
            let region = ImageRect(x: 0.05 + 0.02 * Double(index), y: 0.3, width: 2560.0 / 6000, height: 0.36)
            let view = PixelSize(width: 2560, height: 1440)
            _ = try render(stage, session, Self.everyPass, region: region, outputSize: view)
            _ = try render(stage, session, original, region: region, outputSize: view)
        }
        let tile = 2048
        let origins = stride(from: 0, to: 4000, by: tile).flatMap { y in
            stride(from: 0, to: 6000, by: tile).map { SIMD2(x: $0, y: y) }
        }
        let tiles = try allocations(2 * origins.count, warm: origins.count) { index in
            let origin = origins[index % origins.count]
            let size = PixelSize(width: min(tile, 6000 - origin.x), height: min(tile, 4000 - origin.y))
            let region = ImageRect(
                x: Double(origin.x) / 6000, y: Double(origin.y) / 4000,
                width: Double(size.width) / 6000, height: Double(size.height) / 4000,
            )
            let commands = try #require(helpers.queue.makeCommandBuffer())
            _ = try #require(try stage.process(
                Self.everyPass, session: session, region: region, outputSize: size, commands: commands, cache: false,
            ))
            commands.commit()
            commands.waitUntilCompleted()
        }
        #expect(drag == 0, "a Noise drag made \(drag) textures")
        #expect(pan == 0, "a Before/After pan made \(pan) textures")
        #expect(tiles == 0, "a still's tiles made \(tiles) textures")
    }

    /// The largest photos at 1:1, then a smaller photo: the scratch textures follow the photo
    /// open now.
    @Test func `a 60 MP frame stays within the scratch budget and a smaller photo shrinks it`() throws {
        let stage = DetailStage(device: helpers.device, kernels: helpers.kernels)
        do {
            let large = try helpers.makeSession(.bayer, width: 9504, height: 6336)
            let allocated = try scratchAllocated(stage) { _ = try render(stage, large, softened) }
            #expect(allocated <= Self.scratchBudget, "\(allocated >> 20) MB allocated")
            #expect(Self.scratchBytes(stage) <= Self.scratchBudget)
        }
        let small = try helpers.makeSession(.bayer, width: 4000, height: 3000)
        _ = try render(stage, small, Self.everyPass, outputSize: PixelSize(width: 2000, height: 1500))
        let scratch = Self.scratchBytes(stage)
        #expect(scratch < 400 << 20, "\(scratch >> 20) MB of scratch after opening a 12 MP photo")
    }

    // MARK: - Tiles

    func passes(_ session: ImageSession, _ recipe: EditRecipe) throws -> DetailStage.Passes {
        try #require(DetailStage.passes(recipe, session: session, level: 0, masks: .none))
    }

    var tiledRecipes: [(String, EditRecipe)] {
        var widest = Self.everyPass
        widest[.noiseLuminance] = 100
        widest[.sharpenRadius] = 3
        widest[.sharpenMasking] = 50
        var unevenNoise = Self.everyPass
        unevenNoise.masks = [helpers.leftHalf(.localNoise, -100)]
        var newAmount = Self.everyPass
        newAmount[.sharpenAmount] = 90
        var newRadius = newAmount
        newRadius[.sharpenRadius] = 1.5
        // In order, so the last two find the analysis and then the separation cached. Process 10,
        // whose passes still tile with the analysis cached; process 11's tiles are tested in
        // `DetailDecompositionTests`.
        let recipes = [
            ("every pass", Self.everyPass), ("widest", widest), ("softened", softened), ("uneven noise", unevenNoise),
            ("every pass again", Self.everyPass), ("new Amount", newAmount), ("new Radius", newRadius),
        ]
        return recipes.map { name, recipe in
            var recipe = recipe
            recipe.processVersion = 10
            return (name, recipe)
        }
    }

    /// Tiles overlap by as much as the passes read around a texel, so they render exactly what
    /// one pass over the work area does, including from the sharpening caches: for smooth and
    /// hard-edged scenes, an odd size, and a region away from the photo's corner.
    @Test func `tiled work areas render what one pass renders`() throws {
        let region = ImageRect(x: 0.13, y: 0.21, width: 0.74, height: 0.69)
        for (scene, signal) in [("smooth", Self.smooth), ("blocks", Self.blocks)] {
            let session = try helpers.makeSession(.bayer, width: 961, height: 719, signal: signal)
            let size = session.orientedSize
            let regionSize = PixelSize(
                width: Int(region.width * Double(size.width)), height: Int(region.height * Double(size.height)),
            )
            for (area, outputSize) in [(ImageRect.full, size), (region, regionSize)] {
                let tiled = DetailStage(device: helpers.device, kernels: helpers.kernels)
                tiled.scratchBudget = 118 * 300_000
                var tileCounts: [Int] = []
                for (name, recipe) in tiledRecipes {
                    let whole = try helpers.processAndRead(
                        DetailStage(device: helpers.device, kernels: helpers.kernels), session, recipe, region: area,
                        outputSize: outputSize,
                    )
                    let tiles = try helpers.processAndRead(tiled, session, recipe, region: area, outputSize: outputSize)
                    tileCounts.append(tiled.tileCount)
                    let differing = Self.differing(whole.texels, tiles.texels)
                    #expect(differing == 0, "\(scene), \(area == .full ? "full" : "region"), \(name): \(differing)")
                }
                #expect(tileCounts.allSatisfy { $0 >= 2 } && tileCounts.contains { $0 >= 4 }, "\(tileCounts)")
            }
        }
    }

    /// Tiles overlapping by less than the passes read render something else, so the test above
    /// would notice a halo that fell short. The filters' farthest taps weigh too little to show
    /// in half floats a few texels short; softening's blur of the source shows 32 short. With the
    /// sharpening analysis or separation cached, the tiles need less, and still all of it.
    @Test func `a halo short of the passes' reach shows`() throws {
        let session = try helpers.makeSession(.bayer, width: 641, height: 479, signal: Self.blocks)
        let recipes = tiledRecipes
        let cases: [(name: String, recipe: EditRecipe, before: EditRecipe?, halved: Bool)] = [
            (recipes[0].0, recipes[0].1, nil, true), (recipes[1].0, recipes[1].1, nil, true),
            (recipes[2].0, recipes[2].1, nil, false),
            (recipes[5].0, recipes[5].1, recipes[0].1, true), (recipes[6].0, recipes[6].1, recipes[0].1, true),
        ]
        for (name, recipe, before, halved) in cases {
            let whole = try helpers.processAndRead(
                DetailStage(device: helpers.device, kernels: helpers.kernels), session, recipe,
            )
            let tiled = DetailStage(device: helpers.device, kernels: helpers.kernels)
            tiled.scratchBudget = 118 * 200_000
            // Sharpening's caches alone: the kept noise-reduced source's halo is tested in
            // `DetailStageTests`.
            tiled.ladderCacheTexels = 0
            var measures: SharpenMeasures?
            if let before {
                _ = try helpers.processAndRead(tiled, session, before)
                let sigma = try #require(SharpenSettings(recipe: recipe).sigma(atLevel: 0))
                let work = DetailStage.WorkArea(level: 0, origin: .zero, size: SIMD2(641, 479))
                measures = SharpenMeasures(
                    analysis: tiled.sharpenCache.analysis(session, work, sigma: sigma),
                    separation: tiled.sharpenCache.separation(session, work),
                )
                #expect(measures?.separation != nil)
            }
            let halo = try passes(session, recipe).halo(level: 0, measures: measures)
            tiled.haloShortfall = halved ? halo / 2 : 32
            let tiles = try helpers.processAndRead(tiled, session, recipe)
            #expect(Self.differing(whole.texels, tiles.texels) > 0, "\(name), halo \(halo)")
        }
    }

    /// With the sharpening analysis cached and Clarity reading the texel itself, the tiles overlap
    /// by the one texel Masking's gradient reads; a texel short shows on an odd-sized area whose
    /// gradients cross Masking's threshold everywhere.
    @Test func `a halo one texel short shows`() throws {
        let session = try helpers.makeSession(.bayer, width: 641, height: 479, signal: Self.smooth)
        var before = DetailStageTests.untouched
        // Process 10: process 11 reads its cached ladder at the texel too, so it needs no tiles.
        before.processVersion = 10
        before[.sharpenAmount] = 40
        before[.sharpenMasking] = 50
        before[.clarity] = 25
        var recipe = before
        recipe[.sharpenAmount] = 80
        let whole = try helpers.processAndRead(
            DetailStage(device: helpers.device, kernels: helpers.kernels), session, recipe,
        )
        for shortfall in [0, 1] {
            let tiled = DetailStage(device: helpers.device, kernels: helpers.kernels)
            tiled.scratchBudget = 118 * 100_000
            _ = try helpers.processAndRead(tiled, session, before)
            let measures = SharpenMeasures(analysis: tiled.sharpenCache.heldTextures.first)
            #expect(try passes(session, recipe).halo(level: 0, measures: measures) == 1)
            tiled.haloShortfall = shortfall
            let tiles = try helpers.processAndRead(tiled, session, recipe)
            #expect(tiled.tileCount > 1)
            let differing = Self.differing(whole.texels, tiles.texels)
            #expect(shortfall == 0 ? differing == 0 : differing > 0, "\(shortfall) short: \(differing)")
        }
    }

    /// Dragging Amount over a frame larger than a tile reads only the cached analysis: no tiles,
    /// no scratch, the output alone.
    @Test func `an Amount drag over a large area runs the apply pass alone`() async throws {
        let session = try helpers.makeSession(.bayer, width: 1280, height: 960, signal: Self.blocks)
        var recipe = DetailStageTests.untouched
        recipe[.sharpenAmount] = 60
        let stage = DetailStage(device: helpers.device, kernels: helpers.kernels)
        stage.scratchBudget = 118 * 400_000
        _ = try render(stage, session, recipe)
        _ = try await Self.settledResidentBytes(stage)
        let cached = Set(Self.cachedTextures(stage).map(ObjectIdentifier.init))
        let scratch = stage.heldTextures.filter { !cached.contains(ObjectIdentifier($0)) }
        #expect(!scratch.isEmpty)

        recipe[.sharpenAmount] = 90
        let before = stage.allocated.count
        let commands = try #require(helpers.queue.makeCommandBuffer())
        let output = try #require(try stage.process(
            recipe, session: session, region: .full, outputSize: session.orientedSize, commands: commands,
        ))
        #expect(stage.allocated.count - before == 1)
        #expect(scratch.allSatisfy { $0.setPurgeableState(.keepCurrent) == .volatile }, "scratch was used")
        let read = try helpers.encodeReadBack(
            output.texture, width: output.texture.width, height: output.texture.height, commands: commands,
        )
        commands.commit()
        await commands.completed()
        let fresh = try helpers.processAndRead(
            DetailStage(device: helpers.device, kernels: helpers.kernels),
            session,
            recipe,
        )
        #expect(Self.differing(read(), fresh.texels) == 0)
    }

    // MARK: - Closed photos

    static let closed = EngineSmokeTests.fixtures.first { $0.lastPathComponent == "_DSC0009.ARW" }
    static let next = EngineSmokeTests.fixtures.first { $0.lastPathComponent == "DSC_0750.NEF" }

    /// A retouched, masked photo seen at Fit and 1:1, then another photo opened and rendered: once
    /// the session cache lets go of the first, nothing keeps it or its retouched copy.
    @Test(.enabled(if: EngineSmokeTests.canRender && closed != nil && next != nil))
    func `closed photos are freed`() async throws {
        let engine = try RedlampEngine()
        let closed = try #require(Self.closed)
        weak var photo: ImageSession?
        weak var retouched: ImageSession?
        do {
            let info = try await engine.open(closed)
            var recipe = try ProcessStabilityTests.retouchEdit(process: EditRecipe.currentProcessVersion)
            recipe.spots.append(RetouchSpot(
                mode: .remove, center: ImagePoint(x: 0.7, y: 0.3), source: ImagePoint(x: 0.7, y: 0.3), radius: 0.03,
            ))
            try await Self.frame(engine, recipe)
            _ = try await ProcessStabilityTests.measure(engine, info: info, recipe: recipe)
            photo = engine.currentSession()
            retouched = engine.retouch.retouchedSessions.last
        }
        #expect(photo != nil && retouched != nil)
        _ = try await engine.open(#require(Self.next))
        try await Self.frame(engine, EditRecipe())
        engine.sessions.invalidate(closed)
        // A retouched copy's maps are made in the background after its frame.
        for _ in 0 ..< 150 where photo != nil || retouched != nil {
            engine.renderQueue.sync {}
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(photo == nil)
        #expect(retouched == nil)
    }

    /// The photo open now, fitted in a canvas.
    static func frame(_ engine: RedlampEngine, _ recipe: EditRecipe) async throws {
        var frames = engine.frames().makeAsyncIterator()
        engine.render(RenderRequest(recipe: recipe, targetSize: PixelSize(width: 1600, height: 1000), generation: 1))
        let frame = try #require(await frames.next())
        try #require(frame.generation == 1)
    }

    // MARK: - Reclaimed textures

    /// The system may empty the stage's textures between renders; it then renders them again.
    @Test func `a reclaimed stage renders what a fresh one does`() async throws {
        let session = try helpers.makeSession(.bayer, width: 640, height: 480, signal: Self.smooth)
        let stage = DetailStage(device: helpers.device, kernels: helpers.kernels)
        _ = try render(stage, session, Self.everyPass)
        // The same edit is a cached output; a new Amount reuses the cached sharpening analysis.
        var changedAmount = Self.everyPass
        changedAmount[.sharpenAmount] = 90
        for recipe in [Self.everyPass, changedAmount] {
            _ = try await Self.settledResidentBytes(stage)
            // Held here, so new textures can't take their addresses.
            let reclaimedTextures = stage.heldTextures
            for texture in reclaimedTextures {
                texture.setPurgeableState(.volatile)
                texture.setPurgeableState(.empty)
            }
            let reclaimed = try helpers.processAndRead(stage, session, recipe)
            #expect(!reclaimedTextures.contains { $0 === reclaimed.output.texture })
            #expect(stage.sharpenCache.heldTextures.contains { texture in
                !reclaimedTextures.contains { $0 === texture }
            })
            let fresh = try helpers.processAndRead(
                DetailStage(device: helpers.device, kernels: helpers.kernels), session, recipe,
            )
            #expect(Self.differing(reclaimed.texels, fresh.texels) == 0)
        }
    }
}
