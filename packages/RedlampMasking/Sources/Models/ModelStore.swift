import BackgroundAssets
import CryptoKit
import Foundation
import System

public enum ModelStoreError: Error, CustomStringConvertible {
    case unknownModel(String)
    case notOffered(String)
    case checksumMismatch(String)
    case download(String)

    public var description: String {
        switch self {
        case let .unknownModel(id): "There is no model called \(id)."
        case let .notOffered(id): "\(id) is for evaluation only until its licence is cleared."
        case let .checksumMismatch(path): "A downloaded model file was damaged (\(path)). Try again."
        case let .download(reason): "The model couldn't be downloaded: \(reason)"
        }
    }
}

/// Where models live on this device, and how they get there.
///
/// App Store and TestFlight builds get each model version as its own Apple-hosted Background
/// Assets pack (`onDemand`, downloaded on first use). Other builds (development, the CLI, the
/// notarized direct download) fetch the same files from the publisher over HTTPS into
/// Application Support. Either way every file is checked against the manifest's SHA-256, and a
/// version never changes once published, so a mask made with it can be made again.
public actor ModelStore {
    public static let shared = ModelStore()

    public enum State: Sendable, Hashable {
        case notDownloaded
        case downloading(Double)
        case ready
    }

    public let root: URL
    private var progress: [String: Double] = [:]

    /// Only builds set up for Apple-hosted asset packs use them (App Store and TestFlight).
    static let usesAssetPacks = Bundle.main.object(forInfoDictionaryKey: "BAHasManagedAssetPacks") as? Bool == true

    static func packIsLocal(_ id: String) -> Bool {
        guard usesAssetPacks else { return false }
        if #available(macOS 26.4, iOS 26.4, *) {
            return AssetPackManager.shared.assetPackIsAvailableLocally(withID: id)
        }
        return false
    }

    public init(root: URL? = nil) {
        self.root = root ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appending(path: "Redlamp/Models")
    }

    /// The directory holding a model version's files, once they're all there.
    public func location(of manifest: ModelManifest) -> URL? {
        if Self.packIsLocal(manifest.assetPack), let first = manifest.files.first,
           let url = try? AssetPackManager.shared.url(for: FilePath(first.path)) {
            return Self.root(of: url, relativePath: first.path)
        }
        let directory = directory(for: manifest)
        let complete = manifest.files.allSatisfy { file in
            let attributes = try? FileManager.default
                .attributesOfItem(atPath: directory.appending(path: file.path).path)
            return (attributes?[.size] as? Int) == file.bytes
        }
        return complete ? directory : nil
    }

    public func state(of manifest: ModelManifest) -> State {
        if let fraction = progress[manifest.id] {
            return .downloading(fraction)
        }
        return location(of: manifest) == nil ? .notDownloaded : .ready
    }

    /// Makes the model available, reporting progress 0...1. Returns its directory.
    @discardableResult
    public func download(
        _ manifest: ModelManifest, progress report: @escaping @Sendable (Double) -> Void = { _ in },
    ) async throws -> URL {
        guard (manifest.cleared && !manifest.evaluationOnly) || ModelCatalog.allowsEvaluationModels else {
            throw ModelStoreError.notOffered(manifest.id)
        }
        if let ready = location(of: manifest) {
            return ready
        }
        guard manifest.isPublished else {
            throw ModelStoreError.download("\(manifest.name) isn't published yet; its notes say how to build it")
        }
        progress[manifest.id] = 0
        defer { progress[manifest.id] = nil }
        if Self.usesAssetPacks, let pack = try? await AssetPackManager.shared.assetPack(withID: manifest.assetPack) {
            try await AssetPackManager.shared.ensureLocalAvailability(of: pack)
            if let ready = location(of: manifest) {
                return ready
            }
        }
        return try await downloadDirectly(manifest, report: report)
    }

    public func remove(_ manifest: ModelManifest) async throws {
        if Self.packIsLocal(manifest.assetPack) {
            try await AssetPackManager.shared.remove(assetPackWithID: manifest.assetPack)
        }
        let directory = directory(for: manifest)
        if FileManager.default.fileExists(atPath: directory.path) {
            try FileManager.default.removeItem(at: directory)
        }
    }

    // MARK: - Direct download

    private func directory(for manifest: ModelManifest) -> URL {
        root.appending(path: manifest.id).appending(path: "\(manifest.version)")
    }

    private func downloadDirectly(
        _ manifest: ModelManifest,
        report: @escaping @Sendable (Double) -> Void,
    ) async throws -> URL {
        let staging = root.appending(path: ".\(manifest.id)-\(manifest.version)-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: staging) }
        var done = 0
        let total = max(manifest.downloadBytes, 1)
        for file in manifest.files {
            let (downloaded, response) = try await URLSession.shared.download(from: manifest.remote(file))
            guard (response as? HTTPURLResponse)?.statusCode ?? 200 < 400 else {
                throw ModelStoreError.download("\(file.path): HTTP \((response as? HTTPURLResponse)?.statusCode ?? 0)")
            }
            guard try Self.sha256(of: downloaded) == file.sha256 else {
                throw ModelStoreError.checksumMismatch(file.path)
            }
            let destination = staging.appending(path: file.path)
            try FileManager.default.createDirectory(
                at: destination.deletingLastPathComponent(), withIntermediateDirectories: true,
            )
            try FileManager.default.moveItem(at: downloaded, to: destination)
            done += file.bytes
            progress[manifest.id] = Double(done) / Double(total)
            report(Double(done) / Double(total))
        }
        let final = directory(for: manifest)
        try FileManager.default.createDirectory(
            at: final.deletingLastPathComponent(),
            withIntermediateDirectories: true,
        )
        if FileManager.default.fileExists(atPath: final.path) {
            try FileManager.default.removeItem(at: final)
        }
        try FileManager.default.moveItem(at: staging, to: final)
        return final
    }

    static func sha256(of url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        while let chunk = try handle.read(upToCount: 1 << 20), !chunk.isEmpty {
            hasher.update(data: chunk)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    /// The pack's root, from the URL of one of its files.
    private static func root(of url: URL, relativePath: String) -> URL {
        var root = url
        for _ in relativePath.split(separator: "/") {
            root.deleteLastPathComponent()
        }
        return root
    }
}
