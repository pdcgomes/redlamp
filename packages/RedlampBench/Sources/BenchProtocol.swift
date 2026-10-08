import Foundation

/// What the hub and the phone say to each other, as JSON over HTTP. See docs/bench-tasks.md.
public enum BenchProtocol {
    public static let version = 1
    /// The Bonjour service the Lab's hub advertises.
    public static let serviceType = "_redlamp-bench._tcp"
    /// The Bonjour service the iPhone app advertises while it's open, so the Lab sees it nearby.
    public static let phoneServiceType = "_redlamp-phone._tcp"
    public static let defaultPort: UInt16 = 8765

    public struct HubInfo: Codable, Sendable, Hashable {
        public var name: String
        public var version: Int
        /// Whether the request carried a token the hub knows.
        public var paired: Bool
    }

    /// With a code, pairs at once; without one, asks the owner to allow it in the Lab.
    public struct PairRequest: Codable, Sendable, Hashable {
        public var code: String?
        public var device: String

        public init(code: String? = nil, device: String) {
            self.code = code
            self.device = device
        }
    }

    /// A pairing the owner hasn't answered yet: the phone asks after it by `request`.
    public struct PairPending: Codable, Sendable, Hashable {
        public var request: String
        public var hub: String
    }

    public struct PairStatus: Codable, Sendable, Hashable {
        public enum State: String, Codable, Sendable {
            case pending, approved, denied, expired
        }

        public var state: State
        /// Given once, when the owner allowed it.
        public var token: String?
        public var hub: String
    }

    public struct PairReply: Codable, Sendable, Hashable {
        public var token: String
        public var hub: String
    }

    /// A task or template waiting for the phone.
    public struct Listing: Codable, Sendable, Hashable, Identifiable {
        public struct File: Codable, Sendable, Hashable {
            /// Relative to the folder.
            public var path: String
            public var sha256: String
            public var bytes: Int
        }

        public var id: String
        public var title: String
        public var kind: String
        public var revision: Int
        public var withdrawn: Bool
        public var template: Bool
        public var created: Date
        /// Every file in the folder, `task.json` first.
        public var files: [File]
    }

    /// The hub's answer to a folder sent to its inbox, or to a question about one.
    public struct Receipt: Codable, Sendable, Hashable {
        public var id: String
        public var title: String
        public var kind: String
        public var summary: String
        public var complete: Bool
        /// The digest of the `results.json` the hub has, so the phone knows whether it's the latest.
        public var resultsDigest: String
        public var received: Date
    }
}
