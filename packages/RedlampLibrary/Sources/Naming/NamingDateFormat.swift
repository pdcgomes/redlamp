import Foundation
import Synchronization

/// A date's format in a template, in the pattern letters of Unicode's date formats (ICU's) that suit a
/// file name: `yyyy` `yy` the year; `M` `MM` the month, `MMM` `MMMM` its name; `d` `dd` the day; `D`
/// `DDD` the day of the year; `E` `EEEE` the weekday's name; `H` `HH` the hour from 0 to 23, `h` `hh`
/// from 1 to 12 and `a` AM or PM; `m` `mm` minutes; `s` `ss` seconds; `S` to `SSSSSS` the fraction of
/// the second, cut to that many digits; `Z` the offset from UTC, `+0100`. Other letters are kept for
/// later, so text goes in single quotes (`'T'`, and `''` for a quote); anything else is kept as it is.
struct NamingDateFormat: Sendable, Hashable {
    enum Piece: Sendable, Hashable {
        case text(String)
        case year(Int)
        case month(Int)
        case day(Int)
        case dayOfYear(Int)
        case weekday(Int)
        case hour(Int)
        case hour12(Int)
        case minute(Int)
        case second(Int)
        case fraction(Int)
        case period
        case offset
    }

    /// `{date}`'s format when it has none.
    static let standard = NamingDateFormat(pieces: [.year(4), .month(2), .day(2)])

    let pieces: [Piece]
    let needsOffset: Bool

    private init(pieces: [Piece]) {
        self.pieces = pieces
        needsOffset = pieces.contains(.offset)
    }

    struct Failure: Error {
        /// In characters, from the format's start.
        let offset: Int
        let length: Int
        let message: String
    }

    init(parsing format: String) throws(Failure) {
        let characters = Array(format)
        var pieces: [Piece] = []
        var text = ""
        func flush() {
            if !text.isEmpty {
                pieces.append(.text(text))
                text = ""
            }
        }
        var index = 0
        while index < characters.count {
            let character = characters[index]
            if character == "'" {
                if index + 1 < characters.count, characters[index + 1] == "'" {
                    text.append("'")
                    index += 2
                    continue
                }
                let start = index
                index += 1
                while true {
                    guard index < characters.count else {
                        throw Failure(offset: start, length: 1, message: "this ' isn't closed: end the text with '")
                    }
                    if characters[index] == "'" {
                        if index + 1 < characters.count, characters[index + 1] == "'" {
                            text.append("'")
                            index += 2
                            continue
                        }
                        index += 1
                        break
                    }
                    text.append(characters[index])
                    index += 1
                }
                continue
            }
            guard character.isASCII, character.isLetter else {
                text.append(character)
                index += 1
                continue
            }
            var end = index + 1
            while end < characters.count, characters[end] == character {
                end += 1
            }
            let count = end - index
            let piece: Piece? = switch character {
            case "y": .year(count)
            case "M", "L": .month(count)
            case "d": .day(count)
            case "D": .dayOfYear(count)
            case "E": .weekday(count)
            case "H": .hour(count)
            case "h": .hour12(count)
            case "m": .minute(count)
            case "s": .second(count)
            case "S": count <= 9 ? .fraction(count) : nil
            case "a": .period
            case "Z": .offset
            default: nil
            }
            guard let piece else {
                let message = character == "S"
                    ? "a second's fraction has at most 9 digits"
                    : "\(character) isn't part of a date: use yyyy, MM, dd, HH, mm, ss or SSS, and put text in 'quotes'"
                throw Failure(offset: index, length: count, message: message)
            }
            flush()
            pieces.append(piece)
            index = end
        }
        flush()
        self.init(pieces: pieces)
    }

    /// Appends `moment` as the format has it; false, appending nothing, when the format shows an offset
    /// and the moment has none.
    func append(_ moment: NamingMoment, names: NamingCalendarNames, to output: inout String) -> Bool {
        if needsOffset, moment.offset == nil {
            return false
        }
        let microseconds = moment.microseconds
        let seconds = microseconds >= 0 ? microseconds / 1_000_000 : (microseconds + 1) / 1_000_000 - 1
        let fraction = Int(microseconds - seconds * 1_000_000)
        let days = Int(seconds >= 0 ? seconds / 86400 : (seconds + 1) / 86400 - 1)
        let secondOfDay = Int(seconds - Int64(days) * 86400)
        let (year, month, day) = QueryCalendar.civil(days)
        let hour = secondOfDay / 3600
        for piece in pieces {
            switch piece {
            case let .text(text):
                output += text
            case let .year(count):
                NamingNumbers.append(count == 2 ? abs(year) % 100 : year, digits: count == 2 ? 2 : count, to: &output)
            case let .month(count):
                if count >= 3 {
                    output += (count == 3 ? names.shortMonths : names.months)[month - 1]
                } else {
                    NamingNumbers.append(month, digits: count, to: &output)
                }
            case let .day(count):
                NamingNumbers.append(day, digits: count, to: &output)
            case let .dayOfYear(count):
                NamingNumbers.append(days - QueryCalendar.days(year, 1, 1) + 1, digits: count, to: &output)
            case let .weekday(count):
                let weekday = ((days + 4) % 7 + 7) % 7
                output += (count >= 4 ? names.weekdays : names.shortWeekdays)[weekday]
            case let .hour(count):
                NamingNumbers.append(hour, digits: count, to: &output)
            case let .hour12(count):
                NamingNumbers.append(hour % 12 == 0 ? 12 : hour % 12, digits: count, to: &output)
            case let .minute(count):
                NamingNumbers.append(secondOfDay / 60 % 60, digits: count, to: &output)
            case let .second(count):
                NamingNumbers.append(secondOfDay % 60, digits: count, to: &output)
            case let .fraction(count):
                let shown = min(count, 6)
                var divisor = 1
                for _ in shown ..< 6 {
                    divisor *= 10
                }
                NamingNumbers.append(fraction / divisor, digits: shown, to: &output)
                for _ in shown ..< count {
                    output += "0"
                }
            case .period:
                output += hour < 12 ? names.am : names.pm
            case .offset:
                let offset = moment.offset ?? 0
                output += offset < 0 ? "-" : "+"
                NamingNumbers.append(abs(offset) / 3600, digits: 2, to: &output)
                NamingNumbers.append(abs(offset) / 60 % 60, digits: 2, to: &output)
            }
        }
        return true
    }
}

