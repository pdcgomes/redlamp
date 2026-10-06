import Foundation
import RedlampDocument
import RedlampEngineAPI
import Testing
@testable import RedlampUI

/// The editor never loses a sidecar on disk: browsing, editing and rating a photo whose edit it
/// can't read leave the file as it was.
@MainActor
struct SidecarSafetyTests {
    /// Edits this build can't decode: an enum value it doesn't know and a value of the wrong type,
    /// then a damaged one, cut short.
    nonisolated static let unreadable = [
        #"{"format":"app.redlamp.edit","recipe":{"version":1,"processVersion":1,"treatment":"infrared"}}"#,
        #"{"format":"app.redlamp.edit","recipe":{"version":1,"processVersion":1,"values":{"basic.exposure":"+1"}}}"#,
    ] + damaged

    nonisolated static let damaged = [
        #"{"format":"app.redlamp.edit","recipe":{"version":1,"processVersion":1,"values":{"basic.expo"#,
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

        /// A package for `photo` holding `json` as its edit, and a history session unless not `withHistory`.
        func seed(_ json: String, withHistory: Bool = true) throws {
            let package = SidecarStore().url(for: photo)
            let history = package.appending(path: SidecarStore.historyDirectory)
            try FileManager.default.createDirectory(at: history, withIntermediateDirectories: true)
            try Data(json.utf8).write(to: package.appending(path: SidecarStore.editFile))
            if withHistory {
                try Data("{}".utf8).write(to: history.appending(path: "\(UUID().uuidString).json"))
            }
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
        try await eventually { model.info?.url == url }
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
        #expect(model.readOnlyReason == (Self.damaged.contains(json) ? .damaged : .unreadable))
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

    @Test func `a sidecar holding only fields this build doesn't know survives viewing the photo`() async throws {
        let folder = Folder()
        try FileManager.default.createDirectory(at: folder.url, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder.url) }
        try folder.seed(
            #"{"format":"app.redlamp.edit","recipe":{"version":1,"processVersion":1},"keywords":["harbour"]}"#,
            withHistory: false,
        )
        let before = try folder.contents()
        let model = EditorModel(engine: StubEngine())

        try await open(folder.photo, in: model)
        #expect(!model.isReadOnly)
        try await open(folder.other, in: model)
        try await settle()
        #expect(try folder.contents() == before)
    }

    @Test(arguments: unreadable)
    func `rating a photo whose edit can't be read changes nothing it shows`(json: String) async throws {
        let folder = Folder()
        try FileManager.default.createDirectory(at: folder.url, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder.url) }
        try folder.seed(json)
        let model = EditorModel(engine: StubEngine())
        model.library.insert(LibraryItem(url: folder.photo))

        model.select(folder.photo)
        _ = model.perform(.rating3)
        try await open(folder.photo, in: model)
        #expect(model.currentMetadata == PhotoMetadata(), "a change made as it opened is taken back")
        #expect((model.library.item(for: folder.photo)?.metadata.rating ?? 0) == 0)
        _ = model.perform(.rating4)
        _ = model.perform(.flagPick)
        #expect(model.currentMetadata == PhotoMetadata())
        #expect((model.library.item(for: folder.photo)?.metadata.rating ?? 0) == 0)
    }

    @Test func `rating a photo as it opens keeps the rest of its metadata`() async throws {
        let folder = Folder()
        try FileManager.default.createDirectory(at: folder.url, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder.url) }
        try folder.seed(
            #"{"format":"app.redlamp.edit","recipe":{"version":3,"processVersion":1},"#
                + #""metadata":{"rating":2,"flag":"pick","label":"red","caption":"Harbour"}}"#,
            withHistory: false,
        )
        let model = EditorModel(engine: StubEngine())
        model.library.insert(LibraryItem(url: folder.photo))

