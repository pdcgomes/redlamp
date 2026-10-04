import Foundation
import RedlampEngineAPI

/// The camera bench's public evidence (CAM-17): `docs/camera-bench.json`, which
/// `scripts/camera-bench.py` writes from the submissions and redlamp.app serves, so the bench
/// can ask for what each camera mode still needs. The whole list is downloaded, so the site
/// never learns which cameras someone has. It holds no contributor IDs or file hashes.
public struct CameraBenchSummary: Codable, Sendable, Hashable {
    public struct Mode: Codable, Sendable, Hashable {
        public var key: String
        public var camera: String
        public var label: String
        /// "verified", "tested", "working", "problem" or "untested" (DEC-28).
        public var tier: String
        public var contributors: Int
        public var photos: Int
        /// The checklist's conditions not yet covered, as `BenchCondition` raw values.
        public var needs: [String]
        /// A CC0 sample of this camera is in the decode tests.
        public var verified: Bool

        public init(
            key: String, camera: String, label: String, tier: String, contributors: Int, photos: Int, needs: [String],
            verified: Bool,
        ) {
            self.key = key
            self.camera = camera
            self.label = label
            self.tier = tier
            self.contributors = contributors
            self.photos = photos
            self.needs = needs
            self.verified = verified
        }
    }

    public var format: Int
    public var modes: [Mode]

    public init(format: Int = 1, modes: [Mode]) {
        self.format = format
        self.modes = modes
    }

    /// What each camera mode still needs, by key, for `CameraBenchSelection.choose`.
    public var needs: [String: Set<BenchCondition>] {
        Dictionary(modes.map { ($0.key, Set($0.needs.compactMap(BenchCondition.init(rawValue:)))) }) { first, _ in
            first
        }
    }

    public func mode(_ key: String) -> Mode? {
        modes.first { $0.key == key }
    }
}