/// A time as a clock in some zone showed it, to the microsecond, and that zone's offset from UTC
/// when it's known.
struct NamingMoment: Sendable, Hashable {
    /// Since 1970, reading the clock's time as if it were UTC.
    var microseconds: Int64
    /// Seconds east of UTC.
    var offset: Int?

    init(microseconds: Int64, offset: Int?) {
        self.microseconds = microseconds
        self.offset = offset
    }

    /// The clock time `date` holds, read as if it were UTC, as the index keeps capture times.
    init(wallClock date: Date, offset: Int?) {
        microseconds = Self.microseconds(date)
        self.offset = offset
    }

    static func microseconds(_ date: Date) -> Int64 {
        Int64((date.timeIntervalSince1970 * 1_000_000).rounded())
    }

    /// The same instant on a clock `offset` seconds east of UTC; nil when this one's zone is unknown.
    func shown(at offset: Int) -> NamingMoment? {
        guard let own = self.offset else { return nil }
        return NamingMoment(microseconds: microseconds + Int64(offset - own) * 1_000_000, offset: offset)
    }
}

/// The zone a date is shown in: as the camera's clock showed it, the Mac's, UTC, an offset, or a
/// zone by its name (`Europe/Lisbon`).
enum NamingZone: Sendable, Hashable {
    case camera
    case local
    case utc
    /// Seconds east of UTC.
    case offset(Int)
    case named(String)

    /// `camera`, `local`, `utc`, an offset (`+05:30`, `-0800`, `+5`) or a zone's identifier; nil for
    /// anything else.
    init?(parsing text: String) {
        let text = text.trimmingCharacters(in: .whitespaces)
        switch text.lowercased() {
        case "", "camera":
            self = .camera
            return
        case "local":
            self = .local
            return
        case "utc", "gmt", "z":
            self = .utc
            return
        default:
            break
        }
        if let sign = text.first, sign == "+" || sign == "-" {
            let digits = text.dropFirst().filter { $0 != ":" }
            guard (1 ... 4).contains(digits.count), digits.allSatisfy({ $0.isASCII && $0.isNumber }),
                  text.dropFirst().filter({ $0 == ":" }).count <= 1
            else { return nil }
            let (hours, minutes) = digits.count <= 2 ? (Int(digits)!, 0)
                : (Int(digits.prefix(digits.count - 2))!, Int(digits.suffix(2))!)
            guard hours <= 14, minutes < 60 else { return nil }
            self = .offset((sign == "-" ? -1 : 1) * (hours * 3600 + minutes * 60))
            return
        }
        guard TimeZone(identifier: text) != nil else { return nil }
        self = .named(text)
    }
}

/// The names a date format shows, in one language.
struct NamingCalendarNames: Sendable, Hashable {
    let months: [String]
    let shortMonths: [String]
    /// Sunday first.
    let weekdays: [String]
    let shortWeekdays: [String]
    let am: String
    let pm: String

    static let english = names(for: Locale(identifier: "en_US_POSIX"))

    private static let cache = Mutex<[String: NamingCalendarNames]>([:])

    static func names(for locale: Locale) -> NamingCalendarNames {
        if let names = cache.withLock({ $0[locale.identifier] }) {
            return names
        }
        let formatter = DateFormatter()
        formatter.locale = locale
        formatter.calendar = Calendar(identifier: .gregorian)
        let names = NamingCalendarNames(
            months: formatter.monthSymbols, shortMonths: formatter.shortMonthSymbols,
            weekdays: formatter.weekdaySymbols, shortWeekdays: formatter.shortWeekdaySymbols,
            am: formatter.amSymbol, pm: formatter.pmSymbol,
        )
        cache.withLock { $0[locale.identifier] = names }
        return names
    }
}

/// Numbers as names show them.
enum NamingNumbers {
    /// The most digits a number is padded to.
    static let maximumDigits = 12

    /// `value` in decimal, zero-padded to `digits`.
    static func append(_ value: Int, digits: Int, to output: inout String) {
        if value < 0 {
            output.unicodeScalars.append("-")
        }
        let magnitude = value.magnitude
        var width = 1
        var power: UInt = 1
        while magnitude / power >= 10 {
            power *= 10
            width += 1
        }
        for _ in 0 ..< max(digits - width, 0) {
            output.unicodeScalars.append("0")
        }
        while power > 0 {
            output.unicodeScalars.append(Unicode.Scalar(UInt8(48 + magnitude / power % 10)))
            power /= 10
        }
    }

    /// One decimal at most, and none when it's whole: `2.8`, `8`, `4.3`.
    static func appendDecimal(_ value: Double, to output: inout String) {
        let tenths = Int((value * 10).rounded())
        append(tenths / 10, digits: 1, to: &output)
        if tenths % 10 != 0 {
            output += "."
            append(abs(tenths % 10), digits: 1, to: &output)
        }
    }
}
