import Foundation
import RedlampDocument
import RedlampEngineAPI
import Synchronization

public enum FixtureError: Error, CustomStringConvertible {
    /// The folder holds a fixture made from another spec, seed or raws.
    case differentFixture(String)
    /// The fixture's volume can't clone files (it isn't APFS); copying every raw would fill it.
    case cannotClone(String, Int32)
    case cannotWrite(String, Int32)
    case cannotEncode(String)

    public var description: String {
        switch self {
        case let .differentFixture(path):
            "\(path) holds another fixture (see its manifest.json): choose another folder"
        case let .cannotClone(path, code):
            "can't clone a raw to \(path) (\(String(cString: strerror(code)))): fixtures with raws need an APFS volume"
        case let .cannotWrite(path, code): "can't write \(path): \(String(cString: strerror(code)))"
        case let .cannotEncode(path): "ImageIO can't encode \(path)"
        }
    }
}

extension LibraryFixture {
    /// What writing a fixture did.
    public struct WriteSummary: Sendable {
        public let manifest: FixtureManifest
        /// Photos this run wrote, and those that were already there.
        public let written: Int
        public let skipped: Int
    }

    /// Photos written together by one thread.
    private static let batch = 32

    /// Every folder's photos in batches, interleaved so that every folder is written at the same
    /// pace: a folder's files are created one at a time, so the threads writing at once should be
    /// in as many folders as they can.
    private func batches() -> [(folder: Int, photos: Range<Int>)] {
        folders.indices.flatMap { folder in
            let photos = folders[folder].photos
            let count = (photos.count + Self.batch - 1) / Self.batch
            return (0 ..< count).map { batch in
                let start = photos.lowerBound + batch * Self.batch
                return (
                    key: (Double(batch) + 0.5) / Double(count),
                    folder: folder,
                    photos: start ..< min(start + Self.batch, photos.upperBound),
                )
            }
        }
        .sorted { ($0.key, $0.folder) < ($1.key, $1.folder) }
        .map { ($0.folder, $0.photos) }
    }

    /// Writes the fixture into `root` on every core, then its manifest. What's already there is
    /// kept, so a write that was interrupted is finished by running it again; a folder holding
    /// another fixture's manifest is refused. `progress` is called, from any thread, with the
    /// photos done so far.
    public func write(to root: URL, progress: (@Sendable (Int) -> Void)? = nil) throws -> WriteSummary {
        if let existing = try? FixtureManifest.load(from: root),
           existing.spec != spec || existing.rawSources != rawSources.map(\.name) {
            throw FixtureError.differentFixture(root.path)
        }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let writer = try FixtureWriter(
            root: root.path, sources: cloneSources(in: root), rawSources: rawSources,
            images: FixtureImages.shared.get(),
        )
        let paths = allFolderPaths
        var made = Set<String>()
        for path in paths {
            let url = root.appending(path: path, directoryHint: .isDirectory)
            if !FileManager.default.fileExists(atPath: url.path) {
                try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
                made.insert(path)
            }
        }
        let existing = Set(paths).subtracting(made)

        struct Progress {
            var next = 0
            var tally: Tally
            var written = 0
            var skipped = 0
            var error: (any Error)?
        }
        let batches = batches()
        let state = Mutex(Progress(tally: Tally(queries: FixtureQuery.corpus.count)))
        let workers = DispatchGroup()
        for _ in 0 ..< max(8, 3 * CoreCounts.performance) {
            workers.enter()
            Thread {
                while let batch = state.withLock({ state -> (folder: Int, photos: Range<Int>)? in
                    guard state.error == nil, state.next < batches.count else { return nil }
                    state.next += 1
                    return batches[state.next - 1]
                }) {
                    let folder = folders[batch.folder]
                    let indices = batch.photos
                    let checking = existing.contains(folder.path)
                    var tally = Tally(queries: FixtureQuery.corpus.count)
                    var written = 0
                    var failure: (any Error)?
                    for index in indices {
                        let photo = photo(at: index, in: folder)
                        tally.add(photo)
                        do {
                            if try writer.write(photo, checking: checking) {
                                written += 1
                            }
                        } catch {
                            failure = error
                            break
                        }
                    }
                    let done = state.withLock { state -> Int in
                        state.tally.add(tally)
                        state.written += written
                        state.skipped += indices.count - written
                        state.error = state.error ?? failure
                        return state.written + state.skipped
                    }
                    progress?(done)
                }
                workers.leave()
            }.start()
        }
        workers.wait()
        let finished = state.withLock { $0 }
        if let error = finished.error {
            throw error
        }
        let manifest = manifest(finished.tally)
        try manifest.write(to: root)
        return WriteSummary(manifest: manifest, written: finished.written, skipped: finished.skipped)
    }

