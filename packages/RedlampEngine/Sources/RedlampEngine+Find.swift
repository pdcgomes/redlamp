import CoreGraphics
import Foundation
import RedlampEngineAPI
import RedlampMasking

/// Things named in words (RM-08): OWLv2 boxes them in the analysis render, as AI masks see it.
public extension RedlampEngine {
    internal static let thingFinderID = "owlv2-base"

    func thingsToFind() async -> [String] {
        if let loaded = thingFinder.withLock({ $0 }) {
            return loaded.things
        }
        guard let manifest = ModelCatalog.offered.first(where: { $0.id == Self.thingFinderID }),
              let directory = await ModelStore.shared.location(of: manifest)
        else { return [] }
        return (try? OWLv2Detector.things(in: directory)) ?? []
    }

    func modelNeededToFind() async -> ModelInfo? {
        guard let manifest = ModelCatalog.offered.first(where: { $0.id == Self.thingFinderID }),
              await ModelStore.shared.location(of: manifest) == nil
        else { return nil }
        return await models().first { $0.id == manifest.id }
    }

    func findThings(_ things: Set<String>, threshold: Double) async throws -> [FoundThing] {
        guard let session = currentSession() else { throw EngineError.noImageOpen }
        let analysis = try await analysisImage(for: session)
        let finder = try await loadedThingFinder()
        let image = analysis.image
        let found = try await Task.detached(priority: .userInitiated) {
            try finder.detect(image, things: things, threshold: Float(threshold))
        }.value
        return found.map { detection in
            FoundThing(
                thing: detection.thing, score: Double(detection.score),
                box: ImageRect(
                    x: detection.box.minX, y: detection.box.minY,
                    width: detection.box.width, height: detection.box.height,
                ),
            )
        }
    }

    internal func loadedThingFinder() async throws -> OWLv2Detector {
        if let loaded = thingFinder.withLock({ $0 }) {
            return loaded
        }
        guard let manifest = ModelCatalog.offered.first(where: { $0.id == Self.thingFinderID }),
              let directory = await ModelStore.shared.location(of: manifest)
        else { throw MaskComputationError.unsupported(.objects) }
        let loaded = try await Task.detached(priority: .userInitiated) {
            try OWLv2Detector(manifest: manifest, directory: directory)
        }.value
        thingFinder.withLock { $0 = loaded }
        return loaded
    }
}
