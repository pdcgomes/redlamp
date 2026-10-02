#if os(macOS)
    import CoreServices
    import Foundation

    /// Reports the directories that changed anywhere beneath a set of folders, coalesced: one
    /// FSEvents stream for all of them, so a shoot being copied in arrives as a few batches rather
    /// than an event per file. FSEvents doesn't see changes made on another Mac to a network volume;
    /// those folders are polled instead (see `FolderLibrary`).
    public final class FolderWatcher: @unchecked Sendable {
        /// Guarded by `lock`: the stream isn't `Sendable`.
        private var stream: FSEventStreamRef?
        private let lock = NSLock()
        private let handler: @Sendable ([String]) -> Void
        private let queue = DispatchQueue(label: "app.redlamp.folder-watcher", qos: .utility)

        /// Starts watching `paths`; `handler` gets the changed directories (without a trailing
        /// slash) on a background queue.
        public init(paths: [String], latency: TimeInterval = 0.3, handler: @escaping @Sendable ([String]) -> Void) {
            self.handler = handler
            guard !paths.isEmpty else { return }
            var context = FSEventStreamContext(
                version: 0, info: Unmanaged.passUnretained(self).toOpaque(), retain: nil, release: nil,
                copyDescription: nil,
            )
            let callback: FSEventStreamCallback = { _, info, count, paths, _, _ in
                guard let info else { return }
                let watcher = Unmanaged<FolderWatcher>.fromOpaque(info).takeUnretainedValue()
                let array = unsafeBitCast(paths, to: NSArray.self) as? [String] ?? []
                let directories = array.prefix(count)
                    .map { $0.hasSuffix("/") && $0.count > 1 ? String($0.dropLast()) : $0 }
                watcher.handler(Array(Set(directories)))
            }
            let flags = UInt32(kFSEventStreamCreateFlagUseCFTypes | kFSEventStreamCreateFlagWatchRoot)
            guard let created = FSEventStreamCreate(
                nil, callback, &context, paths as CFArray, FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
                latency, flags,
            ) else { return }
            FSEventStreamSetDispatchQueue(created, queue)
            FSEventStreamStart(created)
            lock.withLock { stream = created }
        }

        public func stop() {
            lock.withLock {
                guard let created = stream else { return }
                FSEventStreamStop(created)
                FSEventStreamInvalidate(created)
                FSEventStreamRelease(created)
                stream = nil
            }
        }

        deinit {
            stop()
        }
    }
#endif
