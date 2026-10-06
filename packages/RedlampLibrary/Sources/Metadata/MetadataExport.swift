import Foundation
import RedlampDocument

public extension ExportMetadata.Fields {
    /// What an export of a photo carries of its own (LIB-22): `metadata`, its fields as the library
    /// shows them (its `.redlamp`'s merged with other apps'), its label named in `labels`' set; its
    /// `keywords` as they're exported (LIB-21); and `captured`, its capture time where the library moved
    /// it from the camera's. A reject, a pick and a mark aren't exported, as Lightroom Classic exports
    /// none of them.
    init(
        _ metadata: PhotoMetadata, keywords: ExportedKeywords, captured: ExportMetadata.CaptureTime? = nil,
        labels: XMPLabelNames = .lightroom,
    ) {
        self.init(
            title: XMPFields.text(metadata.title), caption: XMPFields.text(metadata.caption),
            creators: XMPFields.names(metadata.creator), copyright: XMPFields.text(metadata.copyright),
            location: XMPFields.place(metadata.location), keywords: keywords.names,
            keywordPaths: keywords.paths.map(\.names), rating: metadata.rating > 0 ? metadata.rating : nil,
            label: metadata.label.map(labels.name) ?? XMPFields.text(metadata.customLabel), captured: captured,
        )
    }
}

public extension LibraryMetadata {
    /// The fields an export of photo `id` carries, from the index as it is now: the fields its row
    /// shows, merged from its `.redlamp` and other apps' as the indexer and `LibraryXMP` merge them; its
    /// keywords as `Keywords.json` says each is exported, a person's left out unless `people`; its label
    /// in the set the library writes `.xmp` in; and its capture time where its sidecar shifts it or gives
    /// the camera a zone. Nil when the index doesn't have it.
    func exportFields(ofPhoto id: Int64, people: Bool = true) async throws -> ExportMetadata.Fields? {
        let found = try await index.read { reader -> (PhotoRecord, [KeywordPath], XMPSettings)? in
            guard let row = try reader.photo(id: id) else { return nil }
            return try (row, reader.keywords(forPhoto: id).compactMap(KeywordPath.init), XMPSettings(reader))
        }
        guard let found else { return nil }
        let (row, keywords, settings) = found
        let url = KeywordDefinitions.url(in: paths)
        let definitions = try await LibraryIndex.offCaller { KeywordDefinitions.cached(at: url) }
        let captured = row.cameraCaptured == nil ? nil : row.captured.map {
            ExportMetadata.CaptureTime(time: $0, offset: row.capturedOffset)
        }
        return ExportMetadata.Fields(
            PhotoMetadata(shown: row), keywords: definitions.exported(keywords, people: people), captured: captured,
            labels: settings.conventions.labels,
        )
    }

    /// The fields an export of the photo at `photo` carries (see `exportFields(ofPhoto:people:)`); nil
    /// when the index doesn't have it.
    func exportFields(for photo: URL, people: Bool = true) async throws -> ExportMetadata.Fields? {
        let path = LibraryIndexer.path(photo)
        guard let id = try await index.read({ try $0.photo(path: path)?.id }) else { return nil }
        return try await exportFields(ofPhoto: id, people: people)
    }
}
