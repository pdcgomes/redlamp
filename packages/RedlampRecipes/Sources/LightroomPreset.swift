import Foundation

/// A Lightroom develop preset converted to a recipe (EDT-11): an `.xmp` file of Camera Raw
/// settings in the `crs` namespace, read with Redlamp's own reader. Only the settings the preset
/// carries are included, as Lightroom applies only those, and the report says how each one was
/// carried over.
public struct LightroomPresetImport: Sendable {
    public var recipe: Recipe
    public var report: LightroomImportReport
    /// The preset's crop, which a recipe doesn't hold, for applying to a photo directly
    /// (`LightroomCrop.redlampCrop(imageSize:cameraOrientation:orientation:)`).
    public var crop: LightroomCrop?

    public init(recipe: Recipe, report: LightroomImportReport) {
        self.recipe = recipe
        self.report = report
    }
}

/// How each of a preset's settings was carried over.
public struct LightroomImportReport: Sendable, Equatable {
    public enum Outcome: String, Sendable, CaseIterable {
        /// Redlamp has the same control on the same scale.
        case mapped
        /// Carried over to the nearest Redlamp control or scale; `note` says how.
        case approximated
        /// Not carried over; `note` says why.
        case ignored
    }

    public struct Entry: Sendable, Equatable {
        /// The Camera Raw setting's name without its namespace, for example `Exposure2012`.
        public var setting: String
        public var outcome: Outcome
        public var note: String?

        public init(setting: String, outcome: Outcome, note: String? = nil) {
            self.setting = setting
            self.outcome = outcome
            self.note = note
        }
    }

    /// The preset's `crs:ProcessVersion`, if it has one.
    public var processVersion: String?
    public var entries: [Entry]

    public init(processVersion: String? = nil, entries: [Entry] = []) {
        self.processVersion = processVersion
        self.entries = entries
    }

    public func entries(_ outcome: Outcome) -> [Entry] {
        entries.filter { $0.outcome == outcome }
    }
}

public enum LightroomPresetError: Error, Equatable, CustomStringConvertible {
    /// Not an XMP file of Camera Raw settings.
    case notAPreset
    /// A process version whose sliders Redlamp doesn't map (before Process 2012).
    case unsupportedProcessVersion(String)

    public var description: String {
        switch self {
        case .notAPreset: "This isn't a Lightroom develop preset"
        case let .unsupportedProcessVersion(version):
            "Lightroom process version \(version) predates Process 2012, whose sliders Redlamp maps"
        }
    }
}

public enum LightroomPreset {
    /// Whether `data` looks like a Lightroom develop preset (XMP with Camera Raw settings).
    public static func isPreset(_ data: Data) -> Bool {
        let head = data.prefix(64 * 1024)
        return [CameraRawSettings.rdf, CameraRawSettings.namespace].allSatisfy { head.range(of: Data($0.utf8)) != nil }
    }

    /// The preset as a recipe named `name` (or the preset's own name), with its report.
    public static func convert(_ data: Data, name: String? = nil) throws -> LightroomPresetImport {
        guard isPreset(data), let settings = CameraRawSettings(xmp: data) else { throw LightroomPresetError.notAPreset }
        return try convert(settings, name: name)
    }
}
