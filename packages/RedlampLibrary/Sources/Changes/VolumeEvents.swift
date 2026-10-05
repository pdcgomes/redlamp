import Foundation

/// A change a volume's event history records: a folder whose entries changed, or a sign that the
/// history can't be followed folder by folder and the volume has to be compared again (LIB-08).
struct VolumeEvent: Sendable, Hashable {
    struct Flags: OptionSet, Sendable, Hashable {
        let rawValue: Int

        /// The folder's subfolders may have changed too, without events of their own.
        static let mustScanSubfolders = Flags(rawValue: 1 << 0)
        /// Events were dropped, by the kernel or by the history's reader.
        static let dropped = Flags(rawValue: 1 << 1)
        /// A root, or a folder above it, was moved, deleted or unmounted.
        static let rootChanged = Flags(rawValue: 1 << 2)
        /// The event IDs started again from 0.
        static let idsWrapped = Flags(rawValue: 1 << 3)
        /// The history asked for is replayed: the events after this one are live.
        static let historyDone = Flags(rawValue: 1 << 4)

        /// What says the history can't be followed folder by folder.
        static let lost: Flags = [.dropped, .rootChanged, .idsWrapped]
    }

    /// Relative to the device's root, without leading or trailing slashes.
    var path: String
    var flags: Flags = []
    var id: UInt64
}

/// Where a path is in its device's event history.
struct VolumeLocation: Sendable, Hashable {
    var device: Int64
    /// The path from the device's root, without leading or trailing slashes: empty for the root.
    var path: String
}

/// Where local volumes' event histories come from: FSEvents on macOS, a test's own in tests.
protocol VolumeEventSource: Sendable {
    /// Nil when `path` can't be found.
    func locate(_ path: String) -> VolumeLocation?
    /// The UUID of the device's event history; nil when it keeps none. One other than the UUID
    /// recorded means the history recorded against is gone.
    func eventDatabase(of device: Int64) -> String?
    /// The last event recorded, on any device.
    var currentEvent: UInt64 { get }
    /// Delivers the device's events at and below `paths` (from the device's root) in batches: those
    /// after `since` first, ending with a `historyDone` event, then each change as it comes, gathered
    /// over `latency`. Nil when the device can't be followed.
    func subscribe(
        device: Int64, paths: [String], since: UInt64, latency: Duration,
        handler: @escaping @Sendable ([VolumeEvent]) -> Void,
    ) -> (any VolumeEventSubscription)?
}

protocol VolumeEventSubscription: Sendable {
    func cancel()
}
