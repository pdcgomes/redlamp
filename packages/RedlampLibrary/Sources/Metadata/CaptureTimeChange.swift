import Foundation
import RedlampDocument
import RedlampEngineAPI

/// A change to photos' capture times (LIB-22), made as one batch with Undo: each photo's sidecar holds
/// the seconds added to the time its camera recorded (`captureShift`) and the zone its camera was in
/// (`captureOffset`), and its file is never touched. Photos without a capture time are left out.
public enum CaptureTimeChange: Sendable, Hashable {
    /// Adds `seconds` to each photo's capture time, or takes them off when it's negative.
    case shift([Int64], by: Int)
    /// Gives `photo` the time `time` by the camera's clock, to the second, keeping its fraction of a
    /// second, and shifts `others` by as much, as Lightroom Classic's Edit Capture Time does. `time` is
    /// the clock's reading as if it were UTC, as `PhotoRecord.captured` holds it.
    case set(Int64, to: Date, shifting: [Int64])
    /// Says the camera's clock was in the zone `offset` seconds east of UTC; nil gives the photos back
    /// the zone their files record.
    case zone([Int64], offset: Int?)

    /// `+1 h 30 min`, `-45 s`, `+2 d`.
    public static func describe(shift seconds: Int) -> String {
        var left = abs(seconds)
        var parts: [String] = []
        for (unit, length) in [("d", 86400), ("h", 3600), ("min", 60), ("s", 1)] where left >= length {
            parts.append("\(left / length) \(unit)")
            left %= length
        }
        return (seconds < 0 ? "-" : "+") + (parts.isEmpty ? "0 s" : parts.joined(separator: " "))
    }

    /// `UTC+01:00`, `UTC-05:30`.
    public static func describe(zone seconds: Int) -> String {
        let minutes = abs(seconds) / 60
        return "UTC" + (seconds < 0 ? "-" : "+") + String(format: "%02d:%02d", minutes / 60, minutes % 60)
    }

    /// `2024-06-01 15:30:00`, a time by the camera's clock.
    public static func describe(time: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return formatter.string(from: time)
    }
}

/// Why a capture-time change can't be made.
public enum CaptureTimeError: Error, Sendable, Hashable, CustomStringConvertible {
    /// The photo whose time is set has none, or the index doesn't have it.
    case noCaptureTime(Int64)
    /// A zone beyond −14:00 to +14:00.
    case zoneOutOfRange(Int)

    public var description: String {
        switch self {
        case let .noCaptureTime(id): "photo \(id) has no capture time to set"
        case let .zoneOutOfRange(seconds): "\(seconds) seconds from UTC isn't a zone: they run from −14:00 to +14:00"
        }
    }
}

public extension LibraryMetadata {
    /// What `change` would do, worked out from the index as it is; nothing is written.
    func plan(_ change: CaptureTimeChange) async throws -> MetadataPlan {
        let ids: [Int64]
        let edit: [String: FieldEdit]
        let title: (Int) -> String
        switch change {
        case let .shift(photos, seconds):
            ids = photos
            edit = ["captureShift": .shift(seconds)]
            title = { "Shift the capture time of \(Self.count($0)) by \(CaptureTimeChange.describe(shift: seconds))" }
        case let .set(photo, time, others):
            guard let captured = try await index.read({ try $0.photo(id: photo)?.captured }) else {
                throw CaptureTimeError.noCaptureTime(photo)
            }
            let seconds = Int(time.timeIntervalSince1970.rounded(.down) - captured.timeIntervalSince1970.rounded(.down))
            ids = [photo] + others
            edit = ["captureShift": .shift(seconds)]
            title = {
                "Set a capture time to \(CaptureTimeChange.describe(time: time)), shifting \(Self.count($0)) by "
                    + CaptureTimeChange.describe(shift: seconds)
            }
        case let .zone(photos, offset):
            if let offset, !PhotoMetadata.captureOffsets.contains(offset) {
                throw CaptureTimeError.zoneOutOfRange(offset)
            }
            ids = photos
            edit = ["captureOffset": .set(offset.map { .number(Double($0)) })]
            title = { count in
                offset
                    .map { "Set the camera's zone of \(Self.count(count)) to \(CaptureTimeChange.describe(zone: $0))" }
                    ?? "Give \(Self.count(count)) the zones their files record"
            }
        }
        let dated = try await index.read { reader in
            try Array(Set(ids)).filter { try reader.photo(id: $0)?.captured != nil }
        }
        var batch = MetadataBatch(kind: .captureTime, title: title(dated.count))
        batch.edit = edit
        batch.photos = try await photos(dated, edit: edit)
        return MetadataPlan(batch: batch)
    }

    /// Makes `change` as one batch; see `plan` and `run`.
    @discardableResult
    func apply(_ change: CaptureTimeChange) async throws -> MetadataOutcome {
        try await run(plan(change))
    }
}
