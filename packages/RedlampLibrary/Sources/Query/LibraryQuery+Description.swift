import Foundation

extension LibraryQuery: CustomStringConvertible {
    /// The query's canonical text: fields by their own names, values as the language writes them,
    /// and parentheses only where `OR` sits inside `AND` or under `-`.
    public var description: String {
        switch self {
        case .all:
            ""
        case let .text(text):
            Self.needsQuotes(text, inValue: false) ? Self.quoted(text) : text
        case let .filter(filter):
            filter.description
        case let .not(query):
            "-" + query.operand
        case let .and(queries):
            queries.map { query in
                if case .or = query {
                    return "(\(query))"
                }
                return query.description
            }.joined(separator: " ")
        case let .or(queries):
            queries.map(\.description).joined(separator: " OR ")
        }
    }

    /// As what `-` leaves out: a group in parentheses.
    private var operand: String {
        switch self {
        case .all, .and, .or: "(\(description))"
        case .text, .filter, .not: description
        }
    }

    /// Whether `text` must be quoted to be read back as itself: as free text, or as a value.
    static func needsQuotes(_ text: String, inValue: Bool) -> Bool {
        if text.isEmpty || (!inValue && (text == "OR" || text == "AND" || text.hasPrefix("-"))) {
            return true
        }
        return text.contains { character in
            character.isWhitespace || "()\"".contains(character)
                || (inValue ? character == "," : ":=<>!".contains(character))
        }
    }

    static func quoted(_ text: String) -> String {
        "\"" + text.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }
}

extension LibraryQuery.Filter: CustomStringConvertible {
    public var description: String {
        field.rawValue + comparison.rawValue + values.map { $0.text(for: field) }.joined(separator: ",")
    }
}

extension LibraryQuery.Value {
    /// The value as `field`'s filter writes it.
    func text(for field: LibraryQuery.Field) -> String {
        switch self {
        case let .text(text):
            LibraryQuery.needsQuotes(text, inValue: true) ? LibraryQuery.quoted(text) : text
        case let .number(number):
            Self.format(number, for: field)
        case let .numberRange(lower, upper):
            (lower.map { Self.format($0, for: field) } ?? "") + ".." + (upper.map { Self.format($0, for: field) } ?? "")
        case let .date(date):
            date.description
        case let .dateRange(lower, upper):
            (lower?.description ?? "") + ".." + (upper?.description ?? "")
        case let .flag(flag):
            flag?.rawValue ?? "none"
        case let .label(label):
            label?.rawValue ?? "none"
        case let .bool(bool):
            bool ? "yes" : "no"
        case let .kind(kind):
            switch kind {
            case .raw: "raw"
            case .jpeg: "jpeg"
            case .heic: "heic"
            case .tiff: "tiff"
            case .png: "png"
            case .other: "other"
            }
        case let .detail(detail):
            detail.rawValue
        case let .trait(trait):
            trait.rawValue
        }
    }

    /// Whole numbers without a point, a shutter speed under a second as a fraction when it is one
    /// exactly, and anything else as the shortest text that reads back as the same number.
    static func format(_ number: Double, for field: LibraryQuery.Field) -> String {
        if field == .shutter, number > 0, number < 1 {
            let denominator = (1 / number).rounded()
            if denominator >= 2, denominator < 1e9, 1 / denominator == number {
                return "1/\(Int(denominator))"
            }
        }
        if number == number.rounded(), abs(number) < 1e15 {
            return String(Int64(number))
        }
        return String(number)
    }
}

extension QueryDate: CustomStringConvertible {
    public var description: String {
        switch self {
        case let .year(year): digits(year, 4)
        case let .month(year, month): digits(year, 4) + "-" + digits(month)
        case let .day(year, month, day): digits(year, 4) + "-" + digits(month) + "-" + digits(day)
        case .today: "today"
        case .yesterday: "yesterday"
        case let .last(count, unit): "last:\(count)\(unit.rawValue)"
        }
    }
}

