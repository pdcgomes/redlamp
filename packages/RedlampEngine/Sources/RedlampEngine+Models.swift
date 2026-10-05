import Foundation
import RedlampEngineAPI
import RedlampMasking

/// Downloadable models (Segment Anything for Objects, Depth Anything for Depth Range).
public extension RedlampEngine {
    /// Which model each AI mask kind needs when the OS doesn't provide one.
    internal static func modelID(for kind: MaskKind) -> String? {
        switch kind {
        case .objects: "sam2.1-tiny"
        case .depthRange: "depth-anything-v2-small"
        case .landscape: sam3ID
        default: nil
        }
    }

    /// SAM 3: Landscape, and the People parts Vision can't give (`SAM3Concepts.partPrecedence`).
    internal static let sam3ID = "sam3"

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

    func downloadModel(_ id: String, progress: @escaping @Sendable (Double) -> Void) async throws {
        guard let manifest = ModelCatalog.manifest(id) else { throw ModelStoreError.unknownModel(id) }
        try await ModelStore.shared.download(manifest, progress: progress)
    }

    func removeModel(_ id: String) async throws {
        guard let manifest = ModelCatalog.manifest(id) else { throw ModelStoreError.unknownModel(id) }
        try await ModelStore.shared.remove(manifest)
    }

    private func info(_ manifest: ModelManifest) async -> ModelInfo {
        let state: ModelInfo.State = switch await ModelStore.shared.state(of: manifest) {
        case .notDownloaded: .notDownloaded
        case let .downloading(fraction): .downloading(fraction)
        case .ready: .ready
        }
        return ModelInfo(
            id: manifest.id, name: manifest.name, purpose: manifest.purpose, downloadBytes: manifest.downloadBytes,
            state: state, isEvaluationOnly: manifest.evaluationOnly,
            isCleared: manifest.cleared && !manifest.evaluationOnly, isPublished: manifest.isPublished,
            decision: manifest.decision, licence: manifest.licenses.weights,
            licenceURL: manifest.files.first { $0.path == "LICENSE.txt" }.map(manifest.remote),
            minimumMemory: manifest.minimumMemory, fitsThisMac: manifest.fits(),
        )
    }
}
