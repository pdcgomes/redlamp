import Foundation

/// What happened in this session, oldest first, so a report can say what someone did before
/// sending it.
///
/// It stays in memory, and what it writes itself never names a file: photos are Photo A, Photo B
/// and so on, in the order they were opened, and their file names are kept apart for a report
/// that asks for them. Messages it copies from the UI can mention one, so reports redact them.
@MainActor
public final class ActivityLog {
    public struct Event: Codable, Hashable, Sendable {
        public enum Kind: String, Codable, Sendable {
            case photo, tool, panel, action, edit, mask, view, message, error, export, model, system
        }

        public let time: Date
        public let kind: Kind
        public internal(set) var text: String
        /// How many times it happened in a row: a run of the same event is one entry.
        public internal(set) var count = 1
        /// Events with the same key a moment apart replace each other, as a pinch's zoom levels do.
        let key: String?

        private enum CodingKeys: String, CodingKey {
            case time, kind, text, count
        }

        public init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            time = try container.decode(Date.self, forKey: .time)
            kind = try container.decode(Kind.self, forKey: .kind)
            text = try container.decode(String.self, forKey: .text)
            count = try container.decode(Int.self, forKey: .count)
            key = nil
        }

        init(time: Date, kind: Kind, text: String, key: String?) {
            self.time = time
            self.kind = kind
            self.text = text
            self.key = key
        }
    }

    public static let defaultCapacity = 500

    public private(set) var events: [Event] = []
    private let capacity: Int
    private let now: () -> Date
    private var aliases: [URL: String] = [:]
    private var fileNames: [String] = []

    public init(capacity: Int = ActivityLog.defaultCapacity, now: @escaping () -> Date = Date.init) {
        self.capacity = capacity
        self.now = now
    }

    /// Adds an event. With `key`, it replaces the last event when that has the same key and is
    /// less than `window` seconds old; without one, a repeat of the last event counts it again.
    public func record(
        _ kind: Event.Kind,
        _ text: String,
        replacing key: String? = nil,
        within window: TimeInterval = 2,
    ) {
        let time = now()
        if var last = events.last {
            if let key, last.key == key, time.timeIntervalSince(last.time) < window {
                events[events.count - 1] = Event(time: time, kind: kind, text: text, key: key)
                return
            }
            if key == nil, last.key == nil, last.kind == kind, last.text == text {
                last.count += 1
                events[events.count - 1] = last
                return
            }
        }
        events.append(Event(time: time, kind: kind, text: text, key: key))
        if events.count > capacity {
            events.removeFirst(events.count - capacity)
        }
    }

    public func events(since date: Date) -> [Event] {
        events.filter { $0.time >= date }
    }

    /// "Photo A", "Photo B", … "Photo AA", by the order photos were first opened this session.
    public func alias(for url: URL) -> String {
        if let alias = aliases[url] {
            return alias
        }
        let alias = "Photo \(Self.letters(aliases.count))"
        aliases[url] = alias
        fileNames.append(url.lastPathComponent)
        return alias
    }

    /// Each alias with its photo's file name, in the order they were opened.
    public var photoNames: [(alias: String, fileName: String)] {
        fileNames.enumerated().map { ("Photo \(Self.letters($0.offset))", $0.element) }
    }

    /// 0 is A, 25 is Z, 26 is AA.
    static func letters(_ index: Int) -> String {
        var index = index
        var letters = ""
        repeat {
            letters = String(UnicodeScalar(UInt8(65 + index % 26))) + letters
            index = index / 26 - 1
        } while index >= 0
        return letters
    }
}
