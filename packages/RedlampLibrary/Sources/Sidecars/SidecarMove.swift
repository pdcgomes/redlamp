import Foundation
import RedlampDocument
import Synchronization

/// Moving a root's sidecars from one place to the other: what would move, and what's in the way.
public struct SidecarMovePlan: Sendable, Hashable, Codable {
    /// A sidecar, where it is and where it goes.
    public struct Item: Sendable, Hashable, Codable {
        /// The photo's path below the root.
        public var photo: String
        public var source: URL
        public var target: URL
    }

    /// A photo whose sidecar is in both places.
    public struct Conflict: Sendable, Hashable, Codable {
        public var photo: String
        public var beside: URL
        public var onThisMac: URL
    }

    public var root: Int64
    public var rootPath: String
    public var destination: RootRecord.Sidecars
    public var items: [Item]
    /// The move doesn't start while there are any.
    public var conflicts: [Conflict]
}

/// What a move did.
public struct SidecarMoveOutcome: Sendable, Hashable {
    public var moved = 0
    /// Sidecars gone from where they were before they could be moved.
    public var gone = 0
    /// Sidecars that turned up in both places while the move ran, left as they are.
    public var conflicts: [String] = []
    /// Sidecars that couldn't be moved, by photo, and why; they stay where they were.
    public var failed: [String: String] = [:]

    public init() {}
}

extension RootRecord.Sidecars: Codable {}

public extension LibrarySidecars {
    /// The journal of a move in progress, until LIB-26's file operations journal holds it.
    var moveJournal: URL {
        paths.root.appending(path: "Sidecar Move.json")
    }

    /// What moving `root`'s sidecars to `destination` would do: every `.redlamp` sidecar in the
    /// other place, and the photos whose sidecar is in both. Other apps' `.xmp` never move.
    func planMove(ofRoot root: Int64, to destination: RootRecord.Sidecars) async throws -> SidecarMovePlan {
        let (record, locatorRoot) = try await knownRoot(root)
        let rootURL = URL(fileURLWithPath: record.path, isDirectory: true)
        let locator = SidecarLocator(folder: paths.sidecars, roots: [locatorRoot])
        let beside = try await Self.besideSidecars(below: rootURL).sidecars
        let mac = try await Self.macSidecars(of: locatorRoot, in: paths.sidecars)
        var items: [SidecarMovePlan.Item] = []
        var conflicts: [SidecarMovePlan.Conflict] = []
        for photo in (destination == .onThisMac ? beside : mac).sorted() {
            let image = rootURL.appending(path: photo)
            guard let onThisMac = locator.onThisMac(image) else { continue }
            let besidePhoto = SidecarLocator.besidePhoto(image)
            if beside.contains(photo), mac.contains(photo) {
                conflicts.append(SidecarMovePlan.Conflict(photo: photo, beside: besidePhoto, onThisMac: onThisMac))
            } else {
                let (source, target) = destination == .onThisMac ? (besidePhoto, onThisMac) : (onThisMac, besidePhoto)
                items.append(SidecarMovePlan.Item(photo: photo, source: source, target: target))
            }
        }
        return SidecarMovePlan(
            root: root, rootPath: record.path, destination: destination, items: items, conflicts: conflicts,
        )
    }

    /// Moves the plan's sidecars, after recording it in the journal and setting the root to keep
    /// them at the destination: each is copied beside where it goes, checked byte for byte, put in
    /// place without replacing anything, and only then removed where it was. Throws, moving nothing,
    /// when the plan has conflicts. A move a forced quit interrupted is finished by `resumeMove`.
    func move(_ plan: SidecarMovePlan, progress: (@Sendable (Int, Int) -> Void)? = nil) async throws
        -> SidecarMoveOutcome {
        guard plan.conflicts.isEmpty else { throw LibrarySidecarsError.conflicts(plan.conflicts) }
        let journal = moveJournal
        try await LibraryIndex.offCaller {
            try FileManager.default.createDirectory(
                at: journal.deletingLastPathComponent(), withIntermediateDirectories: true,
            )
            try JSONEncoder().encode(plan).write(to: journal, options: .atomic)
        }
        return try await finish(plan, progress: progress)
    }

    /// Finishes the move in the journal, if there's one: what was moved stays moved, and the rest
    /// moves as `move` would.
    func resumeMove(progress: (@Sendable (Int, Int) -> Void)? = nil) async throws -> SidecarMoveOutcome? {
        let journal = moveJournal
        let plan = try await LibraryIndex.offCaller { () -> SidecarMovePlan? in
            guard FileManager.default.fileExists(atPath: journal.path) else { return nil }
            return try JSONDecoder().decode(SidecarMovePlan.self, from: Data(contentsOf: journal))
        }
        guard let plan else { return nil }
        return try await finish(plan, progress: progress)
    }

