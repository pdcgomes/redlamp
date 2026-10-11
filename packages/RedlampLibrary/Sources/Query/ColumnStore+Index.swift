import Foundation

extension IndexQueries {
    /// The part of the column store holding the photos with IDs in `ids`, for `ColumnStore.joining`:
    /// their columns in one pass over the photos in ID order, and whether each has keywords from a
    /// pass beside it. Photos in the folders of `leavingOut` (`removedFolders`) aren't in it.
    func columnStorePart(
        ids: ClosedRange<Int64>, capacity: Int = 0, leavingOut: Set<Int64> = [],
    ) throws -> ColumnStore.Part {
        var part = ColumnStore.Part(capacity: capacity)
        let photos = try database.cached("""
        SELECT \(Self.columnRowSQL) FROM photos p WHERE p.id BETWEEN ?1 AND ?2 ORDER BY p.id
        """)
        let keywords = try database.cached("""
        SELECT DISTINCT photo FROM photo_keywords WHERE photo BETWEEN ?1 AND ?2 ORDER BY photo
        """)
        for statement in [photos, keywords] {
            try statement.bind(ids.lowerBound, at: 1)
            try statement.bind(ids.upperBound, at: 2)
        }
        defer {
            photos.reset()
            keywords.reset()
        }
        var onKeywords = try keywords.step()
        while try photos.step() {
            var row = Self.columnRow(photos)
            if !leavingOut.isEmpty, leavingOut.contains(row.hot.folder) {
                continue
            }
            while onKeywords, keywords.int64(at: 0) < row.hot.id {
                onKeywords = try keywords.step()
            }
            if onKeywords, keywords.int64(at: 0) == row.hot.id {
                row.details.insert(.keywords)
            }
            part.add(row)
        }
        return part
    }

    /// The smallest and largest photo IDs, from the ends of the table; nil when there are none.
    func photoIDs() throws -> ClosedRange<Int64>? {
        try database.cached("SELECT (SELECT min(id) FROM photos), (SELECT max(id) FROM photos)").first { row in
            row.isNull(at: 0) ? nil : row.int64(at: 0) ... row.int64(at: 1)
        } ?? nil
    }

    /// The rows of photos `ids` the index holds, for `ColumnStore.apply`, but those of roots marked
    /// removed, which the store leaves out.
    func columnRows(ids: [Int64]) throws -> [ColumnStore.Row] {
        let statement = try database.cached("""
        SELECT \(Self.columnRowSQL), \(ColumnEncoding.keywordsSQL) FROM photos p WHERE p.id = ?
        """)
        let leftOut = ids.isEmpty ? [] : try removedFolders()
        return try ids.compactMap { id in
            try statement.bind(id, at: 1)
            let found = try statement.first { row in
                var columns = Self.columnRow(row)
                if row.bool(at: Self.columnRowCount) {
                    columns.details.insert(.keywords)
                }
                return columns
            }
            return found.flatMap { leftOut.contains($0.hot.folder) ? nil : $0 }
        }
    }

    func photoName(id: Int64) throws -> String? {
        let statement = try database.cached("SELECT name FROM photos WHERE id = ?")
        try statement.bind(id, at: 1)
        return try statement.first { $0.string(at: 0) } ?? nil
    }

    /// What `columnRow` reads, columns 0 to 35.
    private static var columnRowSQL: String {
        """
        p.id, p.folder, p.captured, p.camera, p.lens, p.rating, p.flag, p.label, p.marked, p.edited, p.iso, \
        p.aperture, p.focal, p.kind, p.name, p.shutter, \(ColumnEncoding.locationSQL), \(ColumnEncoding.titleSQL), \
        \(ColumnEncoding.captionSQL), \(ColumnEncoding.xmpSQL), p.sidecar_modified, p.size, p.modified, p.state, \
        p.creator, p.copyright, p.sublocation, p.city, p.province, p.country, p.country_code, p.custom_label, \
        p.width, p.height, p.widest_aperture, p.focal35
        """
    }

    /// The columns `columnRowSQL` selects.
    private static var columnRowCount: Int32 {
        36
    }

    /// The photo's row as `columnRowSQL` selects it, without keywords.
    private static func columnRow(_ row: SQLiteStatement) -> ColumnStore.Row {
        var columns = ColumnStore.Row(HotColumns(
            id: row.int64(at: 0), folder: row.int64(at: 1), captured: row.optionalDouble(at: 2),
            camera: row.optionalInt64(at: 3), lens: row.optionalInt64(at: 4), rating: row.int(at: 5),
            flag: row.int(at: 6), label: row.int(at: 7), marked: row.bool(at: 8), edited: row.bool(at: 9),
            iso: row.optionalDouble(at: 10), aperture: row.optionalDouble(at: 11), focal: row.optionalDouble(at: 12),
            kind: row.int(at: 13), name: row.string(at: 14) ?? "",
        ))
        columns.shutter = row.optionalDouble(at: 15)
        let details: [ColumnStore.Details] = [.location, .title, .caption, .xmp]
        for (offset, detail) in details.enumerated() where row.bool(at: 16 + Int32(offset)) {
            columns.details.insert(detail)
        }
        columns.sidecarModified = row.optionalDouble(at: 20)
        columns.size = row.int64(at: 21)
        columns.modified = row.optionalDouble(at: 22)
        columns.state = PhotoRecord.State(rawValue: row.int(at: 23))
        columns.creator = row.string(at: 24)
        columns.copyright = row.string(at: 25)
        columns.location = PhotoRecord.storedLocation(
            sublocation: row.string(at: 26), city: row.string(at: 27), province: row.string(at: 28),
            country: row.string(at: 29), countryCode: row.string(at: 30),
        )
        columns.customLabel = row.string(at: 31)
        columns.width = row.optionalInt(at: 32)
        columns.height = row.optionalInt(at: 33)
        columns.widestAperture = row.optionalDouble(at: 34)
        columns.focal35 = row.optionalDouble(at: 35)
        return columns
    }
}
