import CoreGraphics
import CryptoKit
import Foundation
import RedlampEngineAPI

/// One photo's results, with the two renderings it compared for showing side by side.
public struct CameraBenchResult: @unchecked Sendable {
    public var photo: CameraBenchPhoto
    /// Redlamp's default rendering and the camera's JPEG, at `CameraBench.pairSize`.
    public var ours: CGImage?
    public var theirs: CGImage?
}

/// The camera bench (CAM-14): tests raw files against the JPEG their camera embedded, on this
/// Mac, through any engine that can also read what a raw file says about itself. The engine has
/// one current photo, so photos are tested one at a time (medium format takes up to 2 GB).
public final class CameraBench: @unchecked Sendable {
    public typealias Engine = any EditingEngine & RawFileInspecting

    /// The bench's version: its checks and how it chooses photos.
    public static let version = 1
    /// The long edge of the renderings compared and shown.
    public static let pairSize = 1024

    public let engine: Engine
    private let lock = AsyncLock()

    public init(engine: Engine) {
        self.engine = engine
    }

    /// The software making the measurements.
    public func environment(redlamp: String, commit: String?) -> CameraBenchEnvironment {
        CameraBenchEnvironment(
            redlamp: redlamp, commit: commit, decoder: engine.rawDecoderVersion,
            processVersion: EditRecipe.currentProcessVersion, bench: Self.version,
            system: "macOS \(Self.systemVersion)", chip: Self.chip,
        )
    }

    /// Tests one photo; nil when it isn't a raw file.
    public func run(_ url: URL) async -> CameraBenchResult? {
        await lock.lock()
        let result = await runUnlocked(url)
        await lock.unlock()
        return result
    }

    private func runUnlocked(_ url: URL) async -> CameraBenchResult? {
        guard let identified = engine.identify(url) else { return nil }
        let hash = Self.fileHash(url) ?? ""
        let clock = ContinuousClock()
        let opening = clock.now
        let info: ImageInfo
        do {
            info = try await engine.open(url)
        } catch {
            let photo = CameraBenchPhoto(
                fileHash: hash, mode: CameraMode(identity: identified), identity: identified, measurements: nil,
                asShotTemperature: nil, checks: [CameraBenchChecks.refused(identified, error: error)],
                conditions: BenchCondition.met(by: identified, measurements: nil, temperature: nil),
                decodeSeconds: nil, renderSeconds: nil,
            )
            return CameraBenchResult(
                photo: photo,
                ours: nil,
                theirs: engine.cameraPreview(of: url, maxLongEdge: Self.pairSize),
            )
        }
        let decodeSeconds = Self.seconds(clock.now - opening)
        let identity = info.diagnostics?.identity ?? identified
        let measurements = info.diagnostics?.measurements
        var checks = [CameraBenchChecks.opened()]
        if let measurements {
            checks += CameraBenchChecks.decode(measurements, identity: identity)
        }

        let rendering = clock.now
        let ours = try? await engine.renderStill(StillRequest(
            recipe: EditRecipe(), maxLongEdge: Self.pairSize, colorSpace: .sRGB, bitsPerComponent: 16, purpose: .export,
        ))
        let renderSeconds = Self.seconds(clock.now - rendering)
        let theirs = engine.cameraPreview(of: url, maxLongEdge: Self.pairSize)
        checks.append(CameraBenchChecks.rendered(ours != nil))
        let comparison = ours.flatMap { ours in theirs.flatMap { CameraJPEGComparison(ours: ours, theirs: $0) } }
        checks += CameraBenchChecks.preview(comparison, hasPreview: theirs != nil)

        let temperature = info.asShotWhiteBalance.map { ($0.temperature).rounded() }
        let photo = CameraBenchPhoto(
            fileHash: hash, mode: CameraMode(identity: identity), identity: identity, measurements: measurements,
            asShotTemperature: temperature, checks: checks,
            conditions: BenchCondition.met(by: identity, measurements: measurements, temperature: temperature),
            decodeSeconds: decodeSeconds, renderSeconds: renderSeconds,
        )
        return CameraBenchResult(photo: photo, ours: ours, theirs: theirs)
    }

    // MARK: - Helpers

