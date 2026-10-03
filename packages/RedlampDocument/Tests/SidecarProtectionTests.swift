import Foundation
import RedlampDocument
import RedlampEngineAPI
import Testing

/// A sidecar this build can't read, or can't open now, is never saved over or deleted.
struct SidecarProtectionTests {
    /// Edits this build can't decode, though no version number says a newer Redlamp wrote them:
    /// an enum value it doesn't know, a truncated file, and a value of the wrong type.
    static let unreadable = [
        #"{"format":"app.redlamp.edit","recipe":{"version":1,"processVersion":1,"treatment":"infrared"}}"#,
        #"{"format":"app.redlamp.edit","recipe":{"version":1,"processVersion":1,"values":{"basic.expo"#,
        #"{"format":"app.redlamp.edit","recipe":{"version":1,"processVersion":1,"values":{"basic.exposure":"+1"}}}"#,
    ]

    @Test(arguments: unreadable)
    func `a sidecar this build can't read is never saved over or deleted`(json: String) throws {
        let (image, cleanup) = try temporaryImage()
        defer { cleanup() }
        let store = SidecarStore()
        let package = store.url(for: image)
        try FileManager.default.createDirectory(at: package, withIntermediateDirectories: false)
        try Data(json.utf8).write(to: store.editURL(for: image))

        #expect(store.load(for: image) == nil)
        #expect(store.protection(for: image) == .unreadable)
        #expect(throws: SidecarStoreError.unreadable(package)) {
            try store.save(Sidecar(recipe: EditRecipe()), for: image)
        }
        store.delete(for: image)
        #expect(throws: SidecarStoreError.unreadable(package)) {
            try Library.writeMetadata(PhotoMetadata(rating: 2), for: image, store: store)
        }
        #expect(throws: SidecarStoreError.unreadable(package)) {
            try Library.writeMetadata(PhotoMetadata(), for: image, store: store)
        }
        #expect(try Data(contentsOf: store.editURL(for: image)) == Data(json.utf8))
    }

    @Test func `a package without its edit is written over`() throws {
        let (image, cleanup) = try temporaryImage()
        defer { cleanup() }
        let store = SidecarStore()
        try FileManager.default.createDirectory(at: store.url(for: image), withIntermediateDirectories: false)
        #expect(store.protection(for: image) == nil)
        var recipe = EditRecipe()
        recipe[.exposure] = 0.5
        try store.save(Sidecar(recipe: recipe), for: image)
        #expect(store.load(for: image)?.recipe[.exposure] == 0.5)
    }

    /// An edit that is there but can't be opened (no permission, an I/O error, or iCloud Drive
    /// offline) isn't an edit that is missing.
    @Test(arguments: [true, false])
    func `an edit that can't be opened is never saved over or deleted`(inPackage: Bool) throws {
        let (image, cleanup) = try temporaryImage()
        defer { cleanup() }
        let store = SidecarStore()
        let sidecar = store.url(for: image)
        if inPackage {
            try FileManager.default.createDirectory(at: sidecar, withIntermediateDirectories: false)
        }
        let edit = store.editURL(for: image)
        let json = Data(#"{"format":"app.redlamp.edit","recipe":{"version":3,"processVersion":1}}"#.utf8)
        try json.write(to: edit)
        try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: edit.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: edit.path) }

        #expect(store.protection(for: image) == .unreadable)
        #expect(throws: SidecarStoreError.unreadable(sidecar)) {
            try store.save(Sidecar(recipe: EditRecipe()), for: image)
        }
        #expect(throws: SidecarStoreError.unreadable(sidecar)) {
            try store.saveOrRemove(Sidecar(recipe: EditRecipe()), for: image)
        }
        #expect(throws: SidecarStoreError.unreadable(sidecar)) {
            try Library.writeMetadata(PhotoMetadata(), for: image, store: store)
        }
        store.delete(for: image)
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: edit.path)
        #expect(try Data(contentsOf: edit) == json)
    }

    private func temporaryImage() throws -> (URL, () -> Void) {
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return (directory.appending(path: "IMG_0001.ARW"), { try? FileManager.default.removeItem(at: directory) })
    }
}