    /// The root is found by its path: an index made again since the move began gives it another ID.
    private func finish(_ plan: SidecarMovePlan, progress: (@Sendable (Int, Int) -> Void)?) async throws
        -> SidecarMoveOutcome {
        let root = try await index.read { try $0.root(path: plan.rootPath)?.id } ?? plan.root
        try await setPlacement(plan.destination, forRoot: root)
        let journal = moveJournal
        return try await LibraryIndex.offCaller {
            let outcome = Mutex(SidecarMoveOutcome())
            let done = Atomic(0)
            DispatchQueue.concurrentPerform(iterations: plan.items.count) { index in
                let item = plan.items[index]
                let result = Result { try SidecarMover.coordinatedMove(item.source, to: item.target) }
                outcome.withLock { outcome in
                    switch result {
                    case .success(.moved): outcome.moved += 1
                    case .success(.gone): outcome.gone += 1
                    case .success(.conflict): outcome.conflicts.append(item.photo)
                    case let .failure(error): outcome.failed[item.photo] = String(describing: error)
                    }
                }
                progress?(done.add(1, ordering: .relaxed).newValue, plan.items.count)
            }
            try? FileManager.default.removeItem(at: journal)
            var finished = outcome.withLock { $0 }
            finished.conflicts.sort()
            return finished
        }
    }
}

/// Moves one sidecar, a package or a single file, without ever replacing one.
enum SidecarMover {
    enum Outcome {
        case moved
        case gone
        case conflict
    }

    enum Failure: Error, CustomStringConvertible {
        case notCopied(URL)

        var description: String {
            switch self {
            case let .notCopied(url): "the copy at \(url.path) isn't the same as the sidecar"
            }
        }
    }

    /// `move(_:to:)` under file coordination, as every sidecar read and write is.
    static func coordinatedMove(_ source: URL, to target: URL) throws -> Outcome {
        var outcome: Swift.Result<Outcome, any Error>?
        var coordinationError: NSError?
        NSFileCoordinator(filePresenter: nil).coordinate(
            writingItemAt: source, options: .forDeleting, writingItemAt: target, options: .forReplacing,
            error: &coordinationError,
        ) { source, target in
            outcome = Swift.Result { try move(source, to: target) }
        }
        if let coordinationError {
            throw coordinationError
        }
        return try (outcome ?? .failure(CocoaError(.fileWriteUnknown))).get()
    }

    /// Copies `source` beside `target` under a hidden name, checks the copy, renames it to
    /// `target`, then removes `source`. Run again after a forced quit, it picks up where that left
    /// off: a sidecar found at both, the same, was copied, and only its source is removed.
    static func move(_ source: URL, to target: URL) throws -> Outcome {
        let fileManager = FileManager.default
        switch (fileManager.fileExists(atPath: source.path), fileManager.fileExists(atPath: target.path)) {
        case (false, true):
            return .moved
        case (false, false):
            return .gone
        case (true, true):
            guard same(source, target) else { return .conflict }
            try remove(source)
            return .moved
        case (true, false):
            break
        }
        let folder = target.deletingLastPathComponent()
        try fileManager.createDirectory(at: folder, withIntermediateDirectories: true)
        removeStaging(of: target)
        let staging = folder.appending(path: ".\(target.lastPathComponent).\(UUID().uuidString)")
        do {
            try fileManager.copyItem(at: source, to: staging)
            guard same(source, staging) else { throw Failure.notCopied(staging) }
            try fileManager.moveItem(at: staging, to: target)
        } catch {
            try? fileManager.removeItem(at: staging)
            if fileManager.fileExists(atPath: target.path) {
                return .conflict
            }
            throw error
        }
        try remove(source)
        return .moved
    }

    /// Whether two sidecars hold the same files with the same bytes.
    static func same(_ lhs: URL, _ rhs: URL) -> Bool {
        guard let left = contents(lhs), let right = contents(rhs) else { return false }
        return left == right
    }

    /// Every file in a sidecar by its path inside it, or the single file's bytes under "".
    private static func contents(_ sidecar: URL) -> [String: Data]? {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: sidecar.path, isDirectory: &isDirectory) else { return nil }
        guard isDirectory.boolValue else { return (try? Data(contentsOf: sidecar)).map { ["": $0] } }
        guard let paths = FileManager.default.subpaths(atPath: sidecar.path) else { return nil }
        var files: [String: Data] = [:]
        for path in paths {
            let file = sidecar.appending(path: path)
            var isFolder: ObjCBool = false
            guard FileManager.default.fileExists(atPath: file.path, isDirectory: &isFolder) else { return nil }
            if !isFolder.boolValue {
                guard let data = try? Data(contentsOf: file) else { return nil }
                files[path] = data
            }
        }
        return files
    }

    /// Removes a sidecar by renaming it to a hidden name first, as `SidecarStore` does, so an
    /// interrupted removal leaves it whole or gone; the hidden name is an interrupted save's, which
    /// opening its folder removes.
    private static func remove(_ sidecar: URL) throws {
        let hidden = sidecar.deletingLastPathComponent()
            .appending(path: ".\(sidecar.lastPathComponent).\(UUID().uuidString)")
        try FileManager.default.moveItem(at: sidecar, to: hidden)
        try FileManager.default.removeItem(at: hidden)
    }

    /// Removes copies an interrupted move left beside `target`.
    private static func removeStaging(of target: URL) {
        let folder = target.deletingLastPathComponent()
        let prefix = ".\(target.lastPathComponent)."
        let names = (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []
        for name in names
            where name.hasPrefix(prefix) && UUID(uuidString: String(name.dropFirst(prefix.count))) != nil {
            try? FileManager.default.removeItem(at: folder.appending(path: name))
        }
    }
}
