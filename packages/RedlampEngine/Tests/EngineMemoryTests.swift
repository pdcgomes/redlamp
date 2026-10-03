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

    func render(_ stage: DetailStage, _ session: ImageSession, _ recipe: EditRecipe) throws -> any MTLTexture {
        let commands = try #require(helpers.queue.makeCommandBuffer())
        let output = try #require(try stage.process(
            recipe, session: session, region: .full, outputSize: session.orientedSize, commands: commands,
        ))
        commands.commit()
        commands.waitUntilCompleted()
        return output.texture
    }

    static func residentBytes(_ stage: DetailStage) -> Int {
        stage.heldTextures.filter { $0.setPurgeableState(.keepCurrent) == .nonVolatile }
            .reduce(0) { $0 + $1.allocatedSize }
    }

    /// Completion handlers can run just after `waitUntilCompleted` returns.
    static func settledResidentBytes(_ stage: DetailStage) async throws -> Int {
        for _ in 0 ..< 50 where residentBytes(stage) > idleBudget {
            try await Task.sleep(for: .milliseconds(20))
        }
        return residentBytes(stage)
    }

    @Test func `the detail stage keeps little resident between renders`() async throws {
        let session = try helpers.makeSession(.bayer, width: 6000, height: 4000)
        let stage = DetailStage(device: helpers.device, kernels: helpers.kernels)
        _ = try render(stage, session, Self.everyPass)
        let held = stage.heldTextures.reduce(0) { $0 + $1.allocatedSize }
        let resident = try await Self.settledResidentBytes(stage)
        #expect(resident <= Self.idleBudget, "\(resident >> 20) MB of \(held >> 20) MB resident after a 1:1 render")
    }

    /// The system may empty the stage's textures between renders; it then renders them again.
    @Test func `a reclaimed stage renders what a fresh one does`() async throws {
        let session = try helpers.makeSession(.bayer, width: 640, height: 480) { x, y in
            Float(0.2 + 0.1 * sin(Double(x) / 3) * cos(Double(y) / 5))
        }
        let size = session.orientedSize
        let stage = DetailStage(device: helpers.device, kernels: helpers.kernels)
        var output = try render(stage, session, Self.everyPass)
        // The same edit is a cached output; a new Amount reuses the cached sharpening analysis.
        var changedAmount = Self.everyPass
        changedAmount[.sharpenAmount] = 90
        for recipe in [Self.everyPass, changedAmount] {
            _ = try await Self.settledResidentBytes(stage)
            let reclaimedTextures = Set(stage.heldTextures.map(ObjectIdentifier.init))
            for texture in stage.heldTextures {
                texture.setPurgeableState(.volatile)
                texture.setPurgeableState(.empty)
            }
            output = try render(stage, session, recipe)
            #expect(!reclaimedTextures.contains(ObjectIdentifier(output)))
            #expect(stage.sharpenCache.heldTextures.contains { !reclaimedTextures.contains(ObjectIdentifier($0)) })
            let reclaimed = try helpers.readBack(output, level: 0, width: size.width, height: size.height)
            let fresh = try helpers.readBack(
                render(DetailStage(device: helpers.device, kernels: helpers.kernels), session, recipe),
                level: 0, width: size.width, height: size.height,
            )
            #expect(reclaimed == fresh)
        }
    }
}
