import Foundation

/// How a job's names are made, beyond its template: saved with a preset.
public struct NamingOptions: Sendable, Hashable, Codable {
    public enum ExtensionCase: String, Sendable, Hashable, Codable, CaseIterable {
        case keep, lowercase, uppercase
    }

    /// What takes the place of a character no name can hold (`/ : \ * ? " < > |` and control
    /// characters), and of spaces when they're replaced.
    public enum Replacement: String, Sendable, Hashable, Codable, CaseIterable {
        case dash, underscore

        var character: Unicode.Scalar {
            self == .dash ? "-" : "_"
        }
    }

    public var extensionCase: ExtensionCase
    /// A sequence's first number.
    public var sequenceStart: Int
    public var illegalCharacters: Replacement
    /// Nil keeps spaces.
    public var spaces: Replacement?
    /// Between a name and the number that tells it from another: `-` makes `Wedding-2`.
    public var collisionSeparator: String
    /// The most UTF-8 bytes in a name, its extension and the `.redlamp` sidecar beside it included:
    /// APFS, HFS+ and SMB shares hold 255.
    public var maximumBytes: Int

    public static let standardMaximumBytes = 255

    public init(
        extensionCase: ExtensionCase = .keep, sequenceStart: Int = 1, illegalCharacters: Replacement = .dash,
        spaces: Replacement? = nil, collisionSeparator: String = "-", maximumBytes: Int = standardMaximumBytes,
    ) {
        self.extensionCase = extensionCase
        self.sequenceStart = sequenceStart
        self.illegalCharacters = illegalCharacters
        self.spaces = spaces
        self.collisionSeparator = collisionSeparator
        self.maximumBytes = min(max(maximumBytes, 32), Self.standardMaximumBytes)
    }

    private enum CodingKeys: String, CodingKey {
        case extensionCase, sequenceStart, illegalCharacters, spaces, collisionSeparator, maximumBytes
    }

    /// Options a newer Redlamp added take their defaults.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let defaults = NamingOptions()
        try self.init(
            extensionCase: container.decodeIfPresent(ExtensionCase.self, forKey: .extensionCase)
                ?? defaults.extensionCase,
            sequenceStart: container.decodeIfPresent(Int.self, forKey: .sequenceStart) ?? defaults.sequenceStart,
            illegalCharacters: container.decodeIfPresent(Replacement.self, forKey: .illegalCharacters)
                ?? defaults.illegalCharacters,
            spaces: container.decodeIfPresent(Replacement.self, forKey: .spaces),
            collisionSeparator: container.decodeIfPresent(String.self, forKey: .collisionSeparator)
                ?? defaults.collisionSeparator,
            maximumBytes: container.decodeIfPresent(Int.self, forKey: .maximumBytes) ?? defaults.maximumBytes,
        )
    }
}

/// What a job is given besides its photos: when it runs, the Mac's zone and language, and its texts.
public struct NamingContext: Sendable, Hashable {
    /// When the job runs: `{now}`.
    public var date: Date
    /// The zone `{now}` and `{modified}` are shown in, and dates shown as `local`.
    public var timeZone: TimeZone
    /// The language of months' and weekdays' names.
    public var locale: Locale
    /// `{text}` is the text named "", `{text:shoot}` the one named `shoot`.
    public var texts: [String: String]

    public init(
        date: Date = Date(), timeZone: TimeZone = .current, locale: Locale = Locale(identifier: "en_US_POSIX"),
        texts: [String: String] = [:],
    ) {
        self.date = date
        self.timeZone = timeZone
        self.locale = locale
        self.texts = texts
    }
}

/// Named counters that continue from one job and session to the next: each counter's last number
/// given. A job returns them moved on, and the caller keeps them once the job is done.
public struct NamingCounters: Sendable, Hashable, Codable {
    public var values: [String: Int]

    public init(_ values: [String: Int] = [:]) {
        self.values = values
    }

    public subscript(name: String) -> Int {
        get { values[name] ?? 0 }
        set { values[name] = newValue }
    }
}

/// Tokens of a template, by their place among its tokens.
public struct NamingTokenSet: Sendable, Hashable, Codable, Sequence {
    public var bits: UInt64

    public init(bits: UInt64 = 0) {
        self.bits = bits
    }

    public var isEmpty: Bool {
        bits == 0
    }

    public func contains(_ token: Int) -> Bool {
        token >= 0 && token < 64 && bits & (1 << UInt64(token)) != 0
    }

    public mutating func insert(_ token: Int) {
        if token >= 0, token < 64 {
            bits |= 1 << UInt64(token)
        }
    }

    public func makeIterator() -> AnyIterator<Int> {
        var remaining = bits
        return AnyIterator {
            guard remaining != 0 else { return nil }
            let token = remaining.trailingZeroBitCount
            remaining &= remaining - 1
            return token
        }
    }
}

/// What was done to a name to make it safe.
public struct NamingAdjustments: OptionSet, Sendable, Hashable, Codable {
    public let rawValue: UInt8

    public init(rawValue: UInt8) {
        self.rawValue = rawValue
    }

    /// Characters no name can hold were replaced, or invisible direction marks dropped.
    public static let replaced = NamingAdjustments(rawValue: 1 << 0)
    /// Dots or spaces were dropped from its ends: a name starting with a dot is hidden.
    public static let trimmed = NamingAdjustments(rawValue: 1 << 1)
    /// It was cut to fit `NamingOptions.maximumBytes`, its longest fields first.
    public static let shortened = NamingAdjustments(rawValue: 1 << 2)
    /// It was a name Windows keeps for devices (`CON`, `NUL`, `COM1`), so it was given an ending.
    public static let reserved = NamingAdjustments(rawValue: 1 << 3)
    /// The template made nothing, so the photo keeps its name.
    public static let keptName = NamingAdjustments(rawValue: 1 << 4)
}

/// How a name was told apart from another one that wanted it.
public struct NamingCollision: Sendable, Hashable {
    public enum Holder: Sendable, Hashable {
        /// A photo of the job, by its place in the job.
        case photo(Int)
        /// A file already in the folder.
        case file(String)
    }

    /// The number after the separator: 2 for `Wedding-2`.
    public var suffix: Int
    /// Who has the name without the number.
    public var holder: Holder

    public init(suffix: Int, holder: Holder) {
        self.suffix = suffix
        self.holder = holder
    }
}

/// A photo's new name, and what was decided to make it.
public struct NamingResult: Sendable, Hashable {
    /// The new file name, with its extension.
    public var name: String
    /// The UTF-8 bytes of the extension and its dot, 0 when there's none.
    var extensionBytes: Int
    /// The tokens that came out empty for the photo, flagged in the preview.
    public var emptyTokens: NamingTokenSet
    public var adjustments: NamingAdjustments
    public var collision: NamingCollision?
    /// The photo keeps its name and folder.
    public var isUnchanged: Bool

    /// The new name without its extension.
    public var base: String {
        String(decoding: name.utf8.dropLast(extensionBytes), as: UTF8.self)
    }
}

/// A job's names, one per photo in the job's order, and what it tells the preview.
public struct NamingBatch: Sendable {
    public var results: [NamingResult]
    /// The counters as they'll be once the job is done.
    public var counters: NamingCounters
    /// For each of the template's tokens, how many photos it came out empty for.
    public var emptyCounts: [Int]
    /// Photos given a number to tell their name from another's.
    public var collisions: Int
    /// Photos whose name and folder stay as they are.
    public var unchanged: Int
}
