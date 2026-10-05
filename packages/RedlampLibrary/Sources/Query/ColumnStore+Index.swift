import Foundation

extension IndexQueries {
    /// The column store: the hot-column scan, with the extra columns and the photos with keywords read
    /// beside it, all in ID order, in the reader's one transaction.
    func columnStore() throws -> ColumnStore {
        let extras = try database.prepare("""
        SELECT p.id, p.shutter, \(ColumnEncoding.locationSQL), \(ColumnEncoding.titleSQL), \
        \(ColumnEncoding.captionSQL), \(ColumnEncoding.xmpSQL), p.sidecar_modified FROM photos p ORDER BY p.id
        """)
        let keywords = try database.prepare("SELECT DISTINCT photo FROM photo_keywords ORDER BY photo")
        defer {
            extras.reset()
            keywords.reset()
        }
        var onExtras = try extras.step()
        var onKeywords = try keywords.step()
        var builder = try ColumnStore.Builder(capacity: photoCount())
        try scanHotColumns { hot in
            var row = ColumnStore.Row(hot)
            while onExtras, extras.int64(at: 0) < hot.id {
                onExtras = try extras.step()
            }
            if onExtras, extras.int64(at: 0) == hot.id {
                Self.readExtras(extras, from: 1, into: &row)
            }
            while onKeywords, keywords.int64(at: 0) < hot.id {
                onKeywords = try keywords.step()
            }
            if onKeywords, keywords.int64(at: 0) == hot.id {
                row.details.insert(.keywords)
            }
            builder.add(row)
        }
        return builder.finish()
    }

    /// The rows of photos `ids` the index holds, for `ColumnStore.apply`.
    func columnRows(ids: [Int64]) throws -> [ColumnStore.Row] {
        let statement = try database.cached("""
        SELECT p.id, p.folder, p.captured, p.camera, p.lens, p.rating, p.flag, p.label, p.marked, p.edited, p.iso,
          p.aperture, p.focal, p.kind, p.name, p.shutter, \(ColumnEncoding.locationSQL), \(ColumnEncoding.titleSQL),
          \(ColumnEncoding.captionSQL), \(ColumnEncoding.xmpSQL), p.sidecar_modified, \(ColumnEncoding.keywordsSQL)
        FROM photos p WHERE p.id = ?
        """)
        return try ids.compactMap { id in
            try statement.bind(id, at: 1)
            return try statement.first { row in
                var columns = ColumnStore.Row(HotColumns(
                    id: row.int64(at: 0), folder: row.int64(at: 1), captured: row.optionalDouble(at: 2),
                    camera: row.optionalInt64(at: 3), lens: row.optionalInt64(at: 4), rating: row.int(at: 5),
                    flag: row.int(at: 6), label: row.int(at: 7), marked: row.bool(at: 8), edited: row.bool(at: 9),
                    iso: row.optionalDouble(at: 10), aperture: row.optionalDouble(at: 11),
                    focal: row.optionalDouble(at: 12), kind: row.int(at: 13), name: row.string(at: 14) ?? "",
                ))
                Self.readExtras(row, from: 15, into: &columns)
                if row.bool(at: 21) {
                    columns.details.insert(.keywords)
                }
                return columns
            }
        }
    }

    func photoName(id: Int64) throws -> String? {
        let statement = try database.cached("SELECT name FROM photos WHERE id = ?")
        try statement.bind(id, at: 1)
        return try statement.first { $0.string(at: 0) } ?? nil
    }

    /// Shutter, details and the sidecar's date, from `column` on: as `columnStore`'s extra columns.
    private static func readExtras(_ row: SQLiteStatement, from column: Int32, into columns: inout ColumnStore.Row) {
        columns.shutter = row.optionalDouble(at: column)
        let details: [ColumnStore.Details] = [.location, .title, .caption, .xmp]
        for (offset, detail) in details.enumerated() where row.bool(at: column + 1 + Int32(offset)) {
            columns.details.insert(detail)
        }
        columns.sidecarModified = row.optionalDouble(at: column + 5)
    }
}
