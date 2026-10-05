import Foundation
import Testing
@testable import RedlampMasking

struct OutdatedModelsTests {
    private let base = FileManager.default.temporaryDirectory.appending(path: "outdated-\(UUID().uuidString)")
    private var models: URL {
        base.appending(path: "Models")
    }

    private var compiled: URL {
        base.appending(path: "CompiledModels")
    }

    private func manifest(_ id: String, version: Int) throws -> ModelManifest {
        let json = """
        {"id":"\(id)","version":\(version),"name":"Test","purpose":"Tests","provider":"test",
         "assetPack":"models.\(id).v\(version)","source":"https://example.com/","computeUnits":"cpuAndGPU",
         "cleared":true,"evaluationOnly":false,"files":[],"licenses":{"code":"MIT","weights":"MIT","data":[]}}
        """
        return try JSONDecoder().decode(ModelManifest.self, from: Data(json.utf8))
    }

    private func make(_ paths: [String], in root: URL, modified: Date = Date()) throws {
        for path in paths {
            let url = root.appending(path: path)
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
            try FileManager.default.setAttributes([.modificationDate: modified], ofItemAtPath: url.path)
        }
    }

    private func contents(_ path: String) throws -> Set<String> {
        try Set(FileManager.default.contentsOfDirectory(atPath: base.appending(path: path).path))
    }

    @Test func `older versions of a catalogued model go; newer ones and unlisted models stay`() async throws {
        defer { try? FileManager.default.removeItem(at: base) }
        try make(["depth/1", "depth/2", "depth/3", "retired/1"], in: models)
        let store = ModelStore(root: models)
        try await store.removeOutdated(catalog: [manifest("depth", version: 2)], compiled: compiled)
        #expect(try contents("Models/depth") == ["2", "3"])
        #expect(try contents("Models") == ["depth", "retired"])
    }

    @Test func `compiles of versions the catalogue doesn't list go`() async throws {
        defer { try? FileManager.default.removeItem(at: base) }
        try make([
            "sam3-v1-Sam3ImageEncoder.mlmodelc", "sam3-v1-Sam3TextDecoder.mlmodelc",
            "sam3-landscape-v1-Sam3ImageEncoder.mlmodelc", "depth-v1-Depth.mlmodelc", "depth-v2-Depth.mlmodelc",
        ], in: compiled)
        let store = ModelStore(root: models)
        try await store.removeOutdated(
            catalog: [manifest("sam3", version: 1), manifest("depth", version: 2)], compiled: compiled,
        )
        #expect(try contents("CompiledModels") == [
            "sam3-v1-Sam3ImageEncoder.mlmodelc", "sam3-v1-Sam3TextDecoder.mlmodelc", "depth-v2-Depth.mlmodelc",
        ])
    }

    @Test func `staging a download cut short left goes after a day`() async throws {
        defer { try? FileManager.default.removeItem(at: base) }
        let now = Date()
        try make([".sam3-1-A"], in: models, modified: now.addingTimeInterval(-2 * ModelStore.leftoverAge))
        try make([".sam3-1-B"], in: models, modified: now.addingTimeInterval(-60))
        let store = ModelStore(root: models)
        await store.removeOutdated(catalog: [], compiled: compiled, now: now)
        #expect(try contents("Models") == [".sam3-1-B"])
    }
}
