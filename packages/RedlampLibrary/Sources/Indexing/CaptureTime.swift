import Foundation

/// A photo's capture time as its sidecar changes it (LIB-22): the camera's time with the sidecar's
/// `captureShift` added, in the zone its `captureOffset` gives, or else the file's. The row keeps the
/// camera's own while either is set, so it can always be worked out again, and a sidecar changed
/// since is shown without reading the photo.
public extension PhotoRecord {
    /// The time the camera recorded, without the shift its sidecar gives it.
    var cameraTime: Date? {
        cameraCaptured ?? captured
    }

    /// The zone the photo's file records.
    var cameraZone: Int? {
        cameraCaptured == nil ? capturedOffset : cameraOffset
    }

    /// Seconds its sidecar adds to the camera's time.
    var captureShift: Int {
        guard let captured, let cameraCaptured else { return 0 }
        return Int((captured.timeIntervalSince1970 - cameraCaptured.timeIntervalSince1970).rounded())
    }

    /// Shows the camera's time with `shift` seconds added, in the zone `offset`, or the file's when it's
    /// nil, keeping the camera's own while either changes it. A photo without a capture time has
    /// nothing to change.
    internal mutating func showCapture(shift: Int, offset: Int?) {
        guard let camera = cameraTime else { return }
        let zone = cameraZone
        let changed = shift != 0 || offset != nil
        captured = camera.addingTimeInterval(TimeInterval(shift))
        capturedOffset = offset ?? zone
        cameraCaptured = changed ? camera : nil
        cameraOffset = changed ? zone : nil
    }
}
