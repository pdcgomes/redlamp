import Foundation

public extension NamingFields {
    /// The fields of photos `ids` as `reader`'s index holds them, in that order, leaving out the IDs it
    /// doesn't have. Keywords take a lookup a photo, so they're read only when `keywords`.
    static func read(
        _ ids: [Int64], from reader: some IndexQueries, keywords: Bool = true,
    ) throws -> [(id: Int64, fields: NamingFields)] {
        var cameras: [Int64: (name: String, make: String?, model: String?)] = [:]
        try reader.database.cached("SELECT id, name, make, model FROM cameras").forEachRow { row in
            cameras[row.int64(at: 0)] = (row.string(at: 1) ?? "", row.string(at: 2), row.string(at: 3))
        }
        let lenses = try reader.lensNames()
        var folders: [Int64: String] = [:]
        var found: [(id: Int64, fields: NamingFields)] = []
        found.reserveCapacity(ids.count)
        for id in ids {
            guard let photo = try reader.photo(id: id) else { continue }
            let folder: String
            if let path = folders[photo.folder] {
                folder = path
            } else {
                folder = try reader.folder(id: photo.folder)?.path ?? ""
                folders[photo.folder] = folder
            }
            let camera = photo.camera.flatMap { cameras[$0] }
            try found.append((id, NamingFields(
                photo: photo, folder: folder, camera: camera?.name, cameraMake: camera?.make,
                cameraModel: camera?.model, lens: photo.lens.flatMap { lenses[$0] },
                keywords: keywords ? reader.keywords(forPhoto: id) : [],
            )))
        }
        return found
    }
}

public extension NamingJob {
    /// A job renaming photos `ids` of `index` where they are, in that order (leaving out IDs the index
    /// doesn't have), with the files beside them as `fileSystem` lists their folders, or as the index
    /// has them where a folder can't be listed; and the IDs of the job's photos.
    static func renaming(
        _ ids: [Int64], in index: LibraryIndex, fileSystem: any LibraryFileSystem = LocalFileSystem(),
        keywords: Bool = true,
    ) async throws -> (job: NamingJob, ids: [Int64]) {
        let found = try await index.read { reader in try NamingFields.read(ids, from: reader, keywords: keywords) }
        var existing: [String: Set<String>] = [:]
        var unlisted: [String] = []
        for folder in Set(found.map(\.fields.folder)) {
            do {
                let entries = try fileSystem.contentsOfDirectory(at: URL(fileURLWithPath: folder, isDirectory: true))
                existing[folder] = Set(entries.map(\.name))
            } catch {
                unlisted.append(folder)
            }
        }
        if !unlisted.isEmpty {
            let indexed = try await index.read { [unlisted] reader in
                try unlisted.map { folder in
                    try (
                        folder,
                        reader.folder(path: folder).map { try reader.photos(inFolder: $0.id).map(\.name) } ?? [],
                    )
                }
            }
            for (folder, names) in indexed {
                existing[folder] = Set(names)
            }
        }
        return (NamingJob(found.map { NamingPhoto($0.fields) }, existing: existing), found.map(\.id))
    }
}
