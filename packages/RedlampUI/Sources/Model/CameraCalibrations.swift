import Foundation
import Observation
import RedlampEngineAPI
import RedlampRecipes

/// Each camera's exposure anchor from Calibrate from Target (CAM-28): one entry per camera model,
/// kept in Application Support (`Redlamp/Cameras/Calibrations.json`), and written into each edit
/// that chooses Redlamp Reproduction. An edit keeps the anchor it was given; a later calibration
/// reaches it only through Update Calibration.
@MainActor
@Observable
public final class CameraCalibrations {
    public struct Entry: Codable, Sendable, Hashable {
        /// The camera, as `ImageInfo.cameraName` names it.
        public var camera: String
        public var stops: Double
        /// The ISO the target was shot at.
        public var iso: Double?
        public var date: Date
        /// The target photo's file name.
        public var photo: String

        public init(camera: String, stops: Double, iso: Double?, date: Date, photo: String) {
            self.camera = camera
            self.stops = stops
            self.iso = iso
            self.date = date
            self.photo = photo
        }
    }

    private struct File: Codable {
        var cameras: [Entry]
    }

    public private(set) var entries: [String: Entry]
    @ObservationIgnored private let file: URL?

    /// Reads the store at `file`; without one it lives in memory.
    public init(file: URL? = CameraCalibrations.defaultFile) {
        self.file = file
        let stored = file.flatMap { try? Data(contentsOf: $0) }
            .flatMap { try? Self.decoder.decode(File.self, from: $0) }
        entries = Dictionary(stored?.cameras.map { ($0.camera, $0) } ?? [], uniquingKeysWith: { $1 })
    }

    public nonisolated static var defaultFile: URL {
        RecipeLibrary.defaultRoot.appendingPathComponent("Cameras", isDirectory: true)
            .appendingPathComponent("Calibrations.json")
    }

    public func entry(for camera: String?) -> Entry? {
        camera.flatMap { entries[$0] }
    }

    /// The anchor an edit of a photo from `camera` gets: its calibration, or else the typical one.
    public func anchor(for camera: String?) -> ExposureAnchor {
        entry(for: camera).map { ExposureAnchor(stops: $0.stops, source: .target, camera: $0.camera) }
            ?? .typical(for: camera)
    }

    /// Keeps `entry` for its camera in place of any earlier one.
    public func calibrate(_ entry: Entry) throws {
        var next = entries
        next[entry.camera] = entry
        try save(next)
        entries = next
    }

    public func forget(_ camera: String) throws {
        var next = entries
        guard next.removeValue(forKey: camera) != nil else { return }
        try save(next)
        entries = next
    }

    private func save(_ entries: [String: Entry]) throws {
        guard let file else { return }
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        let cameras = entries.values.sorted { $0.camera < $1.camera }
        try Self.encoder.encode(File(cameras: cameras)).write(to: file, options: .atomic)
    }

    private static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }()

    private static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()
}
