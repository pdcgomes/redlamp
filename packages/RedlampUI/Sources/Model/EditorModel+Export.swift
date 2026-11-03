import Foundation
import RedlampDocument
import RedlampEngineAPI
import RedlampLibrary

extension EditorModel {
    /// Whether Export and Export with Previous have photos to act on: the photo open, or in the Library the photos
    /// selected there, which aren't open once another is chosen in the grid and export with the edits their sidecars
    /// hold.
    var canExport: Bool {
        info != nil || module == .library && selection != nil
    }

    /// Renders the open photo as `settings` describe and writes it to `url`, replacing any
    /// file there that isn't a photo. The photo and its edit are taken before the first
    /// suspension, and the render fails rather than export another photo opened in the meantime.
    /// The library's fields for the photo go with it under `settings.metadata`, when the library has it, and a
    /// version's own in their place when a version is open.
    public func export(_ settings: ExportSettings, to url: URL) async throws {
        guard let info else { throw EngineError.noImageOpen }
        let source = info.url
        let request = settings.stillRequest(recipe: unobservedRecipe, source: source, size: info.pixelSize)
        let core = settings.metadata == .none ? nil : library.service?.core
        let version = openVersion == nil ? nil : photoMetadata
        let files = engine.files
        setExportStatus("Exporting \(info.fileName)…", clearAfter: nil)
        do {
            let image = try await engine.renderStill(request)
            try await Task.detached(priority: .userInitiated) {
                let fields = await Self.exportFields(of: source, core: core, version: version)
                let metadata = ExportMetadata.properties(
                    from: source,
                    reading: files,
                    policy: settings.metadata,
                    recipe: request.recipe,
                    fields: fields,
                )
                try ImageExporter.write(
                    image, to: url, settings: settings, metadata: metadata, source: source, reading: files,
                )
            }.value
        } catch {
            setExportStatus(nil, clearAfter: nil)
            throw error
        }
        setExportStatus("Exported \(url.lastPathComponent)", clearAfter: .seconds(3))
    }

    /// The library's fields for `source`, which its export carries; nil when the library doesn't have it. A version's
    /// export, with the version's `metadata`, carries the version's own in their place (EDT-09).
    nonisolated static func exportFields(
        of source: URL, core: LibraryCore?, version metadata: PhotoMetadata? = nil,
    ) async -> ExportMetadata.Fields? {
        guard let core, let id = await LibraryService.indexIDs(of: [source], in: core.index)[source] else { return nil }
        let fields = try? await LibraryMetadata(index: core.index, paths: core.paths).exportFields(ofPhoto: id)
        guard let metadata else { return fields }
        let keywords = (try? KeywordDefinitions.load(from: KeywordDefinitions.url(in: core.paths)))
            ?? KeywordDefinitions()
        return versionFields(metadata, over: fields, keywords: keywords, labels: core.xmpSettings.conventions.labels)
    }

    /// `photo`, the fields a photo's export carries, with the version's `metadata` in their place: its rating and
    /// label, and its title, caption, creator, copyright, location and keywords, exported as `keywords` says, where it
    /// holds them.
    nonisolated static func versionFields(
        _ metadata: PhotoMetadata, over photo: ExportMetadata.Fields?, keywords: KeywordDefinitions,
        labels: XMPLabelNames,
    ) -> ExportMetadata.Fields {
        let own = ExportMetadata.Fields(
            metadata, keywords: keywords.exported((metadata.keywords ?? []).compactMap(KeywordPath.init)),
            captured: photo?.captured, labels: labels,
        )
        guard var fields = photo else { return own }
        fields.rating = own.rating
        fields.label = own.label
        if metadata.title != nil {
            fields.title = own.title
        }
        if metadata.caption != nil {
            fields.caption = own.caption
        }
        if metadata.creator != nil {
            fields.creators = own.creators
        }
        if metadata.copyright != nil {
            fields.copyright = own.copyright
        }
        if metadata.location != nil {
            fields.location = own.location
        }
        if metadata.keywords != nil {
            fields.keywords = own.keywords
            fields.keywordPaths = own.keywordPaths
        }
        return fields
    }

    /// Wires the batch exporter to the editor's engine factory, sidecars, saves and looks.
    func connectBatchExport() {
        batchExport.makeEngine = { [weak self] in self?.makeWorkerEngine?() }
        batchExport.sidecars = library.sidecars
        batchExport.saved = { [weak self] url in
            guard let self else { return }
            await saves.wait(for: url)
            await settingsSync.wait(for: url)
        }
        batchExport.baseLook = { [weak self] reference in self?.recipes.library.definition(for: reference) }
        batchExport.fields = { [weak self] url, version in
            await Self.exportFields(of: url, core: self?.library.service?.core, version: version)
        }
        // Photos kept in Apple Photos have their originals downloaded from iCloud as the batch comes to them (LIB-60),
        // a few ahead, each held from the cache's budget while it's written.
        batchExport.needsDownload = { [weak self] url in self?.library.needsDownload(url) ?? false }
        batchExport.downloadAhead = { [weak self] urls in self?.originals?.request(urls, priority: .export) }
        batchExport.cancelDownloads = { [weak self] urls in self?.originals?.cancel(urls) }
        batchExport.beforeExporting = { [weak self] url in
            guard let originals = self?.originals, originals.owns(url) else { return }
            originals.hold(url)
            try await originals.local(url, priority: .export)
        }
        batchExport.afterExporting = { [weak self] url in
            guard let originals = self?.originals, originals.owns(url) else { return }
            originals.release(url)
        }
        batchExport.refusing = { [weak self] file in
            guard self?.library.originals?.owns(file) == true else { return nil }
            return "It's kept in Apple Photos, so it can't be exported beside its original: choose a folder to export "
                + "to in the Export dialog."
        }
        settingsSync.beforeWriting = { [weak self] url in await self?.batchExport.wait(for: url) }
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
