import Foundation

/// What the camera bench found on a set of raw files (CAM-14): what `redlamp camera-bench` writes
/// and, with the contributor's answers, what the app sends (CAM-16). Measurements only: no
/// pixels, file names, paths, GPS, serial numbers, owner fields or capture times.
/// `docs/camera-bench.schema.json` describes it.
public struct CameraBenchReport: Codable, Sendable, Hashable {
    /// This format's version.
    public static let currentFormat = 1

    public var format: Int
    public var environment: CameraBenchEnvironment
    public var photos: [CameraBenchPhoto]
    /// One answer per camera mode, from the bench window.
    public var answers: [CameraBenchAnswer]
    /// A random ID per Mac, which can be reset, so contributors can be counted.
    public var contributor: String?
    /// A name to credit, when the contributor gives one.
    public var credit: String?

    public init(
        format: Int = CameraBenchReport.currentFormat, environment: CameraBenchEnvironment, photos: [CameraBenchPhoto],
        answers: [CameraBenchAnswer] = [], contributor: String? = nil, credit: String? = nil,
    ) {
        self.format = format
        self.environment = environment
        self.photos = photos
        self.answers = answers
        self.contributor = contributor
        self.credit = credit
    }
}

/// The software that made the measurements.
public struct CameraBenchEnvironment: Codable, Sendable, Hashable {
    /// Redlamp's version, such as "0.2.2-prealpha", and its commit when known.
    public var redlamp: String
    public var commit: String?
    /// The raw decoder and its version, such as "LibRaw 0.22.2".
    public var decoder: String
    /// The process version the default rendering used.
    public var processVersion: Int
    /// The bench's own version: its checks and how photos are chosen.
    public var bench: Int
    /// The operating system, such as "macOS 26.5", and the Mac's chip.
    public var system: String
    public var chip: String?

    public init(
        redlamp: String, commit: String? = nil, decoder: String, processVersion: Int, bench: Int, system: String,
        chip: String? = nil,
    ) {
        self.redlamp = redlamp
        self.commit = commit
        self.decoder = decoder
        self.processVersion = processVersion
        self.bench = bench
        self.system = system
        self.chip = chip
    }
}

/// A camera and one of its raw modes: the unit the bench's evidence is counted in, since one
/// body's modes can fail separately (Nikon's High Efficiency NEFs, CAM-12).
public struct CameraMode: Codable, Sendable, Hashable, Comparable {
    /// "Sony|ILCE-7M4|sony_arw2_load_raw|14|7028x4688": what submissions are grouped by.
    public var key: String
    /// "Sony ILCE-7M4".
    public var camera: String
    /// "14-bit compressed ARW, 7028 × 4688".
    public var label: String

    public init(key: String, camera: String, label: String) {
        self.key = key
        self.camera = camera
        self.label = label
    }

    public static func < (lhs: CameraMode, rhs: CameraMode) -> Bool {
        (lhs.camera, lhs.label) < (rhs.camera, rhs.label)
    }
}

/// One photo's results.
public struct CameraBenchPhoto: Codable, Sendable, Hashable {
    /// A SHA-256 of the file, so a photo sent twice counts once. Never published.
    public var fileHash: String
    public var mode: CameraMode
    public var identity: RawFileIdentity
    /// The decode's measurements; nil when the file didn't open.
    public var measurements: DecodeMeasurements?
    /// The colour temperature of the camera's white balance, in kelvin.
    public var asShotTemperature: Double?
    public var checks: [BenchCheck]
    /// Which of the evidence checklist's conditions this photo covers.
    public var conditions: [BenchCondition]
    /// Seconds to decode and to render the default edit.
    public var decodeSeconds: Double?
    public var renderSeconds: Double?

    public init(
        fileHash: String, mode: CameraMode, identity: RawFileIdentity, measurements: DecodeMeasurements?,
        asShotTemperature: Double?, checks: [BenchCheck], conditions: [BenchCondition], decodeSeconds: Double?,
        renderSeconds: Double?,
    ) {
        self.fileHash = fileHash
        self.mode = mode
        self.identity = identity
        self.measurements = measurements
        self.asShotTemperature = asShotTemperature
        self.checks = checks
        self.conditions = conditions
        self.decodeSeconds = decodeSeconds
        self.renderSeconds = renderSeconds
    }

    /// The worst verdict among the checks.
    public var verdict: BenchVerdict {
        checks.map(\.verdict).max() ?? .skipped
    }
}

public enum BenchVerdict: String, Codable, Sendable, Hashable, Comparable, CaseIterable {
    case skipped, pass, warn, fail

    public static func < (lhs: BenchVerdict, rhs: BenchVerdict) -> Bool {
        allCases.firstIndex(of: lhs)! < allCases.firstIndex(of: rhs)!
    }
}

/// One check's result.
public struct BenchCheck: Codable, Sendable, Hashable {
    /// Such as "decode.black" or "preview.cast" (see `docs/camera-bench.md`).
    public var id: String
    /// Changes whenever the check's measurements or thresholds change.
    public var version: Int
    public var verdict: BenchVerdict
    /// The numbers the verdict came from, so it can be judged again under new thresholds.
    public var measurements: [String: Double]
    /// What was found, in a sentence.
    public var summary: String
    /// A tracker row that already covers what was found, such as "CAM-12".
    public var tracker: String?

    public init(
        id: String, version: Int, verdict: BenchVerdict, measurements: [String: Double] = [:], summary: String,
        tracker: String? = nil,
    ) {
        self.id = id
        self.version = version
        self.verdict = verdict
        self.measurements = measurements
        self.summary = summary
        self.tracker = tracker
    }
}

/// The conditions the evidence checklist asks each camera mode to be tested in (DEC-28).
public enum BenchCondition: String, Codable, Sendable, Hashable, CaseIterable {
    /// ISO 200 or lower.
    case baseISO
    /// ISO 3200 or higher.
    case highISO
    /// Held upright.
    case portrait
    /// At least 0.1% of the photosites clipped.
    case clippedHighlights
    /// A white balance under 4000 K.
    case warmLight

    public var title: String {
        switch self {
        case .baseISO: "Base ISO (200 or lower)"
        case .highISO: "High ISO (3200 or higher)"
        case .portrait: "A portrait frame"
        case .clippedHighlights: "Clipped highlights (a bright sky or a lamp)"
        case .warmLight: "Warm light (indoors, under 4000 K)"
        }
    }
}

/// The contributor's answer for a camera mode, beside its side-by-side pairs: "Apart from your
/// camera's picture style, do these look like the same photos?"
public struct CameraBenchAnswer: Codable, Sendable, Hashable {
    public enum Choice: String, Codable, Sendable, Hashable, CaseIterable {
        case same, colours, brightness, framing, artefacts, notSure

        public var title: String {
            switch self {
            case .same: "They look the same"
            case .colours: "The colours differ"
            case .brightness: "The brightness differs"
            case .framing: "The framing differs"
            case .artefacts: "Redlamp's has artefacts"
            case .notSure: "Not sure"
            }
        }
    }

    /// The camera mode's key.
    public var mode: String
    public var choice: Choice
    public var note: String?

    public init(mode: String, choice: Choice, note: String? = nil) {
        self.mode = mode
        self.choice = choice
        self.note = note
    }
}
