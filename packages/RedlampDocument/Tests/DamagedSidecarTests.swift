import Foundation
import RedlampDocument
import RedlampEngineAPI
import Testing

/// An edit that isn't a JSON object is damaged: never saved over or deleted, only set aside in its
/// sidecar so the photo can start a new edit (DATA-14).
struct DamagedSidecarTests {
    /// A truncated file, an empty one, one that isn't JSON, and JSON that isn't an object.
    static let damaged = [
        #"{"format":"app.redlamp.edit","recipe":{"version":1,"processVersion":1,"values":{"basic.expo"#,
        "",
        "not JSON",
        "[1, 2]",
    ]

    private let named = String(repeating: "a", count: 64)
    private let unnamed = String(repeating: "b", count: 64)

    private func temporaryImage() throws -> (URL, () -> Void) {
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return (directory.appending(path: "IMG_0001.ARW"), { try? FileManager.default.removeItem(at: directory) })
    }

    /// A package for `image` holding `json` as its edit.
    private func seed(_ json: String, for image: URL) throws -> URL {
        let package = SidecarStore().url(for: image)
        try FileManager.default.createDirectory(at: package, withIntermediateDirectories: true)
        try Data(json.utf8).write(to: package.appending(path: SidecarStore.editFile))
        return package
    }

