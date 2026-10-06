import Foundation
import RedlampLibrary

/// `redlamp library trashed` and `put-back`: Recently Trashed (LIB-26), the photos the library's
/// batches moved to the Trash that are still there, from the journal, and Put Back, a batch like the
/// others, journaled and undoable. Each finishes first a batch a forced quit left unfinished.
extension LibraryCommand {
    static func trashed(_ arguments: [String]) async throws {
        let options = try Arguments(arguments, valued: ["--index"])
        guard options.positional.isEmpty, let path = options.value("--index") else {
            throw CLIError(description: "trashed needs --index\n\n\(usage)")
        }
        try await withOperations(path) { operations in
            let photos = try await operations.trashed()
            if options.has("--json") {
                try print(String(decoding: json(photos), as: UTF8.self))
            } else {
                lines(photos).forEach { print($0) }
            }
        }
    }

    static func putBack(_ arguments: [String]) async throws {
        let options = try Arguments(arguments, valued: ["--index", "--batch"])
        let byBatch = options.value("--batch") != nil
        guard let path = options.value("--index"), byBatch == options.positional.isEmpty else {
            throw CLIError(description: "put-back needs photos or --batch, and --index\n\n\(usage)")
        }
        try await withOperations(path) { operations in
            let batch: FileBatch
            if let text = options.value("--batch") {
                batch = try await operations.planPutBack(batch: batchID(text, in: operations.entries()))
            } else {
                let listed = try await operations.trashed()
                batch = try await operations.planPutBack(options.positional.map { try photo($0, in: listed).id })
            }
            try await planned(batch, operations: operations, options: options)
        }
    }

    // MARK: - Choosing

    /// The batch `text` names: its ID, or the first characters of one, as `trashed` prints them.
    private static func batchID(_ text: String, in entries: [FileJournal.Entry]) throws -> UUID {
        if let id = UUID(uuidString: text) {
            return id
        }
        let found = entries.filter { $0.id.uuidString.lowercased().hasPrefix(text.lowercased()) }
        guard found.count == 1, let entry = found.first, text.count >= 4 else {
            throw CLIError(description: found.isEmpty
                ? "no batch \(text) in the journal"
                : "\(text) names \(count(found.count)) batches: give more of its ID")
        }
        return entry.id
    }

    /// The photo of `listed` at `text`: where it was, or where it is in the Trash.
    private static func photo(_ text: String, in listed: [TrashedPhoto]) throws -> TrashedPhoto {
        let path = folded(URL(fileURLWithPath: text).standardizedFileURL.path)
        let found = listed.filter { folded($0.original) == path || folded($0.place) == path }
        guard found.count == 1, let photo = found.first else {
            throw CLIError(description: found.isEmpty
                ? "\(text) isn't in Recently Trashed: redlamp library trashed lists what is"
                : "\(text) was the place of \(count(found.count)) photos in the Trash: name the one by its place, "
                + found.map(\.place).joined(separator: " or "))
        }
        return photo
    }

    /// A path as the volume compares names: in any case, and in either of Unicode's forms.
    private static func folded(_ path: String) -> String {
        path.precomposedStringWithCanonicalMapping.lowercased()
    }

    // MARK: - Printing

    /// The photos by batch, newest first: each where it was, where it is in the Trash, what went with
    /// it and its pair; then how many.
    private static func lines(_ photos: [TrashedPhoto]) -> [String] {
        guard !photos.isEmpty else { return ["Nothing the library moved to the Trash is still there"] }
        let names = Dictionary(photos.map { ($0.id, ($0.original as NSString).lastPathComponent) }) { first, _ in
            first
        }
        var lines: [String] = []
        var batch: UUID?
        for photo in photos {
            if photo.id.batch != batch {
                batch = photo.id.batch
                lines.append("\(photo.trashed.ISO8601Format())  \(photo.title), batch \(photo.id.batch.uuidString)")
            }
            lines.append("  \(photo.original)")
            var about = "in the Trash at \(photo.place)"
            if let folder = photo.folder {
                about += ", in \(folder), which goes back whole"
            }
            if !photo.files.isEmpty {
                about += ", with " + photo.files.map { ($0.original as NSString).lastPathComponent }
                    .joined(separator: ", ")
            }
            if !photo.pair.isEmpty {
                about += "; paired with " + photo.pair.compactMap { names[$0] }.joined(separator: ", ")
            }
            lines.append("    " + about)
        }
        let batches = Set(photos.map(\.id.batch)).count
        lines.append(
            "\(count(photos.count)) photo\(photos.count == 1 ? "" : "s") in the Trash from \(count(batches)) "
                + "batch\(batches == 1 ? "" : "es"): redlamp library put-back <photo>… or --batch <id> puts them back",
        )
        return lines
    }

    private static func json(_ photos: [TrashedPhoto]) throws -> Data {
        struct File: Encodable {
            let role: String
            let original: String
            let place: String
        }
        struct Photo: Encodable {
            let batch: String
            let title: String
            let trashed: Date
            let photo: Int64
            let original: String
            let place: String
            let contentKey: String?
            let files: [File]
            let folder: String?
            let pair: [String]
        }
        let originals = Dictionary(photos.map { ($0.id, $0.original) }) { first, _ in first }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        return try encoder.encode(photos.map { photo in
            Photo(
                batch: photo.id.batch.uuidString, title: photo.title, trashed: photo.trashed, photo: photo.id.photo,
                original: photo.original, place: photo.place,
                contentKey: photo.photo.photo.contentKey.map { $0.map { String(format: "%02x", $0) }.joined() },
                files: photo.files.map { File(role: $0.role.rawValue, original: $0.original, place: $0.place) },
                folder: photo.folder, pair: photo.pair.compactMap { originals[$0] },
            )
        })
    }

    /// `20,000`, whatever the locale.
    private static func count(_ value: Int) -> String {
        value.formatted(.number.locale(Locale(identifier: "en_US")))
    }
}
