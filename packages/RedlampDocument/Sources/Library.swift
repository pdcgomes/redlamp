import Foundation
import RedlampEngineAPI

public enum Library {
    /// Supported images directly inside `folder`, sorted by name like Finder.
    public static func images(in folder: URL) -> [URL] {
        ((try? FolderScanner.list(folder))?.photos ?? []).map(\.url)
    }

    /// Updates only the culling metadata of an image's sidecar, keeping its edits. Throws,
    /// changing nothing, if the sidecar is protected (see `SidecarStore.protection(for:)`).
    public static func writeMetadata(
        _ metadata: PhotoMetadata,
        for image: URL,
        store: SidecarStore = SidecarStore(),
    ) throws {
        switch store.protection(for: image) {
        case .writtenByNewerVersion: throw SidecarStoreError.writtenByNewerVersion(store.url(for: image))
        case .unreadable: throw SidecarStoreError.unreadable(store.url(for: image))
        case nil: break
        }
        var sidecar = store.load(for: image) ?? Sidecar(recipe: EditRecipe())
        sidecar.metadata = metadata
        sidecar.modified = Date()
        if sidecar.isPristine {
            store.delete(for: image)
        } else {
            try store.save(sidecar, for: image)
        }
    }
}
