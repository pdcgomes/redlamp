import Foundation
import RedlampDocument
import RedlampEngineAPI
import Testing

/// What a crash or force quit in the middle of a save or delete leaves (DATA-11).
struct SidecarInterruptionTests {
    @Test func `what interrupted saves and deletes left is removed once a minute old`() throws {
        let (image, cleanup) = try temporaryImage()
        defer { cleanup() }
        let store = SidecarStore()
        try store.save(Sidecar(recipe: EditRecipe()), for: image)
        let folder = image.deletingLastPathComponent()
        let old = folder.appending(path: ".IMG_0001.ARW.redlamp.\(UUID().uuidString)")
        let young = folder.appending(path: ".IMG_0001.ARW.redlamp.\(UUID().uuidString)")
        let other = folder.appending(path: ".IMG_0001.ARW.redlamp.backup")
        for directory in [old, young, other] {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
            try Data("{}".utf8).write(to: directory.appending(path: SidecarStore.editFile))
        }
        let twoMinutesAgo = Date(timeIntervalSinceNow: -120)
        for directory in [old, other] {
            try FileManager.default.setAttributes([.modificationDate: twoMinutesAgo], ofItemAtPath: directory.path)
        }

        SidecarStore.removeLeftovers(in: folder)
        let names = try Set(FileManager.default.contentsOfDirectory(atPath: folder.path))
        #expect(names == [store.url(for: image).lastPathComponent, young.lastPathComponent, other.lastPathComponent])
    }

    @Test func `a delete that fails partway leaves the package whole, or nothing in view`() throws {
        let (image, cleanup) = try temporaryImage()
        defer { cleanup() }
        let store = SidecarStore()
        var recipe = EditRecipe()
        recipe.masks = [subjectMask(Data("x".utf8))]
        try store.save(Sidecar(recipe: recipe), for: image)
        let masks = store.url(for: image).appending(path: SidecarStore.masksDirectory)
        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: masks.path)
        let folder = image.deletingLastPathComponent()
        defer {
            for name in (try? FileManager.default.subpathsOfDirectory(atPath: folder.path)) ?? []
                where name.hasSuffix(SidecarStore.masksDirectory) {
                try? FileManager.default.setAttributes(
                    [.posixPermissions: 0o700], ofItemAtPath: folder.appending(path: name).path,
                )
            }
        }

        store.delete(for: image)
        let sidecar = store.url(for: image)
        #expect(
            !FileManager.default.fileExists(atPath: sidecar.path) || store.load(for: image)?.recipe == recipe,
            "a package without its edit loads as no edit",
        )
    }

    @Test func `a save whose history can't be written leaves the edit as it was`() throws {
        let (image, cleanup) = try temporaryImage()
        defer { cleanup() }
        let store = SidecarStore()
        try store.save(Sidecar(recipe: EditRecipe(), metadata: PhotoMetadata(rating: 1)), for: image)
        let before = try Data(contentsOf: store.editURL(for: image))
        try Data().write(to: store.url(for: image).appending(path: SidecarStore.historyDirectory))

        var recipe = EditRecipe()
        recipe[.exposure] = 1
        let session = HistorySession(steps: [
            HistoryStep(action: .open, title: "Opened", recipe: EditRecipe()),
            HistoryStep(action: .adjustment(.exposure), title: "Exposure", recipe: recipe),
        ])
        #expect(throws: (any Error).self) {
            try store.save(Sidecar(recipe: recipe, metadata: PhotoMetadata(rating: 1), session: session), for: image)
        }
        #expect(try Data(contentsOf: store.editURL(for: image)) == before)
    }

    private func subjectMask(_ png: Data) -> MaskLayer {
        MaskLayer(name: "Subject", components: [MaskComponent(shape: .ai(AIMask(
            kind: .subject, provider: "test", revision: 1, analysisHash: "0", center: ImagePoint(x: 0.5, y: 0.5),
            bitmap: MaskBitmap(png: png, width: 4, height: 2), createdAt: Date(timeIntervalSince1970: 1000),
        )))])
    }

    private func temporaryImage() throws -> (URL, () -> Void) {
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return (directory.appending(path: "IMG_0001.ARW"), { try? FileManager.default.removeItem(at: directory) })
    }
}
