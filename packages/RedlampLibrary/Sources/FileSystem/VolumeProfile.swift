import Foundation

/// How a kind of volume answers: how long each operation waits before it's served, how fast its
/// bytes arrive, how many operations it serves at once, and when it goes away. The presets are
/// the design's (docs/plans/2026-10-05-library-design.md, The stress harness); megabytes are
/// 1,000,000 bytes, as drives and networks count them.
public struct VolumeProfile: Sendable, Hashable {
    public var name: String
    /// Before each operation is served: a network's round trip.
    public var latency: Duration
    /// How much `latency` varies: the sigma of a log-normal factor whose mean is 1, so the
    /// average latency stays `latency`. 0.4 keeps about two thirds of operations within 50%.
    public var jitter: Double
    /// Bytes a second, shared by the operations in flight; nil for no limit.
    public var bandwidth: Double?
    /// Operations served at once; the others wait for one to finish. Nil for no limit.
    public var maxInFlight: Int?
    /// Charged when an operation's file isn't the one the operation before it was served:
    /// the time a disk's head takes to get there.
    public var seek: Duration
    /// What the volume says it is, in place of what the volume underneath says; nil keeps that.
    public var isLocal: Bool?
    public var isInternal: Bool?
    public var disconnect: Disconnect?

    /// When the volume goes away, and what its operations do then.
    public struct Disconnect: Sendable, Hashable {
        public enum Trigger: Sendable, Hashable {
            /// This long after the simulated volume was made.
            case after(Duration)
            /// Once this many operations have been made.
            case afterOperations(Int)
        }

        public enum Failure: Sendable, Hashable {
            /// Operations fail at once, as on an unplugged drive.
            case unreachable
            /// Operations hang for this long and then fail, as on a network that stopped answering.
            case timeout(Duration)
        }

        public var trigger: Trigger
        public var failure: Failure

        public init(_ trigger: Trigger, failure: Failure = .unreachable) {
            self.trigger = trigger
            self.failure = failure
        }
    }

    public init(
        name: String, latency: Duration = .zero, jitter: Double = 0, bandwidth: Double? = nil,
        maxInFlight: Int? = nil, seek: Duration = .zero, isLocal: Bool? = nil, isInternal: Bool? = nil,
        disconnect: Disconnect? = nil,
    ) {
        self.name = name
        self.latency = latency
        self.jitter = jitter
        self.bandwidth = bandwidth
        self.maxInFlight = maxInFlight.map { max($0, 1) }
        self.seek = seek
        self.isLocal = isLocal
        self.isInternal = isInternal
        self.disconnect = disconnect
    }

    /// The volume as it is, with nothing added.
    public static let ssd = VolumeProfile(name: "ssd")

    /// One head: operations take turns, and moving to another file costs a seek.
    public static let spinning = VolumeProfile(
        name: "spinning", bandwidth: 160_000_000, maxInFlight: 1, seek: .milliseconds(8), isInternal: false,
    )

    public static let nas = VolumeProfile(
        name: "nas", latency: .microseconds(800), bandwidth: 110_000_000, maxInFlight: 16,
        isLocal: false, isInternal: false,
    )

    public static let wifi = VolumeProfile(
        name: "wifi", latency: .milliseconds(12), jitter: 0.4, bandwidth: 25_000_000, maxInFlight: 8,
        isLocal: false, isInternal: false,
    )

    public static let vpn = VolumeProfile(
        name: "vpn", latency: .milliseconds(40), bandwidth: 5_000_000, maxInFlight: 4,
        isLocal: false, isInternal: false,
    )

    public static let presets: [VolumeProfile] = [.ssd, .spinning, .nas, .wifi, .vpn]

    public static func named(_ name: String) -> VolumeProfile? {
        presets.first { $0.name == name.lowercased() }
    }

    /// The same volume, going away as `disconnect` says.
    public func disconnecting(_ disconnect: Disconnect) -> VolumeProfile {
        var profile = self
        profile.disconnect = disconnect
        return profile
    }
}
