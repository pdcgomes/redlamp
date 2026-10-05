import Foundation
import RedlampEngineAPI

/// Lists a folder and every folder below it through a `LibraryFileSystem`, `width` listings at
/// once on threads of its own (each blocks on the volume, which Swift's cooperative pool must
/// not). Sidecar packages, other packages and hidden folders aren't walked into.
enum FolderWalk {
    /// Calls `visit` on the listing thread with each folder's path below the root (`""` for the
    /// root) and its entries, in no particular order. The first error stops the walk and is thrown.
    static func walk(
        _ root: URL, fileSystem: any LibraryFileSystem, width: Int,
        visit: @escaping @Sendable (String, [FileEntry]) -> Void,
    ) async throws {
        let workers = max(width, 1)
        let walk = Walk(root: root, fileSystem: fileSystem, visit: visit, workers: workers)
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
            walk.finished = { continuation.resume(with: $0) }
            for _ in 0 ..< workers {
                let thread = Thread { walk.work() }
                thread.qualityOfService = .userInitiated
                thread.start()
            }
        }
    }

    static func isFolder(_ entry: FileEntry) -> Bool {
        entry.isDirectory && !entry.isPackage && !entry.name.lowercased().hasSuffix(".redlamp")
    }

    static func isPhoto(_ entry: FileEntry) -> Bool {
        !entry.isDirectory && SupportedFormats
            .isSupported(extension: (entry.name as NSString).pathExtension.lowercased())
    }

    /// The folders waiting to be listed and the threads listing them, under one condition.
    private final class Walk: @unchecked Sendable {
        let root: URL
        let fileSystem: any LibraryFileSystem
        let visit: @Sendable (String, [FileEntry]) -> Void
        /// Set before the threads start.
        var finished: ((Result<Void, any Error>) -> Void)?
        /// Threads still working.
        private var workers: Int
        private let condition = NSCondition()
        private var waiting = [""]
        private var listing = 0
        private var error: (any Error)?

        init(
            root: URL, fileSystem: any LibraryFileSystem, visit: @escaping @Sendable (String, [FileEntry]) -> Void,
            workers: Int,
        ) {
            self.root = root
            self.fileSystem = fileSystem
            self.visit = visit
            self.workers = workers
        }

        func work() {
            while let path = next() {
                let folder = path.isEmpty ? root : root.appending(path: path, directoryHint: .isDirectory)
                let result = Result { try fileSystem.contentsOfDirectory(at: folder) }
                if case let .success(entries) = result {
                    visit(path, entries)
                }
                condition.lock()
                listing -= 1
                switch result {
                case let .success(entries):
                    waiting += entries.filter(FolderWalk.isFolder).map { path.isEmpty ? $0.name : path + "/" + $0.name }
                case let .failure(failure):
                    error = error ?? failure
                }
                condition.broadcast()
                condition.unlock()
            }
            condition.lock()
            workers -= 1
            let outcome: Result<Void, any Error>? = workers > 0 ? nil : error.map { .failure($0) } ?? .success(())
            condition.unlock()
            if let outcome {
                finished?(outcome)
            }
        }

        /// The next folder to list, waiting while other threads may still find some; nil once
        /// none are left or the walk has failed.
        private func next() -> String? {
            condition.lock()
            defer { condition.unlock() }
            while error == nil {
                if let path = waiting.popLast() {
                    listing += 1
                    return path
                }
                if listing == 0 {
                    return nil
                }
                condition.wait()
            }
            return nil
        }
    }
}
