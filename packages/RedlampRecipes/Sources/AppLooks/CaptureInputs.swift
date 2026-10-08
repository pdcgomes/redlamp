import Foundation

/// A capture's inputs, however they were gathered (a folder of exports and the kit, or a bench
/// look reference): the chart exports, the kit's own originals, and each photo export with the
/// kit photo it came from. The CLI's `app-import` and the Recipe Lab both read captures from it.
public struct CaptureInputs: Sendable {
    public struct PhotoPair: Sendable {
        public var export: String
        public var exportImage: PixelImage
        public var kitPhoto: String
        public var kitImage: PixelImage
        /// The kit photo's file, so it can be rendered through the engine as the app saw it.
        public var kitFile: URL?
        /// `name`, `content`, or how a bench folder paired it.
        public var matchedBy: String
        public var similarity: Float

        public init(
            export: String,
            exportImage: PixelImage,
            kitPhoto: String,
            kitImage: PixelImage,
            kitFile: URL? = nil,
            matchedBy: String,
            similarity: Float,
        ) {
            self.export = export
            self.exportImage = exportImage
            self.kitPhoto = kitPhoto
            self.kitImage = kitImage
            self.kitFile = kitFile
            self.matchedBy = matchedBy
            self.similarity = similarity
        }
    }

    public var charts: [AppLookImport.Export]
    public var originals: AppLookImport.Originals
    public var photos: [PhotoPair]
    /// Exports that matched no kit photo.
    public var unmatched: [String]
    public var provenance: AppLookReport.Provenance?

    public init(
        charts: [AppLookImport.Export],
        originals: AppLookImport.Originals,
        photos: [PhotoPair] = [],
        unmatched: [String] = [],
        provenance: AppLookReport.Provenance? = nil,
    ) {
        self.charts = charts
        self.originals = originals
        self.photos = photos
        self.unmatched = unmatched
        self.provenance = provenance
    }

    /// The table and spatial effects from the charts, with each photo measured against them.
    public func read() throws -> AppLookImport.Result {
        var result = try AppLookImport.read(charts, sources: originals)
        result.report.add(photos: photos.compactMap { pair in
            PhotoPairAnalysis.analyse(kit: pair.kitImage, export: pair.exportImage, table: result.table).map {
                AppLookReport.Photo(
                    file: pair.export, kitPhoto: pair.kitPhoto, matchedBy: pair.matchedBy,
                    similarity: pair.similarity, measures: $0,
                )
            }
        })
        for name in unmatched {
            result.report.warnings.append("\(name) doesn't match any kit photo")
        }
        result.report.provenance = provenance
        return result
    }
}
