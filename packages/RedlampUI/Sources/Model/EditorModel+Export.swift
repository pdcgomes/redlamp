import Foundation
import RedlampDocument
import RedlampEngineAPI

extension EditorModel {
    /// Renders the open photo as `settings` describe and writes it to `url`, replacing any
    /// file there that isn't a photo. The photo and its edit are taken before the first
    /// suspension, and the render fails rather than export another photo opened in the meantime.
    public func export(_ settings: ExportSettings, to url: URL) async throws {
        guard let info else { throw EngineError.noImageOpen }
        let source = info.url
        let request = settings.stillRequest(recipe: unobservedRecipe, source: source, size: info.pixelSize)
        setExportStatus("Exporting \(info.fileName)…", clearAfter: nil)
        do {
            let image = try await engine.renderStill(request)
            try await Task.detached(priority: .userInitiated) {
                let metadata = ExportMetadata.properties(
                    from: source,
                    policy: settings.metadata,
                    recipe: request.recipe,
                )
                try ImageExporter.write(image, to: url, settings: settings, metadata: metadata, source: source)
            }.value
        } catch {
            setExportStatus(nil, clearAfter: nil)
            throw error
        }
        setExportStatus("Exported \(url.lastPathComponent)", clearAfter: .seconds(3))
    }

    private func setExportStatus(_ status: String?, clearAfter delay: Duration?) {
        exportStatusTask?.cancel()
        exportStatus = status
        guard let delay else { return }
        exportStatusTask = Task { [weak self] in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled else { return }
            self?.exportStatus = nil
        }
    }
}