        model.select(folder.photo)
        _ = model.perform(.rating4)
        try await open(folder.photo, in: model)
        var expected = PhotoMetadata(rating: 4, flag: .pick, label: .red)
        expected.unknownFields = ["caption": .string("Harbour")]
        #expect(model.currentMetadata == expected)
        try await open(folder.other, in: model)
        try await settle()
        #expect(SidecarStore().load(for: folder.photo)?.metadata == expected)
    }

    /// Waits for `condition`, which the save queue's results make true on the main actor.
    private func eventually(_ condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(30)
        while !condition(), ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(5))
        }
    }

    @Test func `a save that fails says why, and the filmstrip shows what is on disk`() async throws {
        let folder = Folder()
        try FileManager.default.createDirectory(at: folder.url, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder.url) }
        let model = EditorModel(engine: StubEngine())
        model.library.insert(LibraryItem(url: folder.photo))
        try await open(folder.photo, in: model)

        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: folder.url.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: folder.url.path) }
        model.setValue(.exposure, 0.8)
        _ = model.perform(.rating4)
        model.saveNow()
        await model.saves.flush()
        try await eventually { model.saveError != nil && model.library.item(for: folder.photo)?.metadata.rating == 0 }
        #expect(model.saveError?.message == "Edits to IMG_0001 can't be saved: permission denied")
        #expect(model.saveError?.canRetry == true)
        #expect(model.library.item(for: folder.photo)?.hasEdits == false)
        #expect(model.library.item(for: folder.photo)?.metadata.rating == 0)
        #expect(model.currentMetadata.rating == 4, "the photo still shows it")

        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: folder.url.path)
        model.setValue(.exposure, 0.9)
        model.saveNow()
        await model.saves.flush()
        try await eventually { model.saveError == nil && model.library.item(for: folder.photo)?.hasEdits == true }
        #expect(model.saveError == nil)
        #expect(SidecarStore().load(for: folder.photo)?.recipe == model.recipe)
        #expect(SidecarStore().load(for: folder.photo)?.metadata?.rating == 4)
        #expect(model.library.item(for: folder.photo)?.hasEdits == true)
        #expect(model.library.item(for: folder.photo)?.metadata.rating == 4)
    }

    @Test func `a rating on a photo whose edit can't be read now says why and is saved once it can`() async throws {
        let folder = Folder()
        try FileManager.default.createDirectory(at: folder.url, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder.url) }
        let json = #"{"format":"app.redlamp.edit","recipe":{"version":3,"processVersion":1,"values":{"basic.exposure":1}}}"#
        try folder.seed(json)
        try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: folder.edit.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: folder.edit.path) }
        let model = EditorModel(engine: StubEngine())
        model.library.insert(LibraryItem(url: folder.photo))

        model.select(folder.photo)
        _ = model.perform(.rating3)
        model.select(folder.other)
        await model.saves.flush()
        try await eventually { model.saveError != nil }
        #expect(model.saveError?.message == "Edits to IMG_0001 can't be saved: permission denied")
        #expect(model.saveError?.canRetry == true)

        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: folder.edit.path)
        model.retrySave()
        await model.saves.flush()
        try await eventually { model.saveError == nil && SidecarStore().load(for: folder.photo)?.metadata?.rating == 3 }
        #expect(model.saveError == nil)
        let saved = try #require(SidecarStore().load(for: folder.photo))
        #expect(saved.metadata?.rating == 3)
        #expect(saved.recipe[.exposure] == 1)
    }

    @Test(arguments: unreadable)
    func `a rating on a photo whose edit doesn't decode says it can't be saved and leaves it`(
        json: String,
    ) async throws {
        let folder = Folder()
        try FileManager.default.createDirectory(at: folder.url, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder.url) }
        try folder.seed(json)
        let before = try folder.contents()
        let model = EditorModel(engine: StubEngine())
        model.library.insert(LibraryItem(url: folder.photo))

        model.select(folder.photo)
        _ = model.perform(.rating3)
        model.select(folder.other)
        await model.saves.flush()
        try await eventually { model.saveError != nil }
        let reason = Self.damaged.contains(json) ? "its edit file is damaged" : "its edit can't be read"
        #expect(model.saveError?.message == "Edits to IMG_0001 can't be saved: \(reason)")
        #expect(model.saveError?.canRetry == false)
        try await settle()
        #expect(try folder.contents() == before)
        #expect(model.saveBeforeQuitting() == .unsaved([folder.photo]), "quitting says it isn't saved")
        #expect(try folder.contents() == before)
    }

    nonisolated static let protectedRatings = [
        (
            #"{"format":"app.redlamp.edit","recipe":{"version":1,"processVersion":99}}"#,
            "a newer version of Redlamp edited it",
        ),
        (
            #"{"format":"app.redlamp.edit","recipe":{"version":3,"processVersion":1,"values":{"basic.exposure":9}}}"#,
            "it has settings this version doesn't know",
        ),
    ]

    @Test(arguments: protectedRatings)
    func `a rating on a protected photo opened and left says why it can't be saved`(
        json: String, reason: String,
    ) async throws {
        let folder = Folder()
        try FileManager.default.createDirectory(at: folder.url, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder.url) }
        try folder.seed(json)
        let before = try folder.contents()
        let model = EditorModel(engine: StubEngine())
        model.library.insert(LibraryItem(url: folder.photo))

        model.select(folder.photo)
        _ = model.perform(.rating3)
        model.select(folder.other)
        await model.saves.flush()
        try await eventually { model.saveError != nil }
        #expect(model.saveError?.message == "Edits to IMG_0001 can't be saved: \(reason)")
        #expect(model.saveError?.canRetry == false)
        try await settle()
        #expect(try folder.contents() == before)
    }

    @Test func `an edit made while its folder is away is saved once it is back`() async throws {
        let folder = Folder()
        try FileManager.default.createDirectory(at: folder.url, withIntermediateDirectories: true)
        let away = folder.url.appendingPathExtension("away")
        defer {
            try? FileManager.default.removeItem(at: folder.url)
            try? FileManager.default.removeItem(at: away)
        }
        let model = EditorModel(engine: StubEngine())
        try await open(folder.photo, in: model)

        try FileManager.default.moveItem(at: folder.url, to: away)
        model.setValue(.exposure, 0.7)
        model.saveNow()
        await model.saves.flush()
        try await eventually { model.saveError != nil }
        #expect(model.saveError?.message == "Edits to IMG_0001 can't be saved: its folder can't be found")

        try FileManager.default.moveItem(at: away, to: folder.url)
        try await eventually { model.saveError == nil }
        #expect(model.saveError == nil)
        #expect(SidecarStore().load(for: folder.photo)?.recipe == model.recipe)
    }

    @Test func `an edit a newer version saved since the photo opened is never saved over`() async throws {
        let folder = Folder()
        try FileManager.default.createDirectory(at: folder.url, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder.url) }
        let model = EditorModel(engine: StubEngine())
        try await open(folder.photo, in: model)
        #expect(!model.isReadOnly)

        try folder.seed(#"{"format":"app.redlamp.edit","recipe":{"version":999,"processVersion":1}}"#)
        let before = try folder.contents()
        model.setValue(.exposure, 0.6)
        model.saveNow()
        await model.saves.flush()
        try await eventually { model.isReadOnly }
        #expect(model.readOnlyReason == .writtenByNewerVersion)
        #expect(model.saveError?.message
            == "Edits to IMG_0001 can't be saved: a newer version of Redlamp changed it since it opened")
        #expect(model.saveError?.canRetry == false)
        model.setValue(.exposure, 0.2)
        model.saveNow()
        await model.saves.flush()
        #expect(try folder.contents() == before)
    }

    @Test func `the notice says when edits from another Mac are waiting to be merged`() {
        let model = EditorModel(engine: StubEngine())
        #expect(model.notice == nil)
        model.hasUnmergedEdits = true
        #expect(model.notice == "Edits from another Mac couldn't be merged here  ·  They're kept as they are")
        model.readOnlyReason = .unreadable
        #expect(model.notice == "This photo's edit file can't be read  ·  Changes won't be saved")
        model.readOnlyReason = .damaged
        #expect(model.notice == "This photo's edit file is damaged  ·  Changes won't be saved")
    }

    @Test func `Start Over keeps a damaged edit aside in the sidecar and opens the photo with a new one`() async throws {
        let folder = Folder()
        try FileManager.default.createDirectory(at: folder.url, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder.url) }
        let damaged = try #require(Self.damaged.first)
        try folder.seed(damaged)
        let model = EditorModel(engine: StubEngine())
        model.library.insert(LibraryItem(url: folder.photo))

        try await open(folder.photo, in: model)
        #expect(model.readOnlyReason == .damaged)
        #expect(model.canStartOver)
        let visit = model.currentVisit
        model.startOver()
        try await eventually { !model.isReadOnly }
        #expect(!model.isReadOnly)
        #expect(!model.canStartOver)
        #expect(model.currentVisit != visit, "a new visit")
        #expect(model.recipe[.exposure] == 0)

        model.setValue(.exposure, 0.5)
        model.saveNow()
        await model.saves.flush()
        try await eventually { SidecarStore().load(for: folder.photo)?.recipe[.exposure] == 0.5 }
        #expect(SidecarStore().load(for: folder.photo)?.recipe[.exposure] == 0.5)
        let copies = try folder.contents().filter { $0.key.contains("edit.damaged-") }
        #expect(copies.count == 1)
        #expect(copies.first?.value == Data(damaged.utf8))
        #expect(model.saveError == nil)
    }

    @Test func `Start Over isn't offered for an edit that doesn't decode`() async throws {
        let folder = Folder()
        try FileManager.default.createDirectory(at: folder.url, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder.url) }
        try folder.seed(#require(Self.unreadable.first))
        let before = try folder.contents()
        let model = EditorModel(engine: StubEngine())

        try await open(folder.photo, in: model)
        #expect(model.readOnlyReason == .unreadable)
        #expect(!model.canStartOver)
        model.startOver()
        try await settle()
        #expect(model.isReadOnly)
        #expect(try folder.contents() == before)
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
