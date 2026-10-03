import Foundation
import Testing
@testable import RedlampMasking

struct ModelStoreTests {
    private func temporary() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// A one-file model served from a local folder, as the publisher's server would.
    private func manifest(serving data: Data, at source: URL, sha256: String? = nil) throws -> ModelManifest {
        try FileManager.default.createDirectory(
            at: source.appending(path: "Model.mlpackage"),
            withIntermediateDirectories: true,
        )
        try data.write(to: source.appending(path: "Model.mlpackage/weights.bin"))
        let json = """
        {"id":"test-model","version":3,"name":"Test","purpose":"Tests","provider":"test","assetPack":"models.test.v3",
         "source":"\(source.absoluteString)","computeUnits":"cpuAndGPU","cleared":true,"evaluationOnly":false,
         "files":[{"path":"Model.mlpackage/weights.bin","bytes":\(data.count),"sha256":"\(sha256 ?? MaskHash
            .sha256(data))"}],
         "licenses":{"code":"MIT","weights":"MIT","data":[]}}
        """
        return try JSONDecoder().decode(ModelManifest.self, from: Data(json.utf8))
    }

    @Test func `bundles the known manifests`() throws {
        let ids = ModelCatalog.all.map(\.id)
        #expect(ids.contains("sam2.1-tiny"))
        #expect(ids.contains("depth-anything-v2-small"))
        let sam = ModelCatalog.manifest("sam2.1-tiny")
        #expect(sam?.downloadBytes == 79_644_968)
        #expect(sam?.cleared == true)
        #expect(try SAMSegmenter.packages(in: #require(sam)).count == 3)
    }

    @Test func `downloads, checks and removes a model`() async throws {
        let root = try temporary()
        let source = try temporary()
        defer {
            try? FileManager.default.removeItem(at: root)
            try? FileManager.default.removeItem(at: source)
        }
        let model = try manifest(serving: Data(repeating: 7, count: 4096), at: source)
        let store = ModelStore(root: root)
        #expect(await store.state(of: model) == .notDownloaded)
        let reports = Reports()
        let directory = try await store.download(model) { reports.append($0) }
        #expect(directory.lastPathComponent == "3")
        #expect(await store.state(of: model) == .ready)
        #expect(reports.values.last == 1)
        try await store.remove(model)
        #expect(await store.location(of: model) == nil)
    }

    @Test func `a release's files are fetched by flat names, other sources' by their paths`() throws {
        let owl = try #require(ModelCatalog.manifest("owlv2-base"))
        let weights = try #require(owl.files.first { $0.path.hasSuffix("weight.bin") })
        #expect(
            owl.remote(weights).absoluteString == "https://github.com/pdcgomes/redlamp/releases/download/"
                + "models-owlv2-base-v1/Owlv2Detector.mlpackage__Data__com.apple.CoreML__weights__weight.bin",
        )
        let sam = try #require(ModelCatalog.manifest("sam2.1-tiny"))
        let encoder = try #require(sam.files.first)
        #expect(sam.remote(encoder).absoluteString.hasSuffix("/resolve/main/\(encoder.path)"))
    }

    @Test func `an unpublished model can't be downloaded`() async throws {
        let root = try temporary()
        let source = try temporary()
        defer {
            try? FileManager.default.removeItem(at: root)
            try? FileManager.default.removeItem(at: source)
        }
        var model = try manifest(serving: Data(repeating: 7, count: 64), at: source)
        model.published = false
        await #expect(throws: ModelStoreError.self) { try await ModelStore(root: root).download(model) }
        #expect(await ModelStore(root: root).location(of: model) == nil)
    }

    @Test func `the models redistributed from a release carry their licence`() throws {
        for id in ["owlv2-base", "depth-anything-3-mono-large", "sam3"] {
            let model = try #require(ModelCatalog.manifest(id))
            #expect(model.cleared && !model.evaluationOnly && model.isPublished, "\(id)")
            #expect(model.files.contains { $0.path == "LICENSE.txt" }, "\(id)")
        }
        #expect(ModelCatalog.manifest("sam3")?.licenses.weights == "SAM License")
    }

    @Test func `refuses a damaged download`() async throws {
        let root = try temporary()
        let source = try temporary()
        defer {
            try? FileManager.default.removeItem(at: root)
            try? FileManager.default.removeItem(at: source)
        }
        let model = try manifest(
            serving: Data(repeating: 1, count: 100),
            at: source,
            sha256: String(repeating: "0", count: 64),
        )
        let store = ModelStore(root: root)
        await #expect(throws: ModelStoreError.self) { try await store.download(model) }
        #expect(await store.location(of: model) == nil)
    }

    @Test func `the embedding cache keeps the most recent within budget`() async throws {
        let root = try temporary()
        defer { try? FileManager.default.removeItem(at: root) }
        let cache = EmbeddingCache(root: root, budget: 2500)
        await cache.store(Data(repeating: 1, count: 1000), for: "a")
        try await Task.sleep(for: .milliseconds(20))
        await cache.store(Data(repeating: 2, count: 1000), for: "b")
        try await Task.sleep(for: .milliseconds(20))
        await cache.store(Data(repeating: 3, count: 1000), for: "c")
        let fresh = EmbeddingCache(root: root, budget: 2500)
        #expect(await fresh.data(for: "a") == nil)
        #expect(await fresh.data(for: "c")?.first == 3)
    }
}

final class Reports: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: [Double] = []

    func append(_ value: Double) {
        lock.withLock { stored.append(value) }
    }

    var values: [Double] {
        lock.withLock { stored }
    }
}

enum MaskHash {
    static func sha256(_ data: Data) -> String {
        let url = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try? data.write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        return (try? ModelStore.sha256(of: url)) ?? ""
    }
}
