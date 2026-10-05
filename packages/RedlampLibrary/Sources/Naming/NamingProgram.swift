import Foundation

/// A template made ready to name many photos: its text made safe once, its formats, zones and
/// patterns read once, and its counters given their first numbers.
struct NamingProgram: Sendable {
    enum Step: Sendable {
        case text(String)
        /// By its place among the template's tokens.
        case token(Int)
    }

    enum Source: Sendable {
        case captured(NamingDateFormat, NamingZone)
        case modified(NamingDateFormat, NamingZone)
        case now(NamingDateFormat, NamingZone)
        case camera, make, model, lens, iso, aperture, shutter, focal, width, height
        case title, caption, creator, copyright, city, state, country, sublocation
        case keywords(String)
        case rating, label, flag
        case name(NamingRange?), original(NamingRange?)
        case number(Int)
        case ext
        case folder(Int)
        case sequence(Int, NamingSequenceScope)
        case total(Int)
        /// By its place among the template's counters.
        case counter(Int, Int)
        case text(String)

        /// Whether shortening a long name may cut it: text, rather than numbers and dates.
        var isText: Bool {
            switch self {
            case .captured, .modified, .now, .iso, .aperture, .shutter, .focal, .width, .height, .rating, .number,
                 .sequence, .total, .counter: false
            default: true
            }
        }
    }

    enum Modifier: Sendable {
        case upper, lower, title
        case range(NamingRange)
        case replace(String, String)
        case regex(NSRegularExpression, String)
        case defaultText(String)
        case before(String)
        case after(String)
    }

    struct Token: Sendable {
        let source: Source
        let modifiers: [Modifier]
        let hasDefault: Bool
    }

    /// The fields of the photo being named, and what the job worked out about it.
    struct Subject {
        let fields: NamingFields
        /// The name now, without its extension.
        let base: String
        let ext: String
        let originalBase: String
        /// The digits that end the original name.
        let number: String
        /// Its folder and the folders above it, nearest first.
        let folders: ArraySlice<String>
        /// Its place in the job, among the photos in its folder, and among those with its extension.
        let sequence: (job: Int, folder: Int, ext: Int)
    }

    let steps: [Step]
    let tokens: [Token]
    let literalBytes: Int
    let safety: NamingSafety
    let names: NamingCalendarNames
    let timeZone: TimeZone
    let zones: [String: TimeZone]
    let context: NamingContext
    let sequenceStart: Int
    let total: Int
    /// Each counter's last number before the job.
    let counterStarts: [Int]
    let counterNames: [String]

    init(
        _ template: NamingTemplate, options: NamingOptions, context: NamingContext, counters: NamingCounters,
        total: Int,
    ) {
        safety = NamingSafety(options)
        names = NamingCalendarNames.names(for: context.locale)
        timeZone = context.timeZone
        self.context = context
        sequenceStart = options.sequenceStart
        self.total = total
        var steps: [Step] = []
        var tokens: [Token] = []
        var literalBytes = 0
        var zones: [String: TimeZone] = [:]
        var counterNames: [String] = []
        for part in template.parts {
            switch part {
            case let .text(text):
                let cleaned = safety.clean(text).0
                literalBytes += cleaned.utf8.count
                steps.append(.text(cleaned))
            case let .token(token):
                let source = Self.source(token, zones: &zones, counters: &counterNames)
                let modifiers = token.modifiers.map(Self.modifier)
                let hasDefault = token.modifiers.contains { modifier in
                    if case .defaultText = modifier {
                        return true
                    }
                    return false
                }
                steps.append(.token(tokens.count))
                tokens.append(Token(source: source, modifiers: modifiers, hasDefault: hasDefault))
            }
        }
        self.steps = steps
        self.tokens = tokens
        self.literalBytes = literalBytes
        self.zones = zones
        self.counterNames = counterNames
        counterStarts = counterNames.map { counters[$0] }
    }

    private static func source(
        _ token: NamingToken, zones: inout [String: TimeZone], counters: inout [String],
    ) -> Source {
        let arguments = token.arguments
        func argument(_ index: Int) -> String {
            index < arguments.count ? arguments[index] : ""
        }
        func digits(_ index: Int) -> Int {
            Int(argument(index)) ?? 1
        }
        func date() -> (NamingDateFormat, NamingZone) {
            let format = argument(0).isEmpty ? .standard : (try? NamingDateFormat(parsing: argument(0))) ?? .standard
            let zone = NamingZone(parsing: argument(1)) ?? .camera
            if case let .named(identifier) = zone {
                zones[identifier] = TimeZone(identifier: identifier)
            }
            return (format, zone)
        }
        switch token.field {
        case .date:
            let (format, zone) = date()
            return .captured(format, zone)
        case .modified:
            let (format, zone) = date()
            return .modified(format, zone)
        case .now:
            let (format, zone) = date()
            return .now(format, zone)
        case .camera: return .camera
        case .make: return .make
        case .model: return .model
        case .lens: return .lens
        case .iso: return .iso
        case .aperture: return .aperture
        case .shutter: return .shutter
        case .focal: return .focal
        case .width: return .width
        case .height: return .height
        case .title: return .title
        case .caption: return .caption
        case .creator: return .creator
        case .copyright: return .copyright
        case .city: return .city
        case .state: return .state
        case .country: return .country
        case .sublocation: return .sublocation
        case .keywords: return .keywords(arguments.isEmpty ? " " : argument(0))
        case .rating: return .rating
        case .label: return .label
        case .flag: return .flag
        case .name: return .name(NamingRange(parsing: argument(0)))
        case .original: return .original(NamingRange(parsing: argument(0)))
        case .number: return .number(digits(0))
        case .ext: return .ext
        case .folder: return .folder(max(Int(argument(0)) ?? 1, 1))
        case .sequence: return .sequence(digits(0), NamingSequenceScope(parsing: argument(1)) ?? .job)
        case .total: return .total(digits(0))
        case .counter:
            let name = argument(0)
            if !counters.contains(name) {
                counters.append(name)
            }
            return .counter(counters.firstIndex(of: name)!, digits(1))
        case .text: return .text(argument(0))
        }
    }

