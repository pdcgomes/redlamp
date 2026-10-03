import Foundation
import RedlampEngineAPI

public enum Library {
    /// Supported images directly inside `folder`, sorted by name like Finder.
    public static func images(in folder: URL) -> [URL] {
        ((try? FolderScanner.list(folder))?.photos ?? []).map(\.url)
    }

    /// Makes `change` to the culling metadata of an image's sidecar as it is on disk, keeping
    /// its edits, history and the rest of its metadata. Throws, changing nothing, if the sidecar
    /// is protected (see `SidecarStore.protection(for:)`).
    public static func writeMetadata(
        for image: URL,
        store: SidecarStore = SidecarStore(),
        _ change: (inout PhotoMetadata) -> Void,
    ) throws {
        var sidecar = store.load(for: image) ?? Sidecar(recipe: EditRecipe())
        var metadata = sidecar.metadata ?? PhotoMetadata()
        change(&metadata)
        sidecar.metadata = metadata
        sidecar.modified = Date()
        try store.saveOrRemove(sidecar, for: image)
    }
}
