import Foundation
import Testing
@testable import RedlampMasking

struct CompiledModelsTests {
    private func folder(_ names: [String], modified: Date) throws -> URL {
        let url = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        for name in names {
            let model = url.appending(path: name)
            try FileManager.default.createDirectory(at: model, withIntermediateDirectories: true)
            try FileManager.default.setAttributes([.modificationDate: modified], ofItemAtPath: model.path)
        }
        return url
    }

    private func remaining(_ url: URL) throws -> Set<String> {
        try Set(FileManager.default.contentsOfDirectory(atPath: url.path))
    }

    @Test func `an old compile of the model is removed, with or without its suffix`() throws {
        let now = Date()
        let url = try folder(
            ["Sam3ImageEncoder.mlmodelc", "Sam3ImageEncoder_0C594D8F-01A7-4B9F-A4E8-FB55CF2790E6.mlmodelc"],
            modified: now.addingTimeInterval(-2 * CompiledModels.leftoverAge),
        )
        defer { try? FileManager.default.removeItem(at: url) }
        CompiledModels.removeLeftovers(of: "Sam3ImageEncoder", in: url, now: now)
        #expect(try remaining(url).isEmpty)
    }

    @Test func `a recent compile may belong to a running launch and is kept`() throws {
        let now = Date()
        let url = try folder(["Sam3ImageEncoder_A.mlmodelc"], modified: now.addingTimeInterval(-60))
        defer { try? FileManager.default.removeItem(at: url) }
        CompiledModels.removeLeftovers(of: "Sam3ImageEncoder", in: url, now: now)
        #expect(try remaining(url) == ["Sam3ImageEncoder_A.mlmodelc"])
    }

    @Test func `other models and other files are kept`() throws {
        let now = Date()
        let names = ["Sam3TextDecoder_A.mlmodelc", "Sam3ImageEncoderLarge.mlmodelc", "Sam3ImageEncoder_A.mlpackage"]
        let url = try folder(names, modified: now.addingTimeInterval(-2 * CompiledModels.leftoverAge))
        defer { try? FileManager.default.removeItem(at: url) }
        CompiledModels.removeLeftovers(of: "Sam3ImageEncoder", in: url, now: now)
        #expect(try remaining(url) == Set(names))
    }
}
