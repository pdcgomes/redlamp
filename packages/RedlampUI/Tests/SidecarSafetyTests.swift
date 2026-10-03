import Foundation
import RedlampDocument
import RedlampEngineAPI
import Testing
@testable import RedlampUI

/// The editor never loses a sidecar on disk: browsing, editing and rating a photo whose edit it
/// can't read leave the file as it was.
@MainActor
struct SidecarSafetyTests {
    /// Edits this build can't decode: an enum value it doesn't know, a truncated file, and a
    /// value of the wrong type.
    nonisolated static let unreadable = [
        #"{"format":"app.redlamp.edit","recipe":{"version":1,"processVersion":1,"treatment":"infrared"}}"#,
        #"{"format":"app.redlamp.edit","recipe":{"version":1,"processVersion":1,"values":{"basic.expo"#,
        #"{"format":"app.redlamp.edit","recipe":{"version":1,"processVersion":1,"values":{"basic.exposure":"+1"}}}"#,
    ]

    private struct Folder {
        let url = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)

        var photo: URL {
            url.appending(path: "IMG_0001.ARW")
        }

        var other: URL {
            url.appending(path: "IMG_0002.ARW")
        }

        var edit: URL {
            SidecarStore().editURL(for: photo)
        }

        /// A package for `photo` holding `json` as its edit, and a history session.
        func seed(_ json: String) throws {
            let package = SidecarStore().url(for: photo)
            let history = package.appending(path: SidecarStore.historyDirectory)
            try FileManager.default.createDirectory(at: history, withIntermediateDirectories: true)
            try Data(json.utf8).write(to: package.appending(path: SidecarStore.editFile))
            try Data("{}".utf8).write(to: history.appending(path: "\(UUID().uuidString).json"))
        }

        /// Every file in the package, with its bytes.
        func contents() throws -> [String: Data] {
            let package = SidecarStore().url(for: photo)
            let enumerator = FileManager.default.enumerator(at: package, includingPropertiesForKeys: nil)
            var files: [String: Data] = [:]
            while let file = enumerator?.nextObject() as? URL {
                guard let data = try? Data(contentsOf: file) else { continue }
                files[String(file.path.dropFirst(package.path.count))] = data
            }
            return files
        }
    }

    private func open(_ url: URL, in model: EditorModel) async throws {
        model.select(url)
        for _ in 0 ..< 400 where model.info?.url != url {
            try await Task.sleep(for: .milliseconds(5))
        }
        try #require(model.info?.url == url)
    }

    /// Long enough for a save the editor started in the background to land.
    private func settle() async throws {
        try await Task.sleep(for: .milliseconds(200))
    }

    @Test(arguments: unreadable)
    func `a photo whose edit can't be read opens read-only and keeps it`(json: String) async throws {
        let folder = Folder()
        try FileManager.default.createDirectory(at: folder.url, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder.url) }
        try folder.seed(json)
        let before = try folder.contents()
        let model = EditorModel(engine: StubEngine())

        try await open(folder.photo, in: model)
        #expect(model.isReadOnly)
        #expect(model.readOnlyReason == .unreadable)
        try await open(folder.other, in: model)
        try await settle()
        #expect(try folder.contents() == before, "browsing past it keeps it")

        try await open(folder.photo, in: model)
        model.setValue(.exposure, 0.5)
        _ = model.perform(.rating4)
        try await open(folder.other, in: model)
        try await settle()
        #expect(try folder.contents() == before, "editing and rating it keep it")
        #expect(try Data(contentsOf: folder.edit) == Data(json.utf8))
    }

    @Test(arguments: unreadable)
    func `sync settings leaves a photo whose edit can't be read alone`(json: String) async throws {
        let folder = Folder()
        try FileManager.default.createDirectory(at: folder.url, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder.url) }
        try folder.seed(json)
        let before = try folder.contents()
        let model = EditorModel(engine: StubEngine())
        model.makeWorkerEngine = { StubEngine() }
        [folder.other, folder.photo].forEach { model.library.insert(LibraryItem(url: $0)) }

        try await open(folder.other, in: model)
        model.setValue(.exposure, 1)
        model.selectAllPhotos()
        model.copySelection = .default
        model.syncSettings()
        await model.settingsSync.idle()
        #expect(try folder.contents() == before)
        #expect(model.settingsSync.report?.contains("left alone") == true)
        model.copySelection = .default
    }
}
