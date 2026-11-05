import Foundation
import RedlampEngineAPI
import RedlampMasking

/// Downloadable models (Segment Anything for Objects, Depth Anything for Depth Range).
public extension RedlampEngine {
    /// Which model each AI mask kind needs when the OS doesn't provide one. REDLAMP_SAM_MODEL puts
    /// another Segment Anything 2.1 (`sam2.1-baseplus`, `sam2.1-large`, evaluation models) behind
    /// Objects and Sky, for the mask bench (MSK-40).
    internal static func modelID(for kind: MaskKind) -> String? {
        switch kind {
        case .objects: ProcessInfo.processInfo.environment["REDLAMP_SAM_MODEL"] ?? "sam2.1-tiny"
        case .depthRange: "depth-anything-v2-small"
        case .landscape: sam3ID
        default: nil
        }
    }

    /// SAM 3: Landscape, and the People parts Vision can't give (`SAM3Concepts.partPrecedence`).
    internal static let sam3ID = "sam3"

    /// The models `modelSky` uses when they're here: Objects' Segment Anything, then Depth Anything 3.
    internal static var skyModelIDs: [String] {
        [modelID(for: .objects), depthAnything3ID].compactMap(\.self)
    }

    /// Of `models`, those Sky offers, in `skyModelIDs`' order: neither here nor downloading, offered
    /// to everyone, published, and fitting this Mac.
    internal static func skyModelsToOffer(from models: [ModelInfo]) -> [ModelInfo] {
        skyModelIDs.compactMap { id in
            models.first { model in
                model.id == id && model.state == .notDownloaded && model.isCleared && model.isPublished
                    && model.fitsThisMac
            }
        }
    }

    func models() async -> [ModelInfo] {
        var infos: [ModelInfo] = []
        for manifest in ModelCatalog.offered {
            await infos.append(info(manifest))
        }
        return infos
    }

    func modelNeeded(for kind: MaskKind) async -> ModelInfo? {
        if kind == .depthRange, currentSession()?.embeddedMattes.contains(.depth) == true {
            return nil
        }
        guard let id = Self.modelID(for: kind), let manifest = ModelCatalog.offered.first(where: { $0.id == id }) else {
            return nil
        }
        let info = await info(manifest)
        return info.state == .ready ? nil : info
    }

    /// SAM 3 for the People parts only it makes; Hair needs it only without an iPhone's hair matte.
    func modelNeeded(for kind: MaskKind, part: PersonPart) async -> ModelInfo? {
        guard kind == .people, SAM3Concepts.partPrecedence.contains(part) else { return await modelNeeded(for: kind) }
        if part == .hair, currentSession()?.embeddedMattes.contains(.hair) == true {
            return nil
        }
        guard let manifest = ModelCatalog.offered.first(where: { $0.id == Self.sam3ID }) else { return nil }
        let info = await info(manifest)
        return info.state == .ready ? nil : info
    }

    /// Sky's models while any is missing; none for a photo with an iPhone's sky matte, which Sky
    /// uses instead.
    func modelsImproving(_ kind: MaskKind) async -> [ModelInfo] {
        guard kind == .sky, currentSession()?.embeddedMattes.contains(.sky) != true else { return [] }
        var infos: [ModelInfo] = []
        for manifest in ModelCatalog.offered where Self.skyModelIDs.contains(manifest.id) {
            await infos.append(info(manifest))
        }
        return Self.skyModelsToOffer(from: infos)
    }

    func downloadModel(_ id: String, progress: @escaping @Sendable (Double) -> Void) async throws {
        guard let manifest = ModelCatalog.manifest(id) else { throw ModelStoreError.unknownModel(id) }
        try await ModelStore.shared.download(manifest, progress: progress)
    }

    /// Removes model files this build can't use: older versions, their compiles, and downloads
    /// cut short (`ModelStore.removeOutdated`). For the app to call once a launch.
    static func removeOutdatedModels() async {
        await ModelStore.shared.removeOutdated()
    }

    /// Lets no AI model load or predict again, in any engine, and waits at most `timeout` for those
    /// running (`Inference`); false if one still runs. For the app to call last before it exits.
    @discardableResult
    static func stopModels(waitingAtMost timeout: TimeInterval) -> Bool {
        Inference.shared.stop(waitingAtMost: timeout)
    }

    func removeModel(_ id: String) async throws {
        guard let manifest = ModelCatalog.manifest(id) else { throw ModelStoreError.unknownModel(id) }
        try await ModelStore.shared.remove(manifest)
    }

    internal func info(_ manifest: ModelManifest) async -> ModelInfo {
        let state: ModelInfo.State = switch await ModelStore.shared.state(of: manifest) {
        case .notDownloaded: .notDownloaded
        case let .downloading(fraction): .downloading(fraction)
        case .ready: .ready
        }
        let licence = manifest.files.first { $0.path == "LICENSE.txt" }
        let local = state == .ready && licence != nil ? await ModelStore.shared.location(of: manifest) : nil
        return ModelInfo(
            id: manifest.id, name: manifest.name, purpose: manifest.purpose, downloadBytes: manifest.downloadBytes,
            state: state, isEvaluationOnly: manifest.evaluationOnly,
            isCleared: manifest.cleared && !manifest.evaluationOnly, isPublished: manifest.isPublished,
            decision: manifest.decision, licence: manifest.licenses.weights,
            licenceURL: licence.map(manifest.remote),
            trainingData: manifest.licenses.data, minimumMemory: manifest.minimumMemory, fitsThisMac: manifest.fits(),
            testedMemory: manifest.testedMemory, testedOnThisMac: manifest.isTested(),
            codeLicence: manifest.licenses.code, page: manifest.page,
            licenceFile: local.map { $0.appending(path: "LICENSE.txt") },
        )
    }
}
