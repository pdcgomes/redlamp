import Foundation
import RedlampEngineAPI

/// What the filmstrip shows of a sidecar: whether the photo is edited, and its rating, flag
/// and label.
public struct SidecarSummary: Sendable, Hashable {
    public var hasEdits: Bool
    public var metadata: PhotoMetadata

    public init(hasEdits: Bool = false, metadata: PhotoMetadata = PhotoMetadata()) {
        self.hasEdits = hasEdits
        self.metadata = metadata
    }
}

public extension SidecarStore {
    /// The badge-level summary of the image's sidecar, from its `edit.json` alone: no mask
    /// bitmaps, history or conflict resolution, and no file coordination. That is safe because
    /// the JSON is only ever replaced atomically (on its own or with the whole package). Nil when
    /// there is no sidecar or it can't be read. Don't call it for a sidecar iCloud Drive hasn't
    /// downloaded: reading it would wait for the download.
    func summary(for image: URL) -> SidecarSummary? {
        Self.summary(atSidecar: locator.readURL(for: image))
    }

    /// The summary of the sidecar at `sidecar`, a package or a single file, as `summary(for:)`
    /// reads it.
    static func summary(atSidecar sidecar: URL) -> SidecarSummary? {
        guard let data = (try? Data(contentsOf: sidecar.appending(path: editFile)))
            ?? (try? Data(contentsOf: sidecar))
        else { return nil }
        struct Probe: Decodable {
            var recipe: EditRecipe
            var metadata: PhotoMetadata?
        }
        guard let probe = try? JSONDecoder.sidecar.decode(Probe.self, from: data) else { return nil }
        return SidecarSummary(hasEdits: !probe.recipe.isPristine, metadata: probe.metadata ?? PhotoMetadata())
    }
}