    /// A SHA-256 of the file's bytes.
    static func fileHash(_ url: URL) -> String? {
        guard let data = try? Data(contentsOf: url, options: .alwaysMapped) else { return nil }
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    static func seconds(_ duration: Duration) -> Double {
        let (seconds, attoseconds) = duration.components
        return ((Double(seconds) + Double(attoseconds) / 1e18) * 1000).rounded() / 1000
    }

    static var systemVersion: String {
        let version = ProcessInfo.processInfo.operatingSystemVersion
        return "\(version.majorVersion).\(version.minorVersion)"
    }

    static var chip: String? {
        var size = 0
        guard sysctlbyname("machdep.cpu.brand_string", nil, &size, nil, 0) == 0, size > 0 else { return nil }
        var bytes = [CChar](repeating: 0, count: size)
        guard sysctlbyname("machdep.cpu.brand_string", &bytes, &size, nil, 0) == 0 else { return nil }
        let name = String(decoding: bytes.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
        return name.isEmpty ? nil : name
    }
}

/// Choosing which photos to test (CAM-14): grouped by camera mode, a few per mode that cover the
/// evidence checklist, the conditions a camera mode still needs first.
public enum CameraBenchSelection {
    public struct Candidate: Sendable, Hashable {
        public var url: URL
        public var identity: RawFileIdentity

        public init(url: URL, identity: RawFileIdentity) {
            self.url = url
            self.identity = identity
        }
    }

    public struct Group: Sendable, Hashable {
        public var mode: CameraMode
        /// Every candidate in this mode, and the ones chosen.
        public var candidates: Int
        public var chosen: [URL]
    }

    /// Up to `perMode` photos per camera mode. `needs` lists, by camera mode key, conditions
    /// its evidence still lacks; photos meeting them come first. White balance and clipping are
    /// only known once a photo is decoded, so the warmest white balance and the brightest
    /// exposure stand in for them.
    public static func choose(
        _ candidates: [Candidate], perMode: Int = 8, needs: [String: Set<BenchCondition>] = [:],
    ) -> [Group] {
        let byMode = Dictionary(grouping: candidates) { CameraMode(identity: $0.identity) }
        return byMode.map { mode, members in
            let sorted = members.sorted { $0.url.path < $1.url.path }
            var chosen: [Candidate] = []
            func take(_ candidate: Candidate?) {
                guard let candidate, chosen.count < perMode, !chosen.contains(candidate) else { return }
                chosen.append(candidate)
            }
            let wanted = needs[mode.key] ?? Set(BenchCondition.allCases)
            let iso = { (c: Candidate) in c.identity.iso ?? 0 }
            let warmth = { (c: Candidate) -> Double in
                guard let m = c.identity.asShotMultipliers, m[0] > 0 else { return 0 }
                return m[2] / m[0]
            }
            let brightness = { (c: Candidate) -> Double in
                guard let iso = c.identity.iso, let time = c.identity.exposureTime, let f = c.identity.aperture, f > 0
                else { return 0 }
                return iso * time / (f * f)
            }
            let ordered: [(BenchCondition, Candidate?)] = [
                (.highISO, sorted.filter { iso($0) >= 3200 }.max { iso($0) < iso($1) }),
                (.baseISO, sorted.filter { iso($0) > 0 }.min { iso($0) < iso($1) }),
                (.portrait, sorted.first { [5, 6].contains($0.identity.orientation) }),
                (.warmLight, sorted.max { warmth($0) < warmth($1) }),
                (.clippedHighlights, sorted.max { brightness($0) < brightness($1) }),
            ]
            for (condition, candidate) in ordered where wanted.contains(condition) {
                take(candidate)
            }
            for (_, candidate) in ordered {
                take(candidate)
            }
            var lenses = Set(chosen.compactMap(\.identity.lens))
            for candidate in sorted where !lenses.contains(candidate.identity.lens ?? "") {
                take(candidate)
                lenses.insert(candidate.identity.lens ?? "")
            }
            if chosen.count < perMode, sorted.count > chosen.count {
                let step = max(1, sorted.count / perMode)
                for candidate in stride(from: 0, to: sorted.count, by: step).map({ sorted[$0] }) {
                    take(candidate)
                }
            }
            return Group(mode: mode, candidates: members.count, chosen: chosen.map(\.url))
        }
        .sorted { $0.mode < $1.mode }
    }
}
