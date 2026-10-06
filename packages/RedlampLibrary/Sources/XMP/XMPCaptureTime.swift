import Foundation

/// A capture time as XMP writes it (LIB-22, LIB-24): a clock's reading, kept as if it were UTC as the
/// library keeps capture times, and the zone the clock was in, in seconds east of UTC, when it says.
/// A photo's own file is never written, so where another app's `.xmp` gives a raw a capture time other
/// than the one its file records (Lightroom Classic's Edit Capture Time changes EXIF's DateTimeOriginal),
/// the difference is a shift.
struct XMPCaptureTime: Sendable, Hashable {
    var time: Date
    var offset: Int?

    init(time: Date, offset: Int? = nil) {
        self.time = time
        self.offset = offset
    }

    /// The time a photo taken at `camera` (its clock's reading and its file's zone) shows with `shift`
    /// seconds added, in the zone `offset`, or else the camera's.
    init(camera: XMPCaptureTime, shift: Int?, offset: Int?) {
        self.init(time: camera.time.addingTimeInterval(TimeInterval(shift ?? 0)), offset: offset ?? camera.offset)
    }

    /// The capture time `packet` gives: its `exif:DateTimeOriginal`, else its `photoshop:DateCreated`;
    /// nil when neither gives a time of day.
    init?(_ packet: some XMPProperties) {
        guard let found = [XMPNamespace.dateTimeOriginal, XMPNamespace.dateCreated].lazy
            .compactMap({ packet.text($0).flatMap(XMPCaptureTime.init(text:)) }).first
        else { return nil }
        self = found
    }

    /// `text` as XMP writes a date, `2026-10-01T13:30:00.25+02:00` (its seconds, fraction and zone
    /// optional, `Z` for UTC), or as EXIF and darktable write one, `2026:10:01 13:30:00.000`; nil for a
    /// date without a time of day, or anything else.
    init?(text: String) {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let middle = text.firstIndex(where: { $0 == "T" || $0 == " " }) else { return nil }
        let day = text[..<middle]
        let date = day.split(separator: day.contains("-") ? "-" : ":", omittingEmptySubsequences: false)
        var clock = text[text.index(after: middle)...]
        var offset: Int?
        if clock.hasSuffix("Z") {
            offset = 0
            clock = clock.dropLast()
        } else if let sign = clock.lastIndex(where: { $0 == "+" || $0 == "-" }) {
            let zone = clock[clock.index(after: sign)...].filter { $0 != ":" }
            guard zone.count == 2 || zone.count == 4, Self.isDigits(zone), let digits = Int(zone) else { return nil }
            let minutes = zone.count == 2 ? digits * 60 : digits / 100 * 60 + digits % 100
            offset = (clock[sign] == "-" ? -60 : 60) * minutes
            clock = clock[..<sign]
        }
        let parts = clock.split(separator: ":", omittingEmptySubsequences: false)
        guard date.count == 3, parts.count == 2 || parts.count == 3, date.allSatisfy(Self.isDigits),
              parts.allSatisfy({ Self.isDigits($0.prefix { $0 != "." }) }),
              let year = Int(date[0]), let month = Int(date[1]), let dayOfMonth = Int(date[2]),
              let hour = Int(parts[0]), let minute = Int(parts[1])
        else { return nil }
        var second = 0
        var fraction = 0.0
        if parts.count == 3 {
            let seconds = parts[2].split(separator: ".", maxSplits: 1, omittingEmptySubsequences: false)
            guard let whole = Int(seconds[0]) else { return nil }
            second = whole
            if seconds.count == 2 {
                guard Self.isDigits(seconds[1]), let value = Double("0." + seconds[1]) else { return nil }
                fraction = value
            }
        }
        let components = DateComponents(
            year: year, month: month, day: dayOfMonth, hour: hour, minute: minute, second: second,
        )
        guard components.isValidDate(in: Self.calendar), let reading = Self.calendar.date(from: components),
              offset.map({ abs($0) <= 18 * 3600 }) ?? true
        else { return nil }
        self.init(time: reading.addingTimeInterval(fraction), offset: offset)
    }

    /// As Adobe's apps write it: `2026-10-01T13:30:00.25+02:00`, a fraction of a second to the hundredth,
    /// and the zone when it's known.
    var text: String {
        let reading = Self.calendar.dateComponents([.year, .month, .day, .hour, .minute, .second], from: time)
        let seconds = time.timeIntervalSince1970
        let hundredths = Int(((seconds - seconds.rounded(.down)) * 100).rounded())
        var text = String(
            format: "%04d-%02d-%02dT%02d:%02d:%02d", reading.year ?? 0, reading.month ?? 0, reading.day ?? 0,
            reading.hour ?? 0, reading.minute ?? 0, reading.second ?? 0,
        )
        if (1 ... 99).contains(hundredths) {
            text += hundredths % 10 == 0 ? ".\(hundredths / 10)" : String(format: ".%02d", hundredths)
        }
        if let offset {
            let minutes = abs(offset) / 60
            text += (offset < 0 ? "-" : "+") + String(format: "%02d:%02d", minutes / 60, minutes % 60)
        }
        return text
    }

    /// Seconds from `camera`'s time to this one's, by whole seconds, as Lightroom Classic's Edit Capture
    /// Time sets a time.
    func shift(from camera: XMPCaptureTime) -> Int {
        Int(time.timeIntervalSince1970.rounded(.down) - camera.time.timeIntervalSince1970.rounded(.down))
    }

    private static let calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .gmt
        return calendar
    }()

    private static func isDigits(_ text: some StringProtocol) -> Bool {
        !text.isEmpty && text.allSatisfy { ("0" ... "9").contains($0) }
    }
}