    /// The files raws are cloned from: the sources, or copies of them in the fixture's hidden
    /// `_sources` folder when the fixture is on another volume, which a clone can't reach.
    private func cloneSources(in root: URL) throws -> [String] {
        guard let first = rawSources.first else { return [] }
        let probe = root.path + "/.clone-probe"
        unlink(probe)
        if clonefile(first.url.path, probe, 0) == 0 {
            unlink(probe)
            return rawSources.map(\.url.path)
        }
        guard errno == EXDEV else { throw FixtureError.cannotClone(root.path, errno) }
        var folder = root.appending(path: Self.sourcesFolder, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        var hidden = URLResourceValues()
        hidden.isHidden = true
        try folder.setResourceValues(hidden)
        return try rawSources.map { source in
            let copy = folder.appending(path: source.name)
            let size = (try? FileManager.default.attributesOfItem(atPath: copy.path)[.size] as? NSNumber)?.int64Value
            if size != source.size {
                try? FileManager.default.removeItem(at: copy)
                try FileManager.default.copyItem(at: source.url, to: copy)
            }
            return copy.path
        }
    }
}

/// Writes one photo's files: the photo (a raw's clone with its dates rewritten, or a small JPEG
/// or HEIC carrying the photo's EXIF, TIFF, GPS and IPTC), its `.redlamp` sidecar and its other
/// app's `.xmp`. Files are written in place: creating a file costs more than writing it (a
/// rename doubled the cost), so a write that was interrupted is found instead by its size, or for
/// a raw by its date, when the folder is written again.
struct FixtureWriter: Sendable {
    let root: String
    /// The files raws are cloned from, by source index.
    let sources: [String]
    let rawSources: [RawSource]
    let images: FixtureImages

    /// Writes what `photo` is missing, and returns whether that included the photo itself.
    /// With `checking` false, the folder was made by this write and nothing in it is checked.
    func write(_ photo: FixturePhoto, checking: Bool) throws -> Bool {
        let folder = root + "/" + photo.folder
        let path = folder + "/" + photo.name
        let wrote = if let source = photo.source {
            try clone(source, captured: photo.captured, to: path, checking: checking)
        } else {
            try place(images.data(for: photo), at: path, checking: checking)
        }
        if let sidecar = photo.sidecar {
            let package = path + ".redlamp"
            guard mkdir(package, 0o755) == 0 || errno == EEXIST else { throw FixtureError.cannotWrite(package, errno) }
            try place(
                Self.sidecar(sidecar, captured: photo.captured), at: package + "/" + SidecarStore.editFile,
                checking: checking,
            )
        }
        if let xmp = photo.xmp {
            try place(Data(Self.xmp(xmp).utf8), at: folder + "/" + photo.xmpName, checking: checking)
        }
        return wrote
    }

    // MARK: - Files

