import Foundation
import RedlampDocument
import RedlampEngineAPI
import Testing
@testable import RedlampLibrary

/// The sidecar's `originalName` (LIB-26) as `SidecarStore` keeps it.
struct FileSidecarTests {
    @Test func `the original name survives a round trip, a rating changed and a merge, and keeps its sidecar`() throws {
        let folder = try TemporaryFolder()
        let image = folder.url.appending(path: "Wedding-001.CR3")
        let store = SidecarStore()
        try store.save(
            Sidecar(
                recipe: EditRecipe(),
                metadata: PhotoMetadata(originalName: "IMG_0001.CR3"),
                modified: FileSandbox.date(),
            ),
            for: image,
        )
        let json = try JSONDecoder().decode(JSONValue.self, from: Data(contentsOf: store.editURL(for: image)))
        guard case let .object(edit) = json, case let .object(metadata)? = edit["metadata"] else {
            Issue.record("no metadata in \(json)")
            return
        }
        #expect(metadata["originalName"] == .string("IMG_0001.CR3"))
        #expect(store.load(for: image)?.metadata?.originalName == "IMG_0001.CR3")
        #expect(store.summary(for: image)?.metadata.originalName == "IMG_0001.CR3")

        try Library.writeMetadata(for: image, store: store) { $0.rating = 4 }
        let rated = try #require(store.load(for: image))
        #expect(rated.metadata?.rating == 4 && rated.metadata?.originalName == "IMG_0001.CR3")

        try Library.writeMetadata(for: image, store: store) { $0.rating = 0 }
        #expect(store.load(for: image)?.metadata?.originalName == "IMG_0001.CR3", "the name alone keeps the sidecar")
        #expect(!PhotoMetadata(originalName: "IMG_0001.CR3").isEmpty)

        // Another Mac recorded the name while this one changed the rating.
        let base = Sidecar(recipe: EditRecipe(), metadata: PhotoMetadata(rating: 1))
        var theirs = base
        theirs.metadata?.originalName = "DSC_0001.NEF"
        var ours = base
        ours.metadata?.rating = 5
        let merged = SidecarStore.merge(ours, theirs, base: base, opened: base)
        #expect(merged.metadata?.rating == 5 && merged.metadata?.originalName == "DSC_0001.NEF")

        let written = #"{"recipe": {}, "metadata": {"rating": 2, "originalName": "IMG_0009.JPG"}}"#
        let decoded = try JSONDecoder().decode(Sidecar.self, from: Data(written.utf8))
        #expect(decoded.metadata?.originalName == "IMG_0009.JPG" && decoded.metadata?.unknownFields.isEmpty == true)
    }
}
