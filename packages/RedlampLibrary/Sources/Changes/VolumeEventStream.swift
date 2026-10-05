#if os(macOS)
    import CoreServices
    import Foundation

    /// FSEvents: each device's history of changed folders, which the system keeps across launches
    /// and replays from any of its events (`FSEventStreamCreateRelativeToDevice`).
    struct FSEventsSource: VolumeEventSource {
        func locate(_ path: String) -> VolumeLocation? {
            var info = stat()
            guard stat(path, &info) == 0, let relative = Self.pathOnDevice(path) else { return nil }
            return VolumeLocation(device: Int64(info.st_dev), path: relative)
        }

        func eventDatabase(of device: Int64) -> String? {
            FSEventsCopyUUIDForDevice(dev_t(truncatingIfNeeded: device)).flatMap { uuid in
                CFUUIDCreateString(nil, uuid) as String?
            }
        }

        var currentEvent: UInt64 {
            FSEventsGetCurrentEventId()
        }

        func subscribe(
            device: Int64, paths: [String], since: UInt64, latency: Duration,
            handler: @escaping @Sendable ([VolumeEvent]) -> Void,
        ) -> (any VolumeEventSubscription)? {
            VolumeEventStream(
                device: dev_t(truncatingIfNeeded: device), paths: paths, since: since, latency: latency,
                handler: handler,
            )
        }

        /// `path` from the root of its device, as the device's event database names it. The system's
        /// data volume is mounted at `/System/Volumes/Data` and reached through firmlinks from `/`, so
        /// a path outside its mount point is from `/`.
        static func pathOnDevice(_ path: String) -> String? {
            guard let real = realpath(path, nil) else { return nil }
            defer { free(real) }
            let resolved = String(cString: real)
            var info = statfs()
            guard statfs(resolved, &info) == 0 else { return nil }
            let mount = withUnsafeBytes(of: info.f_mntonname) { bytes in
                String(decoding: bytes.prefix { $0 != 0 }, as: UTF8.self)
            }
            if mount != "/", resolved == mount || resolved.hasPrefix(mount + "/") {
                return VolumeEventStream.trimmed(String(resolved.dropFirst(mount.count)))
            }
            return VolumeEventStream.trimmed(resolved)
        }
    }

    /// One FSEvents stream for folders on a device: directories only, coalesced over the stream's
    /// latency, on a queue of its own. Paths, in and out, are from the device's root.
    final class VolumeEventStream: VolumeEventSubscription, @unchecked Sendable {
        /// What the stream's callback reaches, retained by the stream for as long as it lives.
        private final class Receiver {
            let handler: @Sendable ([VolumeEvent]) -> Void

            init(_ handler: @escaping @Sendable ([VolumeEvent]) -> Void) {
                self.handler = handler
            }
        }

        /// Guarded by `lock`: the stream isn't `Sendable`.
        private var stream: FSEventStreamRef?
        private let lock = NSLock()
        private let queue = DispatchQueue(label: "app.redlamp.library.changes", qos: .utility)

        /// Starts following `paths` on `device` from just after `since`; nil when FSEvents refuses.
        init?(
            device: dev_t, paths: [String], since: FSEventStreamEventId, latency: Duration,
            handler: @escaping @Sendable ([VolumeEvent]) -> Void,
        ) {
            let receiver = Receiver(handler)
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
            let callback: FSEventStreamCallback = { _, info, count, paths, flags, ids in
                guard let info else { return }
                let receiver = Unmanaged<Receiver>.fromOpaque(info).takeUnretainedValue()
                let names = unsafeBitCast(paths, to: NSArray.self) as? [String] ?? []
                receiver.handler((0 ..< min(count, names.count)).map { index in
                    VolumeEvent(
                        path: VolumeEventStream.trimmed(names[index]), flags: VolumeEventStream.flags(flags[index]),
                        id: ids[index],
                    )
                })
            }
            let watched = paths.map { $0.isEmpty ? "/" : $0 }
            let options =
                FSEventStreamCreateFlags(kFSEventStreamCreateFlagUseCFTypes | kFSEventStreamCreateFlagWatchRoot)
            guard let created = FSEventStreamCreateRelativeToDevice(
                nil, callback, &context, device, watched as CFArray, since, latency.seconds, options,
            ) else { return nil }
            FSEventStreamSetDispatchQueue(created, queue)
            guard FSEventStreamStart(created) else {
                FSEventStreamInvalidate(created)
                FSEventStreamRelease(created)
                return nil
            }
            stream = created
        }

        func cancel() {
            lock.withLock {
                guard let created = stream else { return }
                FSEventStreamStop(created)
                FSEventStreamInvalidate(created)
                FSEventStreamRelease(created)
                stream = nil
            }
        }

        deinit {
            cancel()
        }

        static func flags(_ raw: FSEventStreamEventFlags) -> VolumeEvent.Flags {
            func has(_ flag: Int) -> Bool {
                raw & FSEventStreamEventFlags(flag) != 0
            }
            var flags: VolumeEvent.Flags = []
            if has(kFSEventStreamEventFlagMustScanSubDirs) {
                flags.insert(.mustScanSubfolders)
            }
            if has(kFSEventStreamEventFlagUserDropped) || has(kFSEventStreamEventFlagKernelDropped) {
                flags.insert(.dropped)
            }
            if has(kFSEventStreamEventFlagRootChanged) || has(kFSEventStreamEventFlagUnmount) {
                flags.insert(.rootChanged)
            }
            if has(kFSEventStreamEventFlagEventIdsWrapped) {
                flags.insert(.idsWrapped)
            }
            if has(kFSEventStreamEventFlagHistoryDone) {
                flags.insert(.historyDone)
            }
            return flags
        }

        static func trimmed(_ path: String) -> String {
            var path = Substring(path)
            while path.hasPrefix("/") {
                path = path.dropFirst()
            }
            while path.hasSuffix("/") {
                path = path.dropLast()
            }
            return String(path)
        }
    }
#endif