/// Civil dates as days since 1 January 1970 (Howard Hinnant's algorithms), in the capture time's
/// terms: the camera's clock read as if it were UTC.
enum QueryCalendar {
    static let millisecondsPerDay: Int64 = 86_400_000

    static func days(_ year: Int, _ month: Int, _ day: Int) -> Int {
        let y = month <= 2 ? year - 1 : year
        let era = (y >= 0 ? y : y - 399) / 400
        let yearOfEra = y - era * 400
        let dayOfYear = (153 * (month > 2 ? month - 3 : month + 9) + 2) / 5 + day - 1
        let dayOfEra = yearOfEra * 365 + yearOfEra / 4 - yearOfEra / 100 + dayOfYear
        return era * 146_097 + dayOfEra - 719_468
    }

    static func civil(_ days: Int) -> (year: Int, month: Int, day: Int) {
        let z = days + 719_468
        let era = (z >= 0 ? z : z - 146_096) / 146_097
        let dayOfEra = z - era * 146_097
        let yearOfEra = (dayOfEra - dayOfEra / 1460 + dayOfEra / 36524 - dayOfEra / 146_096) / 365
        let dayOfYear = dayOfEra - (365 * yearOfEra + yearOfEra / 4 - yearOfEra / 100)
        let shifted = (5 * dayOfYear + 2) / 153
        let day = dayOfYear - (153 * shifted + 2) / 5 + 1
        let month = shifted < 10 ? shifted + 3 : shifted - 9
        return (yearOfEra + era * 400 + (month <= 2 ? 1 : 0), month, day)
    }

    static func daysInMonth(_ year: Int, _ month: Int) -> Int {
        let next = month == 12 ? days(year + 1, 1, 1) : days(year, month + 1, 1)
        return next - days(year, month, 1)
    }

    /// The day `milliseconds` falls on.
    static func day(ofMilliseconds milliseconds: Int64) -> Int {
        Int(milliseconds >= 0 ? milliseconds / millisecondsPerDay : (milliseconds + 1) / millisecondsPerDay - 1)
    }

    /// Today, as the Mac's clock and zone have it.
    static func today(now: Date, timeZone: TimeZone) -> Int {
        let local = now.timeIntervalSince1970 + Double(timeZone.secondsFromGMT(for: now))
        return Int((local / 86400).rounded(.down))
    }
}

extension QueryDate {
    /// The capture times it spans, in milliseconds, its end excluded.
    func interval(today: Int) -> Range<Int64> {
        let (first, end): (Int, Int) = switch self {
        case let .year(year): (QueryCalendar.days(year, 1, 1), QueryCalendar.days(year + 1, 1, 1))
        case let .month(year, month):
            (
                QueryCalendar.days(year, month, 1),
                QueryCalendar.days(year, month, 1)
                    + QueryCalendar.daysInMonth(year, month),
            )
        case let .day(year, month, day): (
                QueryCalendar.days(year, month, day),
                QueryCalendar.days(year, month, day) + 1,
            )
        case .today: (today, today + 1)
        case .yesterday: (today - 1, today)
        case let .last(count, unit): (Self.start(ofLast: count, unit, today: today), today + 1)
        }
        return Int64(first) * QueryCalendar.millisecondsPerDay ..< Int64(end) * QueryCalendar.millisecondsPerDay
    }

    /// The first day of the last `count` units, today included: the day after the same day `count`
    /// months or years ago (the month's last day when it's shorter), or `count` days or weeks back.
    private static func start(ofLast count: Int, _ unit: Unit, today: Int) -> Int {
        switch unit {
        case .days: return today - count + 1
        case .weeks: return today - 7 * count + 1
        case .months, .years:
            let (year, month, day) = QueryCalendar.civil(today)
            let months = year * 12 + (month - 1) - (unit == .months ? count : 12 * count)
            let (pastYear, pastMonth) = (months >= 0 ? months / 12 : (months - 11) / 12, (months % 12 + 12) % 12 + 1)
            return QueryCalendar.days(pastYear, pastMonth, min(day, QueryCalendar.daysInMonth(pastYear, pastMonth))) + 1
        }
    }
}
