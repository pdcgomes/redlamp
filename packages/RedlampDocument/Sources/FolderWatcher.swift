#if os(macOS)
    import CoreServices
    import Foundation

    /// Reports the directories that changed anywhere beneath a set of folders, coalesced: one
    /// FSEvents stream for all of them, so a shoot being copied in arrives as a few batches rather
    /// than an event per file. FSEvents doesn't see changes made on another Mac to a network volume;
    /// those folders are polled instead (see `FolderLibrary`).
    ///
    /// Every stream lives on one serial queue, from its start to its release, and its callbacks run
    /// there: starting and stopping a stream waits on FSEvents' service, for seconds while it's busy,
    /// so neither waits for it, and a watcher made before another is stopped starts first, so no
    /// change falls between them. The callback reaches what the stream retains, never the watcher,
    /// which may be gone by the time a callback queued before `stop` runs.
    public final class FolderWatcher: Sendable {
        /// What the stream's callback reaches, retained by the stream for as long as it lives.
        private final class Receiver: @unchecked Sendable {
            let handler: @Sendable ([String]) -> Void
            /// Used only on `queue`: set once the watcher stops, after which no change is reported.
            var stopped = false
            /// Used only on `queue`.
            var stream: FSEventStreamRef?

            init(_ handler: @escaping @Sendable ([String]) -> Void) {
                self.handler = handler
            }
        }

        private static let queue = DispatchQueue(label: "app.redlamp.folder-watcher", qos: .utility)
        private let receiver: Receiver

        /// Starts watching `paths`; `handler` gets the changed directories (without a trailing
        /// slash) on a background queue. Returns at once: the stream starts on the watchers' queue.
        public init(paths: [String], latency: TimeInterval = 0.3, handler: @escaping @Sendable ([String]) -> Void) {
            let receiver = Receiver(handler)
            self.receiver = receiver
            guard !paths.isEmpty else { return }
            Self.queue.async {
                guard !receiver.stopped else { return }
                receiver.stream = Self.start(paths, latency: latency, receiver: receiver)
            }
        }

        /// Stops watching once the watchers' queue reaches it, after what it's asked to do before: from then on,
        /// `handler` isn't called. Returns at once.
        public func stop() {
            let receiver = receiver
            Self.queue.async {
                receiver.stopped = true
                guard let stream = receiver.stream else { return }
                receiver.stream = nil
                FSEventStreamStop(stream)
                FSEventStreamInvalidate(stream)
                FSEventStreamRelease(stream)
            }
        }

        deinit {
            stop()
        }

        /// A stream of `paths` started on `queue`, reaching `receiver`; nil when FSEvents refuses.
        private static func start(_ paths: [String], latency: TimeInterval, receiver: Receiver) -> FSEventStreamRef? {
            dispatchPrecondition(condition: .onQueue(queue))
            var context = FSEventStreamContext(
                version: 0, info: Unmanaged.passUnretained(receiver).toOpaque(),
                retain: { info in
                    guard let info else { return nil }
                    _ = Unmanaged<Receiver>.fromOpaque(info).retain()
                    return info
                },
                release: { info in
                    guard let info else { return }
                    Unmanaged<Receiver>.fromOpaque(info).release()
                },
                copyDescription: nil,
            )
            let callback: FSEventStreamCallback = { _, info, count, paths, _, _ in
                guard let info else { return }
                let receiver = Unmanaged<Receiver>.fromOpaque(info).takeUnretainedValue()
                guard !receiver.stopped else { return }
                let array = unsafeBitCast(paths, to: NSArray.self) as? [String] ?? []
                let directories = array.prefix(count)
                    .map { $0.hasSuffix("/") && $0.count > 1 ? String($0.dropLast()) : $0 }
                receiver.handler(Array(Set(directories)))
            }
            let flags = UInt32(kFSEventStreamCreateFlagUseCFTypes | kFSEventStreamCreateFlagWatchRoot)
            guard let created = FSEventStreamCreate(
                nil, callback, &context, paths as CFArray, FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
                latency, flags,
            ) else { return nil }
            FSEventStreamSetDispatchQueue(created, queue)
            guard FSEventStreamStart(created) else {
                FSEventStreamInvalidate(created)
                FSEventStreamRelease(created)
                return nil
            }
            return created
        }
    }
#endif
