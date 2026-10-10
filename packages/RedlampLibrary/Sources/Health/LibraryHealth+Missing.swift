import Foundation

/// What Locate… found at a file chosen for a missing photo (DEC-59).
public struct MissingLocation: Sendable, Hashable {
    /// Why a photo can't be relinked to the file chosen.
    public enum Problem: Sendable, Hashable, CustomStringConvertible {
        /// The file isn't in any of the library's folders.
        case notInLibrary
        /// The file shows something else: its content key isn't the photo's.
        case differs
        /// The photo was never read, so nothing is known of what it shows to match.
        case unknownContent
        /// Another missing photo had the file's place: found there again once its folder is listed.
        case anotherPhoto
        /// The photo isn't missing any more.
        case found

        public var description: String {
            switch self {
            case .notInLibrary: "it isn't in any of the library's folders"
            case .differs: "it isn't the same photo: its content differs"
            case .unknownContent: "the photo was never read, so it can't be matched"
            case .anotherPhoto: "another missing photo was there, and is found there again"
            case .found: "the photo has been found already"
            }
        }
    }

    /// The photo with the file chosen; nil when it can't be relinked to it, `problem` saying why.
    public var photo: PhotoRelink?
    public var problem: Problem?
    /// The other missing photos from the photo's folder found beside the file, under their names, with their content.
    public var others: [PhotoRelink]

    public init(photo: PhotoRelink? = nil, problem: Problem? = nil, others: [PhotoRelink] = []) {
        self.photo = photo
        self.problem = problem
        self.others = others
    }
}

public extension LibraryHealth {
    /// Locate…'s look at the file at `url` for missing photo `id` (DEC-59): whether it's the photo, by its content key
    /// (the file's size and first 64 KiB, all that's read of it), and the other missing photos of the photo's folder
    /// found beside it, under their names, with their content.
    func locate(_ id: Int64, at url: URL) async throws -> MissingLocation {
        let path = LibraryIndexer.path(url)
        let (photo, missing, inLibrary, holder) = try await index.read { reader in
            let photo = try reader.photo(id: id)
            let missing = try photo.map { try reader.missingPhotos(inFolder: $0.folder) } ?? []
            return try (
                photo,
                missing.filter { $0.id != id },
                reader.root(containing: path) != nil,
                reader.photo(path: path),
            )
        }
        guard let photo, photo.state.contains(.missing) else { return MissingLocation(problem: .found) }
        guard inLibrary else { return MissingLocation(problem: .notInLibrary) }
        if let holder, holder.id != id, holder.state.contains(.missing) {
            return MissingLocation(problem: .anotherPhoto)
        }
        guard let key = photo.contentKey else { return MissingLocation(problem: .unknownContent) }
        let (fileSystem, folder) = (operations.fileSystem, FilePlanner.split(path).folder)
        let held = try await index.read { reader in
            try Set(missing.compactMap { try reader.photo(path: folder + "/" + $0.name) }.filter {
                $0.state.contains(.missing)
            }.map(\.name))
        }
        return try await LibraryIndex.offCaller {
            guard Self.contentKey(at: path, fileSystem) == key else { return MissingLocation(problem: .differs) }
            let others = missing.compactMap { other -> PhotoRelink? in
                let beside = folder + "/" + other.name
                guard !held.contains(other.name), let wanted = other.contentKey,
                      Self.contentKey(at: beside, fileSystem) == wanted
                else { return nil }
                return PhotoRelink(id: other.id, path: beside)
            }
            return MissingLocation(photo: PhotoRelink(id: id, path: path), others: others)
        }
    }

    /// Locate…'s batch: `relinks`' missing photos relinked to the files they were found as, with what that leaves the
    /// Missing check's `findings`, which one Undo takes back. It runs as the other checks' batches do (`run`), checked
    /// again first: each photo still missing, where it was, as it was.
    func planRelink(_ relinks: [PhotoRelink], in findings: HealthFindings) async throws -> HealthPlan {
        let batch = try await operations.planRelink(relinks)
        let relinked = Set(batch.steps.filter { $0.kind == .relink }.flatMap { $0.photos.map(\.id) })
        let picked = findings.findings.filter { relinked.contains($0.photo) }
        return try await HealthPlan(
            check: .missing, batch: batch, findings: picked, leftOut: [], expected: expected(picked),
            chosen: relinked,
        )
    }

    /// Remove: the batch that takes the missing photos `ids` out of the library with nothing moved (DEC-59), which one
    /// Undo puts back, checked again as the other checks' batches are; those `findings` don't list are left out.
    func planRemoval(_ ids: [Int64], in findings: HealthFindings) async throws -> HealthPlan {
        let wanted = Set(ids)
        let picked = findings.findings.filter { wanted.contains($0.photo) }
        let batch = try await operations.planRemoval(ofMissing: picked.map(\.photo))
        return try await HealthPlan(
            check: .missing, batch: batch, findings: picked, leftOut: [], expected: expected(picked),
            chosen: Set(picked.map(\.photo)),
        )
    }

    /// The content key of the file at `path`, a file and not a folder, from its first 64 KiB; nil when it can't be
    /// read.
    private static func contentKey(at path: String, _ fileSystem: any LibraryFileSystem) -> Data? {
        let url = URL(fileURLWithPath: path)
        guard let entry = try? fileSystem.attributes(of: url), !entry.isDirectory,
              let head = try? fileSystem.read(url, range: 0 ..< min(Int(entry.size), ContentKey.headLength))
        else { return nil }
        return ContentKey(fileSize: Int(entry.size), head: head).data
    }
}

extension IndexQueries {
    /// The photos of `folder` missing from it (DEC-59), by name, as `photos_missing` finds them.
    func missingPhotos(inFolder folder: Int64) throws -> [PhotoRecord] {
        let statement = try database.cached("""
        SELECT \(IndexColumns.photo) FROM photos WHERE folder = ? AND state & \(PhotoRecord.State.missing.rawValue) != 0
        ORDER BY name
        """)
        try statement.bind(folder, at: 1)
        return try statement.map(PhotoRecord.init)
    }
}
