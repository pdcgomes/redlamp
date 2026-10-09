import Foundation

/// Where Redlamp Reproduction puts a camera's metered grey (CAM-28): the stops added to Exposure,
/// in place of a DNG's BaselineExposure, that put an 18% grey the meter read at scene 0.18 in the
/// white-balanced raw, whose clip is 1. Each edit that uses the look keeps its own photo's camera's
/// (`docs/plans/2026-10-09-reproduction-design.md`).
public struct ExposureAnchor: Codable, Sendable, Hashable {
    /// Where the stops came from. A value a newer Redlamp wrote is kept as it is.
    public struct Source: RawRepresentable, Codable, Sendable, Hashable {
        public var rawValue: String

        public init(rawValue: String) {
            self.rawValue = rawValue
        }

        /// Measured from a target with Calibrate from Target.
        public static let target = Source(rawValue: "target")
        /// The camera has no calibration: `typicalStops`.
        public static let typical = Source(rawValue: "typical")
    }

    /// A metered grey 3.5 stops below clip, the middle of the 3.3 to 3.7 stops cameras' ISO
    /// calibrations put it at; on those cameras it lands between L* 46.5 and 52.6.
    public static let typicalStops = 1.03

    public var stops: Double
    public var source: Source
    /// The camera it belongs to, as `ImageInfo.cameraName` names it.
    public var camera: String?
    /// Fields written by a newer Redlamp, written back unchanged.
    public var unknownFields: [String: JSONValue] = [:]

    public init(stops: Double, source: Source, camera: String?) {
        self.stops = stops
        self.source = source
        self.camera = camera
    }

    /// The typical anchor, for a camera without a calibration.
    public static func typical(for camera: String?) -> ExposureAnchor {
        ExposureAnchor(stops: typicalStops, source: .typical, camera: camera)
    }
}

public extension EditRecipe {
    /// This edit with its photo's anchor, `photo` (the camera's calibration or the typical anchor;
    /// nil for a photo that isn't raw): under Redlamp Reproduction, `photo` unless the edit already
    /// has one for that camera; under any other look, none.
    func anchored(_ photo: ExposureAnchor?) -> EditRecipe {
        var result = self
        guard baseLook.isReproduction, let photo else {
            result.exposureAnchor = nil
            return result
        }
        if exposureAnchor == nil || exposureAnchor?.camera != photo.camera {
            result.exposureAnchor = photo
        }
        return result
    }
}