    /// For a pattern made in code that doesn't compile: parsing refuses those.
    private static let matchingNothing = try! NSRegularExpression(pattern: "(?!)")

    private static func modifier(_ modifier: NamingModifier) -> Modifier {
        switch modifier {
        case .upper: return .upper
        case .lower: return .lower
        case .title: return .title
        case let .range(range): return .range(range)
        case let .replace(find, with): return .replace(find, with)
        case let .regex(pattern, with, ignoringCase):
            let expression = (try? NSRegularExpression(
                pattern: pattern, options: ignoringCase ? [.caseInsensitive] : [],
            )) ?? Self.matchingNothing
            return .regex(expression, with)
        case let .defaultText(text): return .defaultText(text)
        case let .before(text): return .before(text)
        case let .after(text): return .after(text)
        }
    }

    // MARK: - Naming a photo

    /// `subject`'s base name, in at most `maximumBytes`, with the tokens that came out empty and what
    /// was done to make it safe. `values` is scratch space, kept between photos.
    func base(
        for subject: Subject, maximumBytes: Int, values: inout [String],
    ) -> (base: String, empty: NamingTokenSet, adjustments: NamingAdjustments) {
        values.removeAll(keepingCapacity: true)
        var empty = NamingTokenSet()
        var adjustments: NamingAdjustments = []
        var bytes = literalBytes
        for (index, token) in tokens.enumerated() {
            var value = value(token.source, of: subject)
            for modifier in token.modifiers {
                apply(modifier, to: &value)
            }
            if value.isEmpty, !token.hasDefault {
                empty.insert(index)
            }
            let (cleaned, changed) = safety.clean(value)
            if changed {
                adjustments.insert(.replaced)
            }
            bytes += cleaned.utf8.count
            values.append(cleaned)
        }
        if bytes > maximumBytes {
            shorten(&values, by: bytes - maximumBytes)
        }
        var base = ""
        base.reserveCapacity(min(bytes, maximumBytes))
        for step in steps {
            switch step {
            case let .text(text): base += text
            case let .token(index): base += values[index]
            }
        }
        let (finished, safe) = safety.finish(base, maximumBytes: maximumBytes)
        adjustments.formUnion(safe)
        if bytes > maximumBytes {
            adjustments.insert(.shortened)
        }
        guard !finished.isEmpty else {
            let kept = safety.finish(safety.clean(subject.base).0, maximumBytes: maximumBytes).0
            return (kept, empty, [.keptName])
        }
        return (finished, empty, adjustments)
    }

    /// Cuts the longest text values first, evening them out, until `excess` bytes are gone or no
    /// text is left to cut; `NamingSafety.finish` cuts whatever remains from the end.
    private func shorten(_ values: inout [String], by excess: Int) {
        var excess = excess
        let candidates = tokens.indices.filter { tokens[$0].source.isText }
        while excess > 0 {
            var longest = 0
            var second = 0
            for index in candidates {
                let length = values[index].utf8.count
                if length > longest {
                    second = longest
                    longest = length
                } else if length < longest, length > second {
                    second = length
                }
            }
            guard longest > 0 else { return }
            let tied = candidates.filter { values[$0].utf8.count == longest }
            let target = max(longest - (excess + tied.count - 1) / tied.count, second)
            for index in tied {
                let before = values[index].utf8.count
                values[index] = NamingSafety.cut(values[index], toBytes: target)
                excess -= before - values[index].utf8.count
            }
        }
    }

