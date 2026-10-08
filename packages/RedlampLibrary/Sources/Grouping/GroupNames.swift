import Foundation

/// Groups' names in words (LIB-41), in English, as the command line prints them: days and spans of
/// capture times as the camera's clock showed them, in milliseconds as the column store keeps them.
/// The app can write its own from a group's value and span.
enum GroupNames {
    private static let months = [
        "January", "February", "March", "April", "May", "June", "July", "August", "September", "October",
        "November", "December",
    ]

    /// `14 June 2025`, `day` being days since 1970.
    static func day(_ day: Int) -> String {
        let (year, month, date) = QueryCalendar.civil(day)
        return "\(date) \(months[month - 1]) \(year)"
    }

    /// `14 June 2025`, of a day as the query language has it.
    static func day(_ date: QueryDate) -> String {
        guard case let .day(year, month, day) = date, (1 ... 12).contains(month) else { return "\(date)" }
        return "\(day) \(months[month - 1]) \(year)"
    }

    /// `14 June 2025, 14:03 to 14:47`: one time when both are in the same minute, and both days when
    /// they're on different days.
    static func span(_ first: Int64, _ last: Int64) -> String {
        let (firstDay, lastDay) = (QueryCalendar.day(ofMilliseconds: first), QueryCalendar.day(ofMilliseconds: last))
        let (from, to) = (time(first), time(last))
        if firstDay != lastDay {
            return "\(day(firstDay)), \(from) to \(day(lastDay)), \(to)"
        }
        return from == to ? "\(day(firstDay)), \(from)" : "\(day(firstDay)), \(from) to \(to)"
    }

    /// `14:03`.
    static func time(_ milliseconds: Int64) -> String {
        let minutes = Int(milliseconds - Int64(QueryCalendar.day(ofMilliseconds: milliseconds))
            * QueryCalendar.millisecondsPerDay) / 60000
        return digits(minutes / 60) + ":" + digits(minutes % 60)
    }

    /// `2025-06-14T14:03:12`, the clock's time without a zone, as JSON gives it.
    static func timestamp(_ milliseconds: Int64) -> String {
        let day = QueryCalendar.day(ofMilliseconds: milliseconds)
        let (year, month, date) = QueryCalendar.civil(day)
        let seconds = Int(milliseconds - Int64(day) * QueryCalendar.millisecondsPerDay) / 1000
        return "\(year)-\(digits(month))-\(digits(date))T\(digits(seconds / 3600)):\(digits(seconds / 60 % 60))"
            + ":\(digits(seconds % 60))"
    }

    private static func digits(_ number: Int) -> String {
        number < 10 ? "0\(number)" : "\(number)"
    }
}