    /// Writes `data` at `path`, unless `checking` finds a file of its size there.
    @discardableResult
    private func place(_ data: Data, at path: String, checking: Bool) throws -> Bool {
        if checking, size(of: path) == data.count {
            return false
        }
        let fd = open(path, O_WRONLY | O_CREAT | O_TRUNC | O_CLOEXEC, 0o644)
        guard fd >= 0 else { throw FixtureError.cannotWrite(path, errno) }
        let written = data.withUnsafeBytes { Darwin.write(fd, $0.baseAddress, $0.count) }
        let code = errno
        close(fd)
        guard written == data.count else { throw FixtureError.cannotWrite(path, code) }
        return true
    }

    /// Clones the raw and writes its capture date over each of its source's dates. A clone
    /// already there is kept if it has its date.
    private func clone(_ source: Int, captured: FixtureDate, to path: String, checking: Bool) throws -> Bool {
        let date = Array(captured.exif.utf8)
        let offsets = rawSources[source].dateOffsets
        var cloned = false
        if checking, let size = size(of: path) {
            if size != rawSources[source].size {
                unlink(path)
            } else if date == read(path, at: offsets[0], count: date.count) {
                return false
            } else {
                cloned = true
            }
        }
        if !cloned, clonefile(sources[source], path, 0) != 0 {
            throw FixtureError.cannotClone(path, errno)
        }
        let fd = open(path, O_WRONLY | O_CLOEXEC)
        guard fd >= 0 else { throw FixtureError.cannotWrite(path, errno) }
        let rewritten = offsets.allSatisfy { pwrite(fd, date, date.count, off_t($0)) == date.count }
        let code = errno
        close(fd)
        guard rewritten else { throw FixtureError.cannotWrite(path, code) }
        return true
    }

    private func size(of path: String) -> Int? {
        var info = stat()
        return stat(path, &info) == 0 ? Int(info.st_size) : nil
    }

    private func read(_ path: String, at offset: Int, count: Int) -> [UInt8] {
        let fd = open(path, O_RDONLY | O_CLOEXEC)
        guard fd >= 0 else { return [] }
        defer { close(fd) }
        var bytes = [UInt8](repeating: 0, count: count)
        return pread(fd, &bytes, count, off_t(offset)) == count ? bytes : []
    }

    // MARK: - Sidecars

    /// `edit.json` as Redlamp writes it, so `SidecarStore` reads it as it reads its own.
    static func sidecar(_ sidecar: FixturePhoto.Sidecar, captured: FixtureDate) throws -> Data {
        var recipe = EditRecipe()
        if sidecar.edited {
            recipe[.exposure] = 0.35
        }
        let value = Sidecar(
            recipe: recipe,
            metadata: PhotoMetadata(rating: sidecar.rating, flag: sidecar.flag, label: sidecar.label),
            modified: captured.date.addingTimeInterval(86400),
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        return try encoder.encode(value)
    }

    /// Another app's sidecar: rating, label and keywords, as Lightroom Classic writes them.
    static func xmp(_ xmp: FixturePhoto.OtherXMP) -> String {
        let label = xmp.label.map { "\n   xmp:Label=\"\($0.rawValue.capitalized)\"" } ?? ""
        let keywords = xmp.keywords.map { "     <rdf:li>\(escaped($0))</rdf:li>" }.joined(separator: "\n")
        return """
        <?xpacket begin="\u{FEFF}" id="W5M0MpCehiHzreSzNTczkc9d"?>
        <x:xmpmeta xmlns:x="adobe:ns:meta/">
         <rdf:RDF xmlns:rdf="http://www.w3.org/1999/02/22-rdf-syntax-ns#">
          <rdf:Description rdf:about=""
            xmlns:xmp="http://ns.adobe.com/xap/1.0/"
            xmlns:dc="http://purl.org/dc/elements/1.1/"
           xmp:Rating="\(xmp.rating)"\(label)>
           <dc:subject>
            <rdf:Bag>
        \(keywords)
            </rdf:Bag>
           </dc:subject>
          </rdf:Description>
         </rdf:RDF>
        </x:xmpmeta>
        <?xpacket end="w"?>

        """
    }

    private static func escaped(_ text: String) -> String {
        text.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
    }
}
