import Foundation
import OSLog

/// Redlamp's own entries in the unified log, read back for a report: notices, errors and faults
/// from its subsystems since the session began. Reading the current process's log needs no
/// entitlement.
enum AppLogTail {
    static func entries(since date: Date, limit: Int = 60) async -> [String] {
        await Task.detached(priority: .utility) {
            guard let store = try? OSLogStore(scope: .currentProcessIdentifier),
                  let entries = try? store.getEntries(
                      at: store.position(date: date),
                      matching: NSPredicate(format: "subsystem BEGINSWITH %@", "app.redlamp"),
                  )
            else { return [] }
            let time = Date.FormatStyle().hour(.twoDigits(amPM: .omitted)).minute(.twoDigits).second(.twoDigits)
            var lines: [String] = []
            for case let entry as OSLogEntryLog in entries
                where entry.level.rawValue >= OSLogEntryLog.Level.notice.rawValue {
                lines
                    .append(
                        "\(entry.date.formatted(time)) \(name(entry.level)) \(entry.category): \(entry.composedMessage)",
                    )
            }
            return Array(lines.suffix(limit))
        }.value
    }

    private static func name(_ level: OSLogEntryLog.Level) -> String {
        switch level {
        case .fault: "fault"
        case .error: "error"
        case .notice: "notice"
        case .info: "info"
        case .debug: "debug"
        default: "log"
        }
    }
}
