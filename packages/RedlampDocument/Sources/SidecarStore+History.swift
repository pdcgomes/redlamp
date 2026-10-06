import Foundation
import RedlampEngineAPI

/// History sessions in the sidecar package: one file each in `history/`, beside the edit.
public extension SidecarStore {
    /// The photo's history sessions, newest first, with their mask bitmaps loaded. Session files
    /// this build can't read are left out.
    func loadHistory(for image: URL) -> [HistorySession] {
        let sidecar = url(for: image)
        return (try? Self.reading(sidecar) { Self.decodeHistory(inSidecar: $0) }) ?? []
    }
}

extension SidecarStore {
    static func historyFiles(in sidecar: URL) -> [URL] {
        let directory = sidecar.appending(path: historyDirectory)
        let names = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
        return names.filter { $0.hasSuffix(".json") }.sorted().map { directory.appending(path: $0) }
    }

    static func historySummary(_ file: URL) -> HistoryFile.Summary? {
        (try? Data(contentsOf: file)).flatMap { try? JSONDecoder.sidecar.decode(HistoryFile.Summary.self, from: $0) }
    }

    private static func decodeHistory(inSidecar sidecar: URL) -> [HistorySession] {
        // Steps share bitmaps: each file is read once.
        var loaded: [String: Data?] = [:]
        let bitmap = { (sha: String) -> Data? in
            if let data = loaded[sha] {
                return data
            }
            let data = try? Data(contentsOf: bitmapURL(sha, inSidecar: sidecar))
            loaded[sha] = data
            return data
        }
        return historyFiles(in: sidecar).compactMap { file -> HistorySession? in
            guard var session = try? HistorySession(decoding: Data(contentsOf: file)) else { return nil }
            for index in session.steps.indices {
                session.steps[index].recipe.loadMaskBitmaps(bitmap)
            }
            return session
        }
        .sorted { $0.started > $1.started }
    }

    /// Writes the open session's file, or removes it while the session has no edits, and the
    /// files of its unsaved sessions; with `clearsHistory`, removes every other session's
    /// instead. Returns whether anything changed.
    @discardableResult
    static func writeHistory(of sidecar: Sidecar, in package: URL) throws -> Bool {
        let fileManager = FileManager.default
        let directory = package.appending(path: historyDirectory)
        let name = sidecar.session.map { "\($0.id.uuidString).json" }
        var changed = false
        if sidecar.clearsHistory {
            for file in historyFiles(in: package) where file.lastPathComponent != name {
                try fileManager.removeItem(at: file)
                changed = true
            }
        }
        if !sidecar.clearsHistory {
            for earlier in sidecar.unsavedSessions where earlier.hasEdits && earlier.id != sidecar.session?.id {
                changed = try writeSession(earlier, in: package) || changed
            }
        }
        guard let session = sidecar.session, let name else { return changed }
        let file = directory.appending(path: name)
        guard session.hasEdits else {
            guard fileManager.fileExists(atPath: file.path) else { return changed }
            try fileManager.removeItem(at: file)
            return true
        }
        return try writeSession(session, in: package) || changed
    }

    /// Writes `session`'s file unless it holds that already. Returns whether it wrote it.
    private static func writeSession(_ session: HistorySession, in package: URL) throws -> Bool {
        let directory = package.appending(path: historyDirectory)
        let file = directory.appending(path: "\(session.id.uuidString).json")
        let data = try session.encoded()
        let existing = try? Data(contentsOf: file)
        guard existing != data else { return false }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try data.write(to: file, options: .atomic)
        if existing == nil {
            pruneHistory(in: package, keeping: file)
        }
        return true
    }

    /// Removes the oldest sessions beyond `keptSessions`, never `current` or a file this build
    /// can't read.
    private static func pruneHistory(in package: URL, keeping current: URL) {
        let others = historyFiles(in: package).filter { $0.lastPathComponent != current.lastPathComponent }
        let dated = others.compactMap { file -> (file: URL, started: Date)? in
            guard let summary = historySummary(file), (summary.version ?? 1) <= HistorySession.formatVersion,
                  let started = summary.started
            else { return nil }
            return (file, started)
        }
        for old in dated.sorted(by: { $0.started > $1.started }).dropFirst(keptSessions - 1) {
            try? FileManager.default.removeItem(at: old.file)
        }
    }

    /// Adds the sessions of a conflicting copy that `package` lacks, with the bitmaps they use.
    static func copyHistory(from other: URL, into package: URL) throws {
        guard isPackage(package), isPackage(other) else { return }
        let fileManager = FileManager.default
        for file in historyFiles(in: other) {
            let target = package.appending(path: historyDirectory).appending(path: file.lastPathComponent)
            guard !fileManager.fileExists(atPath: target.path) else { continue }
            for sha in historySummary(file)?.bitmaps ?? [] {
                let bitmap = bitmapURL(sha, inSidecar: package)
                guard !fileManager.fileExists(atPath: bitmap.path),
                      let png = try? Data(contentsOf: bitmapURL(sha, inSidecar: other))
                else { continue }
                try fileManager.createDirectory(
                    at: bitmap.deletingLastPathComponent(),
                    withIntermediateDirectories: true,
                )
                try png.write(to: bitmap, options: .atomic)
            }
            try fileManager.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(contentsOf: file).write(to: target, options: .atomic)
        }
    }
}
