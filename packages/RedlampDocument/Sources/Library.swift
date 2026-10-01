import Foundation
import RedlampEngineAPI

public enum Library {
    /// Supported images directly inside `folder`, sorted by name like Finder.
    public static func images(in folder: URL) -> [URL] {
        let files = (try? FileManager.default.contentsOfDirectory(
            at: folder,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles],
        )) ?? []
        return files
            .filter(SupportedFormats.isSupported)
            .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
    }

    /// Whether a sidecar with edits exists for the image.
    public static func hasEdits(_ image: URL, store: SidecarStore = SidecarStore()) -> Bool {
        store.load(for: image).map { !$0.recipe.isPristine } ?? false
    }

    /// Edit state and culling metadata for the filmstrip.
    public static func summary(
        _ image: URL,
        store: SidecarStore = SidecarStore(),
    ) -> (hasEdits: Bool, metadata: PhotoMetadata) {
        guard let sidecar = store.load(for: image) else { return (false, PhotoMetadata()) }
        return (!sidecar.recipe.isPristine, sidecar.metadata ?? PhotoMetadata())
    }

    /// Updates only the culling metadata of an image's sidecar, keeping its edits.
    public static func writeMetadata(
        _ metadata: PhotoMetadata,
        for image: URL,
        store: SidecarStore = SidecarStore(),
    ) throws {
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
