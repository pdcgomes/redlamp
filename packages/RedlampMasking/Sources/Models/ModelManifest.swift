import Foundation

/// One model version: what it is for, the files that make it up, and where its licences and
/// training data stand. Each lives in `Resources/Models/<id>.json`; the licence gate
/// (`scripts/check-model-licenses.py`) reads the same files.
public struct ModelManifest: Codable, Sendable, Hashable, Identifiable {
    public struct File: Codable, Sendable, Hashable {
        public var path: String
        public var bytes: Int
        public var sha256: String
    }

    public struct Licenses: Codable, Sendable, Hashable {
        public var code: String
        public var weights: String
        /// The datasets the weights were trained on (or distilled from).
        public var data: [String]
    }

    public var id: String
    public var version: Int
    public var name: String
    public var purpose: String
    /// The `AIMask.provider` of masks it makes.
    public var provider: String
    /// The Apple-hosted Background Assets pack holding this version (App Store builds).
    public var assetPack: String
    /// Where the files can be fetched directly (development and direct-download builds).
    public var source: URL
    /// `cpuAndGPU`, `cpuAndNeuralEngine` or `all`.
    public var computeUnits: String
    public var files: [File]
    public var licenses: Licenses
    /// The tracker decision its use waits on, if any.
    public var decision: String?
    /// Training-data terms that don't allow shipping it.
    public var evaluationOnly: Bool
    /// Its decision is accepted, so everyone is offered it. Until then (and always for
    /// evaluation-only models) it is offered only with evaluation models turned on.
    public var cleared: Bool
    /// `false` while its files are only on the machine that converted them (nil means published).
    public var published: Bool?
    /// The least memory a Mac needs to run it, in bytes; Macs with less aren't offered it.
    public var minimumMemory: Int?
    /// The least memory it has been tried on, in bytes; Macs with less are offered it with a note
    /// that it hasn't been tested on them.
    public var testedMemory: Int?
    public var notes: String?

    /// Whether a Mac with `memory` bytes runs it (this Mac's by default).
    public func fits(memory: UInt64 = ProcessInfo.processInfo.physicalMemory) -> Bool {
        minimumMemory.map { memory >= UInt64($0) } ?? true
    }

    /// Whether it has been tried on a Mac with as little as `memory` bytes (this Mac's by default).
    public func isTested(memory: UInt64 = ProcessInfo.processInfo.physicalMemory) -> Bool {
        testedMemory.map { memory >= UInt64($0) } ?? true
    }

    public var isPublished: Bool {
        published ?? true
    }

    public var downloadBytes: Int {
        files.reduce(0) { $0 + $1.bytes }
    }

    /// Where `file` is fetched from: by its path under the source, except from a GitHub release,
    /// whose assets can't hold folders, so each `/` of the path is `__` in the asset's name.
    public func remote(_ file: File) -> URL {
        if source.host() == "github.com", source.path().contains("/releases/download/") {
            return source.appending(path: file.path.replacingOccurrences(of: "/", with: "__"))
        }
        return source.appending(path: file.path)
    }
}

/// The models Redlamp knows, from the bundled manifests.
public enum ModelCatalog {
    public static let all: [ModelManifest] = {
        let bundle = Bundle(for: BundleToken.self)
        // Resources are copied flat into the framework.
        let urls = bundle.urls(forResourcesWithExtension: "json", subdirectory: nil) ?? []
        return urls.compactMap { url in
            (try? Data(contentsOf: url)).flatMap { try? JSONDecoder().decode(ModelManifest.self, from: $0) }
        }
        .sorted { $0.id < $1.id }
    }()

    public static let evaluationModelsKey = "app.redlamp.evaluationModels"

    /// Models awaiting licence review are offered only when asked for (Settings › Models, or
    /// `REDLAMP_EVALUATION_MODELS=1`).
    public static var allowsEvaluationModels: Bool {
        ProcessInfo.processInfo.environment["REDLAMP_EVALUATION_MODELS"] == "1"
            || UserDefaults.standard.bool(forKey: evaluationModelsKey)
    }

    public static var offered: [ModelManifest] {
        all.filter { ($0.cleared && !$0.evaluationOnly) || allowsEvaluationModels }
    }

    public static func manifest(_ id: String) -> ModelManifest? {
        all.first { $0.id == id }
    }

    private final class BundleToken {}
}
