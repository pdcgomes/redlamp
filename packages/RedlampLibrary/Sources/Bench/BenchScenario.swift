import Foundation
import RedlampDocument
import Synchronization

/// What a scenario runs on: a fixture, its manifest, and the volume it's simulated on.
public struct BenchContext: Sendable {
    public let fixture: URL
    public let manifest: FixtureManifest
    public let profile: VolumeProfile

    public init(fixture: URL, manifest: FixtureManifest, profile: VolumeProfile) {
        self.fixture = fixture
        self.manifest = manifest
        self.profile = profile
    }

    /// The fixture's volume as `profile` simulates it, new and idle for each scenario.
    public func fileSystem(base: any LibraryFileSystem = LocalFileSystem()) -> SimulatedFileSystem {
        SimulatedFileSystem(base: base, profile: profile, seed: manifest.spec.seed)
    }

    /// How many operations a scenario keeps in flight: as many as the volume serves, or one per
    /// performance core.
    public var width: Int {
        profile.maxInFlight ?? CoreCounts.performance
    }
}

/// One of `redlamp library bench`'s measurements. Its results with a budget end in PASS or FAIL.
public protocol BenchScenario: Sendable {
    /// What `--scenario` calls it.
    var name: String { get }
    func run(_ context: BenchContext) async throws -> [BenchResult]
}

/// The scenarios `redlamp library bench` runs, in order. Each measures before the next warms
/// anything, so the first runs on a cold cache when the fixture is on a freshly attached image.
public enum BenchScenarios {
    private static let registered = Mutex<[any BenchScenario]>([
        ListingScenario(),
        FixtureCheckScenario(),
    ])

    public static var all: [any BenchScenario] {
        registered.withLock { $0 }
    }

    public static func named(_ name: String) -> (any BenchScenario)? {
        all.first { $0.name == name }
    }

    /// Adds `scenario` after the others, or in place of the one with its name.
    public static func register(_ scenario: any BenchScenario) {
        registered.withLock { scenarios in
            if let index = scenarios.firstIndex(where: { $0.name == scenario.name }) {
                scenarios[index] = scenario
            } else {
                scenarios.append(scenario)
            }
        }
    }
}