    private func date(second: Int = 0) throws -> Date {
        try #require(DateComponents(
            calendar: Calendar(identifier: .gregorian), year: 2026, month: 10, day: 6, hour: 7, minute: 15,
            second: second,
        ).date)
    }

    private func names(in package: URL) throws -> [String] {
        try FileManager.default.contentsOfDirectory(atPath: package.path).sorted()
    }

    @Test(arguments: damaged)
    func `an edit that isn't a JSON object is damaged, and kept`(json: String) throws {
        let (image, cleanup) = try temporaryImage()
        defer { cleanup() }
        let store = SidecarStore()
        let package = try seed(json, for: image)

        #expect(store.load(for: image) == nil)
        #expect(store.protection(for: image) == .damaged)
        #expect(store.readForEditing(for: image).protection == .damaged)
        #expect(throws: SidecarStoreError.damaged(package)) { try store.loadThrowing(for: image) }
        #expect(throws: SidecarStoreError.damaged(package)) {
            try store.save(Sidecar(recipe: EditRecipe()), for: image)
        }
        #expect(throws: SidecarStoreError.damaged(package)) {
            try store.saveOrRemove(Sidecar(recipe: EditRecipe()), for: image)
        }
        store.delete(for: image)
        #expect(throws: SidecarStoreError.damaged(package)) {
            try Library.writeMetadata(for: image, store: store) { $0.rating = 2 }
        }
        #expect(try Data(contentsOf: store.editURL(for: image)) == Data(json.utf8))
    }

    @Test func `Start Over sets the damaged edit aside in its package, and keeps the masks it names`() throws {
        let (image, cleanup) = try temporaryImage()
        defer { cleanup() }
        let store = SidecarStore()
        let json = #"{"format":"app.redlamp.edit","recipe":{"masks":[{"bitmap":{"sha256":"\#(named)""#
        let package = try seed(json, for: image)
        let masks = package.appending(path: SidecarStore.masksDirectory)
        try FileManager.default.createDirectory(at: masks, withIntermediateDirectories: true)
        for sha256 in [named, unnamed] {
            try Data("png".utf8).write(to: masks.appending(path: "\(sha256).png"))
        }

        let copy = try #require(try store.setAsideDamagedEdit(for: image, at: date()))
        #expect(copy == package.appending(path: "edit.damaged-2026-10-06-071500.json"))
        #expect(try Data(contentsOf: copy) == Data(json.utf8))
        #expect(try names(in: package) == ["edit.damaged-2026-10-06-071500.json", "masks"])
        #expect(store.protection(for: image) == nil)
        #expect(store.load(for: image) == nil)

        var recipe = EditRecipe()
        recipe[.exposure] = 0.5
        try store.save(Sidecar(recipe: recipe), for: image)
        #expect(store.load(for: image)?.recipe[.exposure] == 0.5)
        #expect(try Data(contentsOf: copy) == Data(json.utf8))
        #expect(FileManager.default.fileExists(atPath: masks.appending(path: "\(named).png").path))
        #expect(!FileManager.default.fileExists(atPath: masks.appending(path: "\(unnamed).png").path))
    }

    @Test func `a damaged single-file sidecar becomes a package holding it`() throws {
        let (image, cleanup) = try temporaryImage()
        defer { cleanup() }
        let store = SidecarStore()
        let sidecar = store.url(for: image)
        try Data("not JSON".utf8).write(to: sidecar)
        #expect(store.protection(for: image) == .damaged)

        let copy = try #require(try store.setAsideDamagedEdit(for: image, at: date()))
        #expect(copy == sidecar.appending(path: "edit.damaged-2026-10-06-071500.json"))
        #expect(try names(in: sidecar) == ["edit.damaged-2026-10-06-071500.json"])
        #expect(try Data(contentsOf: copy) == Data("not JSON".utf8))
        #expect(store.protection(for: image) == nil)
        let hidden = try FileManager.default.contentsOfDirectory(atPath: sidecar.deletingLastPathComponent().path)
        #expect(hidden.allSatisfy { !$0.hasPrefix(".") }, "nothing left beside it")
    }

    @Test func `setting a damaged edit aside twice in a second keeps both`() throws {
        let (image, cleanup) = try temporaryImage()
        defer { cleanup() }
        let store = SidecarStore()
        let package = try seed("one", for: image)
        try store.setAsideDamagedEdit(for: image, at: date())
        try Data("two".utf8).write(to: package.appending(path: SidecarStore.editFile))
        let second = try #require(try store.setAsideDamagedEdit(for: image, at: date()))
        #expect(second.lastPathComponent == "edit.damaged-2026-10-06-071500-2.json")
        #expect(try Data(contentsOf: second) == Data("two".utf8))
        #expect(try names(in: package).count == 2)
    }

    @Test(arguments: [
        #"{"format":"app.redlamp.edit","recipe":{"version":3,"processVersion":1}}"#,
        #"{"format":"app.redlamp.edit","recipe":{"version":1,"processVersion":1,"treatment":"infrared"}}"#,
        #"{"format":"app.redlamp.edit","recipe":{"version":99,"processVersion":1}}"#,
    ])
    func `only a damaged edit is set aside`(json: String) throws {
        let (image, cleanup) = try temporaryImage()
        defer { cleanup() }
        let store = SidecarStore()
        let package = try seed(json, for: image)
        #expect(try store.setAsideDamagedEdit(for: image) == nil)
        #expect(try names(in: package) == [SidecarStore.editFile])
        #expect(try Data(contentsOf: store.editURL(for: image)) == Data(json.utf8))
    }

    @Test func `a photo without a sidecar has nothing to set aside`() throws {
        let (image, cleanup) = try temporaryImage()
        defer { cleanup() }
        #expect(try SidecarStore().setAsideDamagedEdit(for: image) == nil)
        #expect(!FileManager.default.fileExists(atPath: SidecarStore().url(for: image).path))
    }

    @Test(arguments: [true, false])
    func `removing a sidecar keeps the damaged edits set aside, and the masks they name`(deleting: Bool) throws {
        let (image, cleanup) = try temporaryImage()
        defer { cleanup() }
        let store = SidecarStore()
        let damaged = #"{"recipe":{"masks":[{"bitmap":{"sha256":"\#(named)""#
        let package = try seed(damaged, for: image)
        let masks = package.appending(path: SidecarStore.masksDirectory)
        try FileManager.default.createDirectory(at: masks, withIntermediateDirectories: true)
        try Data("png".utf8).write(to: masks.appending(path: "\(named).png"))
        let copy = try #require(try store.setAsideDamagedEdit(for: image, at: date()))
        var recipe = EditRecipe()
        recipe[.exposure] = 0.5
        try store.save(Sidecar(recipe: recipe), for: image)
        try Data("png".utf8).write(to: masks.appending(path: "\(unnamed).png"))
        #expect(try names(in: package).contains(SidecarStore.editFile))

        if deleting {
            store.delete(for: image)
        } else {
            try store.saveOrRemove(Sidecar(recipe: EditRecipe()), for: image)
        }
        #expect(try names(in: package) == [copy.lastPathComponent, SidecarStore.masksDirectory])
        #expect(try names(in: masks) == ["\(named).png"], "only the masks a damaged edit names")
        #expect(try Data(contentsOf: copy) == Data(damaged.utf8))
        #expect(store.load(for: image) == nil)
        let beside = try FileManager.default.contentsOfDirectory(atPath: package.deletingLastPathComponent().path)
        #expect(beside.allSatisfy { !$0.hasPrefix(".") }, "nothing left beside it")
    }
}
