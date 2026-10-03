import Foundation
import RedlampMasking
import Testing
@testable import RedlampEngine

/// A photo's embedded mattes are found once, while its session is built, so asking which masks
/// it offers never reads the file again.
struct EmbeddedMattesTests {
    private static func fixture(_ name: String) -> URL? {
        EngineSmokeTests.fixtures.first { $0.lastPathComponent == name }
    }

    @Test(.enabled(if: EngineSmokeTests.canRender && fixture("IMG_1361.DNG") != nil))
    func `the session keeps the mattes its file carries`() async throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let copy = folder.appending(path: "IMG_1361.DNG")
        try FileManager.default.copyItem(at: #require(Self.fixture("IMG_1361.DNG")), to: copy)
        let engine = try RedlampEngine()
        _ = try await engine.open(copy)

        try FileManager.default.removeItem(at: copy)
        #expect(EmbeddedMattes.available(in: copy).isEmpty, "the file is gone")
        #expect(engine.currentSession()?.embeddedMattes == [.sky])
    }

    @Test(.enabled(if: EngineSmokeTests.canRender && fixture("DSC_0750.NEF") != nil))
    func `a photo without mattes has none`() async throws {
        let engine = try RedlampEngine()
        _ = try await engine.open(#require(Self.fixture("DSC_0750.NEF")))
        #expect(engine.currentSession()?.embeddedMattes == [])
    }
}
