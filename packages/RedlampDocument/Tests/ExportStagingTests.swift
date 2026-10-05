import Foundation
import Testing
@testable import RedlampDocument

struct ExportStagingTests {
    private let defaults = UserDefaults(suiteName: "ExportStagingTests-\(UUID().uuidString)")!
    private let root = FileManager.default.temporaryDirectory.appending(path: "export-staging-\(UUID().uuidString)")

    private func folder(_ name: String) throws -> URL {
        let url = root.appending(path: name)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        try Data("partial".utf8).write(to: url.appending(path: "Photo.jpg"))
        return url
    }

    @Test func `an export cut short leaves its staging listed, and a later launch removes it`() throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let now = Date()
        let abandoned = try folder("abandoned")
        let running = try folder("running")
        ExportStaging.begin(abandoned, defaults: defaults, now: now.addingTimeInterval(-2 * ExportStaging.leftoverAge))
        ExportStaging.begin(running, defaults: defaults, now: now.addingTimeInterval(-60))
        ExportStaging.removeLeftovers(defaults: defaults, now: now)
        #expect(!FileManager.default.fileExists(atPath: abandoned.path))
        #expect(FileManager.default.fileExists(atPath: running.path), "it may be another process's export")
        ExportStaging.end(running, defaults: defaults)
        #expect(defaults.dictionary(forKey: ExportStaging.key) == nil)
    }

    @Test func `a finished export leaves nothing listed or on disk`() throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let folder = try folder("out")
        let url = folder.appending(path: "Export.jpg")
        try ImageExporter.place(at: url) { try Data("jpeg".utf8).write(to: $0) }
        #expect(try Data(contentsOf: url) == Data("jpeg".utf8))
        #expect(UserDefaults.standard.dictionary(forKey: ExportStaging.key)?.keys
            .contains { $0.contains("out") } != true)
    }
}