    private func value(_ source: Source, of subject: Subject) -> String {
        let fields = subject.fields
        switch source {
        case let .captured(format, zone):
            guard let captured = fields.captured else { return "" }
            return date(NamingMoment(wallClock: captured, offset: fields.capturedOffset), format, zone)
        case let .modified(format, zone):
            guard let modified = fields.modified else { return "" }
            return date(instant: modified, format, zone)
        case let .now(format, zone):
            return date(instant: context.date, format, zone)
        case .camera: return fields.camera ?? ""
        case .make: return fields.make ?? ""
        case .model: return fields.model ?? ""
        case .lens: return fields.lens ?? ""
        case .iso: return number(fields.iso.map { Int($0.rounded()) })
        case .aperture: return decimal(fields.aperture)
        case .shutter:
            guard let shutter = fields.shutter, shutter > 0, shutter.isFinite else { return "" }
            if shutter >= 0.3 {
                return decimal(shutter)
            }
            var text = "1-"
            NamingNumbers.append(Int((1 / shutter).rounded()), digits: 1, to: &text)
            return text
        case .focal: return decimal(fields.focalLength)
        case .width: return number(fields.width)
        case .height: return number(fields.height)
        case .title: return fields.title ?? ""
        case .caption: return fields.caption ?? ""
        case .creator: return fields.creator ?? ""
        case .copyright: return fields.copyright ?? ""
        case .city: return fields.location?.city ?? ""
        case .state: return fields.location?.state ?? ""
        case .country: return fields.location?.country ?? ""
        case .sublocation: return fields.location?.sublocation ?? ""
        case let .keywords(separator):
            return fields.keywords.map { $0.split(separator: "/").last.map(String.init) ?? $0 }
                .joined(separator: separator)
        case .rating: return number(fields.rating)
        case .label: return fields.label ?? ""
        case .flag:
            switch fields.flag {
            case .pick: return "Pick"
            case .reject: return "Reject"
            case nil: return ""
            }
        case let .name(range): return range.map { $0.apply(to: subject.base) } ?? subject.base
        case let .original(range): return range.map { $0.apply(to: subject.originalBase) } ?? subject.originalBase
        case let .number(digits):
            let found = subject.number
            guard !found.isEmpty else { return "" }
            return found.count >= digits ? found : String(repeating: "0", count: digits - found.count) + found
        case .ext: return subject.ext
        case let .folder(level): return level <= subject.folders.count ? subject.folders[subject.folders
                .startIndex + level - 1] : ""
        case let .sequence(digits, scope):
            let place = switch scope {
            case .job: subject.sequence.job
            case .folder: subject.sequence.folder
            case .fileExtension: subject.sequence.ext
            }
            return number(sequenceStart + place, digits: digits)
        case let .total(digits): return number(total, digits: digits)
        case let .counter(slot, digits): return number(counterStarts[slot] + subject.sequence.job + 1, digits: digits)
        case let .text(name): return context.texts[name] ?? ""
        }
    }

    private func number(_ value: Int?, digits: Int = 1) -> String {
        guard let value else { return "" }
        var text = ""
        NamingNumbers.append(value, digits: digits, to: &text)
        return text
    }

    private func decimal(_ value: Double?) -> String {
        guard let value, value > 0, value.isFinite else { return "" }
        var text = ""
        NamingNumbers.appendDecimal(value, to: &text)
        return text
    }

    /// A capture time, which the camera's clock showed, in `zone`; empty when that needs the camera's
    /// offset and it's unknown.
    private func date(_ moment: NamingMoment, _ format: NamingDateFormat, _ zone: NamingZone) -> String {
        let shown: NamingMoment? = switch zone {
        case .camera: moment
        case .utc: moment.shown(at: 0)
        case let .offset(offset): moment.shown(at: offset)
        case .local, .named:
            moment.offset.flatMap { own in
                let instant = Date(timeIntervalSince1970: Double(moment.microseconds) / 1_000_000 - Double(own))
                return moment.shown(at: offset(of: zone, at: instant))
            }
        }
        guard let shown else { return "" }
        var text = ""
        return format.append(shown, names: names, to: &text) ? text : ""
    }

    /// An instant, such as a file's modification date, in `zone`: the Mac's for `camera`.
    private func date(instant: Date, _ format: NamingDateFormat, _ zone: NamingZone) -> String {
        let offset = offset(of: zone, at: instant)
        let moment = NamingMoment(
            microseconds: NamingMoment.microseconds(instant) + Int64(offset) * 1_000_000, offset: offset,
        )
        var text = ""
        return format.append(moment, names: names, to: &text) ? text : ""
    }

    private func offset(of zone: NamingZone, at instant: Date) -> Int {
        switch zone {
        case .camera, .local: timeZone.secondsFromGMT(for: instant)
        case .utc: 0
        case let .offset(offset): offset
        case let .named(identifier): (zones[identifier] ?? timeZone).secondsFromGMT(for: instant)
        }
    }

    private func apply(_ modifier: Modifier, to value: inout String) {
        switch modifier {
        case .upper: value = value.uppercased()
        case .lower: value = value.lowercased()
        case .title: value = value.capitalized
        case let .range(range): value = range.apply(to: value)
        case let .replace(find, with): value = value.replacingOccurrences(of: find, with: with)
        case let .regex(expression, with):
            value = expression.stringByReplacingMatches(
                in: value, range: NSRange(value.startIndex..., in: value), withTemplate: with,
            )
        case let .defaultText(text):
            if value.isEmpty {
                value = text
            }
        case let .before(text):
            if !value.isEmpty {
                value = text + value
            }
        case let .after(text):
            if !value.isEmpty {
                value += text
            }
        }
    }
}
