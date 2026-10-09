import Foundation
import RedlampDocument
import RedlampEngineAPI
import RedlampLibrary
import Synchronization

/// `redlamp library metadata`: the photos' ratings, flags, labels, marks and IPTC Core's fields (LIB-15,
/// LIB-22), set on the photos a query finds or from a preset, and their capture times shifted, set or
/// given the camera's zone, each change a batch with Undo; the presets; and manual stacks made and opened
/// (LIB-28), through `redlamp library stacks`. Collections' changes go in the same journal
/// (`LibraryCommand+Collections`). Every change first finishes one a forced quit left.
extension LibraryCommand {
    static let metadataUsage = """
    usage: redlamp library metadata --index <path> [<query>] [--limit <n>] [--json]
           redlamp library metadata set --index <path> <query> [--rating <0-5>] [--flag pick|reject|none]
                                    [--label <name>|none] [--mark | --unmark] [--title <text>] [--caption <text>]
                                    [--creator <text>] [--copyright <text>] [--sublocation <text>] [--city <text>]
                                    [--state <text>] [--country <text>] [--country-code <text>] [--codes <file>]
                                    [--dry-run] [--json]
           redlamp library metadata shift --index <path> <query> --by <amount> [--dry-run] [--json]
           redlamp library metadata shift --index <path> <query> --to <date time> [--photo <name>] [--dry-run]
                                    [--json]
           redlamp library metadata zone --index <path> <query> --offset <±hh:mm> | --file [--dry-run] [--json]
           redlamp library metadata preset <name> --index <path> <query> [--codes <file>] [--dry-run] [--json]
           redlamp library metadata presets --index <path> [--json]
           redlamp library metadata presets save <name> --index <path> [--<field> <text>]… [--append <field>]…
                                    [--prefix <field>]…
           redlamp library metadata presets remove <name> --index <path>
           redlamp library metadata undo --index <path> [--dry-run] [--json]
           redlamp library stacks stack <query> --index <path> [--top <name>] [--dry-run] [--json]
           redlamp library stacks unstack|remove|split|top <query> --index <path> [--dry-run] [--json]
           redlamp library stacks move <query> --index <path> --by <places> [--dry-run] [--json]

    A capture time is the camera's, by its clock, with the shift its sidecar gives it; the photo's file is
    never changed. shift --by adds an amount (+1h30m, -90s, 2d, -05:00, or seconds) to each photo's; --to
    gives the photo named by --photo, or the first the query finds in capture order, that time
    (2024-06-01 15:30:00) and shifts the rest by as much. zone says which zone the camera's clock was in,
    or with --file gives the photos back the zones their files record.
    """

    /// The texts `set` and `presets save` take, by option.
    private static let textOptions: [(option: String, field: MetadataPreset.Field)] = [
        ("--title", .title), ("--caption", .caption), ("--creator", .creator), ("--copyright", .copyright),
        ("--sublocation", .sublocation), ("--city", .city), ("--state", .state), ("--country", .country),
        ("--country-code", .countryCode),
    ]

    static func metadata(_ arguments: [String]) async throws {
        let rest = Array(arguments.dropFirst())
        switch arguments.first {
        case "set": try await setMetadata(rest)
        case "shift": try await shiftCaptureTimes(rest)
        case "zone": try await setCameraZone(rest)
        case "preset": try await applyPreset(rest)
        case "presets": try await presets(rest)
        case "undo": try await undoMetadata(rest)
        default: try await listMetadata(arguments)
        }
    }

    // MARK: - The photos' fields

    /// Each photo the query finds (every photo without one) with its fields as the index shows them.
    private static func listMetadata(_ arguments: [String]) async throws {
        let options = try Arguments(arguments, valued: ["--index", "--limit"])
        guard let path = options.value("--index") else {
            throw CLIError(description: "metadata needs --index\n\n\(metadataUsage)")
        }
        let query = try metadataQuery(options.positional.joined(separator: " "))
        let limit = try options.int("--limit")
        let rows = try await withMetadata(path, recovering: false) { metadata in
            var ids = try await queriedPhotoIDs(query, in: metadata.index)
            if let limit {
                ids = Array(ids.prefix(limit))
            }
            let found = ids
            return try await metadata.index.read { reader in
                try found.compactMap { id -> (path: String, row: PhotoRecord, collections: [String])? in
                    guard let row = try reader.photo(id: id),
                          let path = try reader.photoPath(id: id) else { return nil }
                    return try (path, row, reader.collections(ofPhoto: id).map(\.text))
                }
            }
        }
        if options.has("--json") {
            let photos = rows.map { photo -> [String: Any] in
                var object: [String: Any] = ["path": photo.path, "rating": photo.row.rating, "mark": photo.row.marked]
                object["flag"] = photo.row.flag?.rawValue
                object["label"] = photo.row.label?.rawValue
                object["customLabel"] = photo.row.customLabel
                object["title"] = photo.row.title
                object["caption"] = photo.row.caption
                object["creator"] = photo.row.creator
                object["copyright"] = photo.row.copyright
                object["location"] = photo.row.location.map(locationObject)
                object["collections"] = photo.collections
                object["stack"] = photo.row.stack.map { stack -> [String: Any] in
                    var object: [String: Any] = ["top": stack.top]
                    object["id"] = stack.id?.uuidString
                    object["position"] = stack.position
                    return object
                }
                object["otherApps"] = photo.row.otherFields.map(\.rawValue).sorted()
                if photo.row.captureShift != 0 {
                    object["captureShift"] = photo.row.captureShift
                }
                if let zone = givenZone(photo.row) {
                    object["captureOffset"] = zone
                }
                return object
            }
            let data = try JSONSerialization.data(withJSONObject: photos, options: [.prettyPrinted, .sortedKeys])
            print(String(decoding: data, as: UTF8.self))
            return
        }
        for photo in rows {
            print(photo.path + "\t" + describe(photo.row, collections: photo.collections))
        }
        print("\(metadataCount(rows.count)) photos")
    }

    /// `4 stars, picked, red, marked, title “Tram 28”, in Lisbon, Portugal, collections Clients/Acme`.
    private static func describe(_ row: PhotoRecord, collections: [String]) -> String {
        var parts: [String] = []
        if row.rating > 0 {
            parts.append(row.rating == 1 ? "1 star" : "\(row.rating) stars")
        }
        if let flag = row.flag {
            parts.append(flag == .pick ? "picked" : "rejected")
        }
        if let label = row.label?.rawValue ?? row.customLabel.map({ "label “\($0)”" }) {
            parts.append(label)
        }
        if row.marked {
            parts.append("marked")
        }
        for (name, value) in [
            ("title", row.title), ("caption", row.caption), ("creator", row.creator), ("copyright", row.copyright),
        ] {
            if let value {
                parts.append("\(name) “\(value)”")
            }
        }
        if let location = row.location {
            let place = [location.sublocation, location.city, location.state, location.country]
                .compactMap(\.self).joined(separator: ", ")
            parts.append("in " + place + (location.countryCode.map { " (\($0))" } ?? ""))
        }
        if !collections.isEmpty {
            parts.append("collections " + collections.joined(separator: ", "))
        }
        if let stack = row.stack {
            let place = stack.position.map { ", place \($0 + 1)" } ?? ""
            parts
                .append(stack.id
                    .map { "stack \($0.uuidString)\(stack.top ? ", its top" : "")\(place)" } ?? "its burst's top")
        }
        if row.captureShift != 0, let captured = row.captured {
            parts.append("taken \(CaptureTimeChange.describe(time: captured)), shifted "
                + CaptureTimeChange.describe(shift: row.captureShift))
        }
        if let zone = givenZone(row) {
            parts.append("the camera's zone " + CaptureTimeChange.describe(zone: zone))
        }
        return parts.isEmpty ? "nothing" : parts.joined(separator: ", ")
    }

    /// The zone the photo's sidecar gives its camera, where it isn't the one its file records.
    private static func givenZone(_ row: PhotoRecord) -> Int? {
        row.cameraCaptured != nil && row.capturedOffset != row.cameraZone ? row.capturedOffset : nil
    }

    private static func locationObject(_ location: PhotoLocation) -> [String: String] {
        var object: [String: String] = [:]
        object["sublocation"] = location.sublocation
        object["city"] = location.city
        object["state"] = location.state
        object["country"] = location.country
        object["countryCode"] = location.countryCode
        return object
    }

    // MARK: - Changes

    private static func setMetadata(_ arguments: [String]) async throws {
        let valued = Set(["--index", "--rating", "--flag", "--label", "--codes"]).union(textOptions.map(\.option))
        let options = try Arguments(arguments, valued: valued)
        guard let path = options.value("--index") else {
            throw CLIError(description: "metadata set needs --index\n\n\(metadataUsage)")
        }
        let codes = try options.value("--codes").map { try CodeReplacements(contentsOf: URL(fileURLWithPath: $0)) }
            ?? CodeReplacements()
        var fields: [MetadataField] = []
        if let rating = try options.int("--rating") {
            guard (0 ... 5).contains(rating) else { throw CLIError(description: "--rating needs 0 to 5 stars") }
            fields.append(.rating(rating))
        }
        if let flag = options.value("--flag") {
            guard let parsed = flag == "none" ? .some(nil) : PhotoFlag(rawValue: flag).map(Optional.some) else {
                throw CLIError(description: "--flag needs pick, reject or none")
            }
            fields.append(.flag(parsed))
        }
        if let label = options.value("--label") {
            fields.append(.namedLabel(label == "none" ? nil : label))
        }
        if options.has("--mark") || options.has("--unmark") {
            fields.append(.mark(options.has("--mark")))
        }
        for (option, field) in textOptions {
            guard let text = options.value(option).map(codes.expanded) else { continue }
            let value: String? = text.isEmpty ? nil : text
            let set: MetadataField = switch field {
            case .title: .title(value)
            case .caption: .caption(value)
            case .creator: .creator(value)
            case .copyright: .copyright(value)
            case .sublocation: .sublocation(value)
            case .city: .city(value)
            case .state: .state(value)
            case .country: .country(value)
            case .countryCode: .countryCode(value)
            }
            fields.append(set)
        }
        guard !fields.isEmpty else {
            throw CLIError(description: "metadata set needs a field to set\n\n\(metadataUsage)")
        }
        let query = try metadataQuery(options.positional.joined(separator: " "))
        try await withMetadata(path) { metadata in
            let ids = try await queriedPhotoIDs(query, in: metadata.index)
            try await planned(metadata.plan(.set(fields, on: ids)), metadata: metadata, options: options)
        }
    }

    private static func applyPreset(_ arguments: [String]) async throws {
        let options = try Arguments(arguments, valued: ["--index", "--codes"])
        guard let name = options.positional.first, let path = options.value("--index") else {
            throw CLIError(description: "metadata preset needs a preset's name and --index\n\n\(metadataUsage)")
        }
        let codes = try options.value("--codes").map { try CodeReplacements(contentsOf: URL(fileURLWithPath: $0)) }
            ?? CodeReplacements()
        let query = try metadataQuery(options.positional.dropFirst().joined(separator: " "))
        try await withMetadata(path) { metadata in
            guard let preset = try await metadata.presets()[name] else { throw MetadataError.noSuchPreset(name) }
            let ids = try await queriedPhotoIDs(query, in: metadata.index)
            try await planned(
                metadata.plan(.preset(preset, to: ids, codes: codes)), metadata: metadata, options: options,
            )
        }
    }

    // MARK: - Capture times

    /// `shift --by` and `shift --to`: the capture times of the photos a query finds, moved by an amount,
    /// or one photo's set and the rest moved by as much.
    private static func shiftCaptureTimes(_ arguments: [String]) async throws {
        let options = try Arguments(arguments, valued: ["--index", "--by", "--to", "--photo"])
        guard let path = options.value("--index"), !options.positional.isEmpty else {
            throw CLIError(description: "metadata shift needs a query and --index\n\n\(metadataUsage)")
        }
        let query = try metadataQuery(options.positional.joined(separator: " "))
        try await withMetadata(path) { metadata in
            let ids = try await queriedPhotoIDs(query, in: metadata.index)
            let change: CaptureTimeChange
            switch (options.value("--by"), options.value("--to")) {
            case let (amount?, nil):
                guard let seconds = seconds(amount) else {
                    throw CLIError(description: "--by needs an amount: +1h30m, -90s, 2d, -05:00 or seconds")
                }
                change = .shift(ids, by: seconds)
            case let (nil, text?):
                guard let time = cameraTime(text) else {
                    throw CLIError(description: "--to needs a date and time: 2024-06-01 15:30:00")
                }
                let name = options.value("--photo")
                let photo = try await metadata.index.read { reader in
                    try ids.first { id in
                        guard let row = try reader.photo(id: id) else { return false }
                        return name.map { row.name == $0 } ?? (row.captured != nil)
                    }
                }
                guard let photo else {
                    throw CLIError(description: name.map { "the query finds no photo named \($0)" }
                        ?? "the query finds no photo with a capture time")
                }
                change = .set(photo, to: time, shifting: ids.filter { $0 != photo })
            case (nil, nil):
                throw CLIError(description: "metadata shift needs --by or --to\n\n\(metadataUsage)")
            case (_?, _?):
                throw CLIError(description: "metadata shift takes --by or --to, not both")
            }
            try await plannedCapture(metadata.plan(change), metadata: metadata, options: options)
        }
    }

    /// `zone`: the zone the camera's clock was in, for the photos a query finds, or with `--file` the
    /// zones their files record.
    private static func setCameraZone(_ arguments: [String]) async throws {
        let options = try Arguments(arguments, valued: ["--index", "--offset"])
        guard let path = options.value("--index"), !options.positional.isEmpty else {
            throw CLIError(description: "metadata zone needs a query and --index\n\n\(metadataUsage)")
        }
        let offset: Int?
        switch (options.value("--offset"), options.has("--file")) {
        case let (text?, false):
            guard let seconds = zone(text) else {
                throw CLIError(description: "--offset needs a zone: +09:00, -05:30 or Z")
            }
            offset = seconds
        case (nil, true):
            offset = nil
        default:
            throw CLIError(description: "metadata zone needs --offset or --file\n\n\(metadataUsage)")
        }
        let query = try metadataQuery(options.positional.joined(separator: " "))
        try await withMetadata(path) { metadata in
            let ids = try await queriedPhotoIDs(query, in: metadata.index)
            try await plannedCapture(metadata.plan(.zone(ids, offset: offset)), metadata: metadata, options: options)
        }
    }

    /// Runs `plan` as `planned` does; with `--dry-run`, prints each photo's capture time and zone as they
    /// are and as they'd be, and changes nothing.
    private static func plannedCapture(_ plan: MetadataPlan, metadata: LibraryMetadata, options: Arguments)
        async throws {
        guard options.has("--dry-run") else {
            return try await planned(plan, metadata: metadata, options: options)
        }
        let photos = plan.photos
        let rows = try await metadata.index.read { reader in try photos.map { try reader.photo(id: $0.id) } }
        let changes = zip(photos, rows).compactMap { photo, row in
            row.map { (
                path: photo.path,
                before: (time: $0.captured, offset: $0.capturedOffset),
                after: photo.capture(of: $0),
            ) }
        }
        if options.has("--json") {
            func moment(_ capture: (time: Date?, offset: Int?)) -> [String: Any] {
                var object: [String: Any] = [:]
                object["captured"] = capture.time.map(CaptureTimeChange.describe(time:))
                object["zone"] = capture.offset.map(CaptureTimeChange.describe(zone:))
                return object
            }
            let objects = changes.map { change -> [String: Any] in
                ["path": change.path, "before": moment(change.before), "after": moment(change.after)]
            }
            let data = try JSONSerialization.data(
                withJSONObject: ["title": plan.title, "photos": objects], options: [.prettyPrinted, .sortedKeys],
            )
            print(String(decoding: data, as: UTF8.self))
            return
        }
        for change in changes {
            print(change.path + "\t" + describeCapture(change.before) + " → " + describeCapture(change.after))
        }
        print("\(plan.title): \(metadataCount(changes.count)) photos would change. Nothing was written.")
    }

    /// `2024-06-01 09:30:00 UTC+01:00`, without a zone when the camera recorded none.
    private static func describeCapture(_ capture: (time: Date?, offset: Int?)) -> String {
        guard let time = capture.time else { return "no capture time" }
        return CaptureTimeChange.describe(time: time)
            + (capture.offset.map { " " + CaptureTimeChange.describe(zone: $0) } ?? "")
    }

    /// Seconds from `+1h30m`, `-90s`, `2d`, `-05:00`, `+01:30:15` or a number of seconds.
    static func seconds(_ text: String) -> Int? {
        var rest = Substring(text.trimmingCharacters(in: .whitespaces))
        let sign = rest.first == "-" ? -1 : 1
        if rest.first == "-" || rest.first == "+" {
            rest = rest.dropFirst()
        }
        guard !rest.isEmpty, rest.allSatisfy(\.isASCII) else { return nil }
        if let plain = Int(rest) {
            return sign * plain
        }
        if rest.contains(":") {
            let parts = rest.split(separator: ":", omittingEmptySubsequences: false).compactMap { Int($0) }
            guard parts.count == rest.count(where: { $0 == ":" }) + 1, (2 ... 3).contains(parts.count),
                  parts.allSatisfy({ $0 >= 0 }), parts.dropFirst().allSatisfy({ $0 < 60 })
            else { return nil }
            return sign * (parts[0] * 3600 + parts[1] * 60 + (parts.count == 3 ? parts[2] : 0))
        }
        let units: [Character: Int] = ["d": 86400, "h": 3600, "m": 60, "s": 1]
        var total = 0
        var digits = ""
        for character in rest {
            if character.isNumber {
                digits.append(character)
                continue
            }
            guard let value = Int(digits), let unit = units[character] else { return nil }
            total += value * unit
            digits = ""
        }
        return digits.isEmpty ? sign * total : nil
    }

    /// A zone's seconds east of UTC from `+09:00`, `-0530`, `+9` or `Z`.
    static func zone(_ text: String) -> Int? {
        let text = text.trimmingCharacters(in: .whitespaces)
        if text == "Z" || text.uppercased() == "UTC" {
            return 0
        }
        guard let sign = text.first, sign == "+" || sign == "-" else { return nil }
        let digits = text.dropFirst().replacingOccurrences(of: ":", with: "")
        guard [1, 2, 4].contains(digits.count), digits.allSatisfy({ $0.isASCII && $0.isNumber }),
              let hours = Int(digits.prefix(digits.count == 4 ? 2 : digits.count)),
              let minutes = digits.count == 4 ? Int(digits.suffix(2)) : 0, minutes < 60
        else { return nil }
        return (sign == "-" ? -1 : 1) * (hours * 3600 + minutes * 60)
    }

    /// `2024-06-01 15:30:00`, with a `T` or to the minute too, as a time by the camera's clock.
    static func cameraTime(_ text: String) -> Date? {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        let text = text.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: "T", with: " ")
        for format in ["yyyy-MM-dd HH:mm:ss", "yyyy-MM-dd HH:mm"] {
            formatter.dateFormat = format
            if let date = formatter.date(from: text) {
                return date
            }
        }
        return nil
    }

    private static func undoMetadata(_ arguments: [String]) async throws {
        let options = try Arguments(arguments, valued: ["--index"])
        guard let path = options.value("--index") else {
            throw CLIError(description: "metadata undo needs --index\n\n\(metadataUsage)")
        }
        try await withMetadata(path) { metadata in
            try await planned(metadata.planUndo(), metadata: metadata, options: options)
        }
    }

    // MARK: - Presets

    private static func presets(_ arguments: [String]) async throws {
        let rest = Array(arguments.dropFirst())
        switch arguments.first {
        case "save": try await savePreset(rest)
        case "remove":
            let options = try Arguments(rest, valued: ["--index"])
            guard let name = options.positional.first, let path = options.value("--index") else {
                throw CLIError(description: "metadata presets remove needs a name and --index\n\n\(metadataUsage)")
            }
            try await withMetadata(path, recovering: false) { try await $0.removePreset(named: name) }
            print("“\(name)” removed")
        default:
            let options = try Arguments(arguments, valued: ["--index"])
            guard let path = options.value("--index") else {
                throw CLIError(description: "metadata presets needs --index\n\n\(metadataUsage)")
            }
            let presets = try await withMetadata(path, recovering: false) { try await $0.presets() }
            if options.has("--json") {
                let objects = presets.presets.map { preset -> [String: Any] in
                    let fields = preset.fields.reduce(into: [String: Any]()) { fields, entry in
                        fields[entry.key.rawValue] = ["text": entry.value.text, "mode": entry.value.mode.rawValue]
                    }
                    return ["name": preset.name, "fields": fields]
                }
                let data = try JSONSerialization.data(withJSONObject: objects, options: [.prettyPrinted, .sortedKeys])
                print(String(decoding: data, as: UTF8.self))
                return
            }
            for preset in presets.presets {
                let fields = preset.fields.sorted { $0.key < $1.key }.map { field, entry in
                    "\(field.rawValue) \(entry.mode == .replace ? "" : entry.mode.rawValue + " ")“\(entry.text)”"
                }
                print(preset.name + "\t" + fields.joined(separator: ", "))
            }
            print("\(metadataCount(presets.presets.count)) presets")
        }
    }

    /// Keeps a preset of the fields given, each replacing what a photo has unless `--append` or
    /// `--prefix` names it.
    private static func savePreset(_ arguments: [String]) async throws {
        let valued = Set(["--index", "--append", "--prefix"]).union(textOptions.map(\.option))
        let options = try Arguments(arguments, valued: valued)
        guard let name = options.positional.first, let path = options.value("--index") else {
            throw CLIError(description: "metadata presets save needs a name and --index\n\n\(metadataUsage)")
        }
        var fields: [MetadataPreset.Field: MetadataPreset.Entry] = [:]
        for (option, field) in textOptions {
            guard let text = options.value(option) else { continue }
            let mode: MetadataPreset.Mode = options.values("--append").contains(field.rawValue) ? .append
                : options.values("--prefix").contains(field.rawValue) ? .prefix : .replace
            fields[field] = MetadataPreset.Entry(text, mode: mode)
        }
        let modes = options.values("--append") + options.values("--prefix")
        if let unknown = modes.first(where: { MetadataPreset.Field(rawValue: $0).flatMap { fields[$0] } == nil }) {
            throw CLIError(
                description: "--append and --prefix name a field the preset gives a text: \(unknown) isn't one",
            )
        }
        guard !fields.isEmpty else { throw CLIError(description: "a preset needs a field\n\n\(metadataUsage)") }
        try await withMetadata(path, recovering: false) {
            try await $0.save(MetadataPreset(name: name, fields: fields))
        }
        print("“\(name)” saved: \(fields.keys.sorted().map(\.rawValue).joined(separator: ", "))")
    }

    // MARK: - Stacks

    /// The verbs `redlamp library stacks` hands here.
    static let stackVerbs: Set = ["stack", "unstack", "remove", "split", "move", "top"]

    /// `stacks stack`, `unstack`, `remove`, `split`, `move` and `top`: manual stacks of the photos a query finds,
    /// as Lightroom Classic's Stacking has them.
    static func stackChange(_ arguments: [String]) async throws {
        let verb = arguments.first ?? ""
        let options = try Arguments(arguments.dropFirst(), valued: ["--index", "--top", "--by"])
        guard let path = options.value("--index"), !options.positional.isEmpty else {
            throw CLIError(description: "stacks \(verb) needs a query and --index\n\n\(metadataUsage)")
        }
        var places: Int?
        if verb == "move" {
            guard let by = options.value("--by"), let offset = Int(by), offset != 0 else {
                throw CLIError(description: "stacks move needs --by, a whole number of places other than 0")
            }
            places = offset
        }
        let query = try metadataQuery(options.positional.joined(separator: " "))
        try await withMetadata(path) { metadata in
            let engine = QueryEngine(index: metadata.index)
            try await engine.load()
            let ids = try await queriedPhotoIDs(query, in: metadata.index)
            guard let first = ids.first else { throw CLIError(description: "the query finds no photos") }
            let stacks = try await StackFinder.find(in: metadata.index, store: engine.store ?? ColumnStore())
            let change: StackChange
            switch verb {
            case "stack":
                var top: Int64?
                if let name = options.value("--top") {
                    top = try await metadata.index.read { reader in
                        try ids.first { try reader.photo(id: $0)?.name == name }
                    }
                    guard top != nil else { throw CLIError(description: "the query finds no photo named \(name)") }
                }
                change = .stack(ids, top: top)
            case "unstack": change = .unstack(ids)
            case "remove": change = .remove(ids)
            case "split": change = .split(before: first)
            case "move": change = .move(first, by: places ?? 0)
            default: change = .top(first)
            }
            try await planned(metadata.plan(change, in: stacks), metadata: metadata, options: options)
        }
    }

    // MARK: - Running

    /// Runs `plan`, printing its progress on stderr and then what it did; with `--dry-run`, prints
    /// each photo it would change and its fields after, and changes nothing.
    static func planned(_ plan: MetadataPlan, metadata: LibraryMetadata, options: Arguments) async throws {
        let photos = plan.photos
        if options.has("--dry-run") {
            if options.has("--json") {
                let objects = try photos.map { photo -> [String: Any] in
                    try [
                        "path": photo.path, "before": jsonObject(photo.before), "after": jsonObject(photo.after),
                    ]
                }
                let data = try JSONSerialization.data(withJSONObject: [
                    "title": plan.title, "photos": objects, "collections": plan.definedCollections.map(\.text),
                ], options: [.prettyPrinted, .sortedKeys])
                print(String(decoding: data, as: UTF8.self))
                return
            }
            for photo in photos {
                let changed = photo.after.keys.sorted().filter { photo.after[$0] != photo.before[$0] }
                print(photo.path + "\t" + changed
                    .map { "\($0): \(fieldText(photo.before[$0])) → \(fieldText(photo.after[$0]))" }
                    .joined(separator: "; "))
            }
            print("\(plan.title): \(metadataCount(photos.count)) photos would change. Nothing was written.")
            return
        }
        let reported = Mutex(ContinuousClock.now)
        let clock = ContinuousClock()
        let started = clock.now
        let outcome = try await metadata.run(plan) { done, total in
            let report = reported.withLock { last in
                guard ContinuousClock.now - last >= .seconds(1) || done == total else { return false }
                last = .now
                return true
            }
            if report {
                FileHandle.standardError
                    .write(Data("  \(metadataCount(done)) of \(metadataCount(total)) sidecars\n".utf8))
            }
        }
        let seconds = (clock.now - started) / .seconds(1)
        if options.has("--json") {
            let data = try JSONSerialization.data(withJSONObject: [
                "batch": outcome.batch.uuidString, "title": outcome.title, "state": outcome.state.rawValue,
                "photos": outcome.photos, "written": outcome.written, "skipped": outcome.skipped, "seconds": seconds,
                "indexSeconds": outcome.indexTime / .seconds(1), "sidecarSeconds": outcome.sidecarTime / .seconds(1),
            ], options: [.prettyPrinted, .sortedKeys])
            print(String(decoding: data, as: UTF8.self))
            return
        }
        print(String(
            format: "%@: %@, %@ photos changed, %@ sidecars written in %.1f s", outcome.title,
            describeState(outcome.state), metadataCount(outcome.photos), metadataCount(outcome.written), seconds,
        ))
        if !outcome.skipped.isEmpty {
            print("  \(metadataCount(outcome.skipped.count)) sidecars this build can't write kept as they were:")
            outcome.skipped.prefix(20).forEach { print("    \($0)") }
        }
    }

    /// A field's value for a dry run: its text, a list joined, or `none`.
    private static func fieldText(_ value: JSONValue?) -> String {
        switch value {
        case nil, .null?: "none"
        case let .string(text)?: "“\(text)”"
        case let .number(number)?: number.rounded() == number ? String(Int(number)) : String(number)
        case let .bool(flag)?: flag ? "yes" : "no"
        case let value?: (try? String(decoding: JSONEncoder().encode(value), as: UTF8.self)) ?? "?"
        }
    }

    private static func jsonObject(_ values: [String: JSONValue]) throws -> Any {
        try JSONSerialization.jsonObject(with: JSONEncoder().encode(values), options: [.fragmentsAllowed])
    }

    // MARK: - Helpers

    /// Opens the index, finishes a change a forced quit left (unless `recovering` is false), then runs
    /// `body`.
    static func withMetadata<T>(
        _ path: String, recovering: Bool = true, _ body: (LibraryMetadata) async throws -> T,
    ) async throws -> T {
        let url = URL(fileURLWithPath: path)
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw CLIError(description: "no index at \(url.path) (make one with redlamp library index)")
        }
        let index = try await LibraryIndex.open(at: url)
        let metadata = LibraryMetadata(index: index)
        do {
            if recovering {
                for outcome in try await metadata.recover() {
                    FileHandle.standardError.write(Data(
                        "\(outcome.title), which a forced quit interrupted: \(describeState(outcome.state))\n".utf8,
                    ))
                }
            }
            let result = try await body(metadata)
            await index.close()
            return result
        } catch {
            await index.close()
            if let error = error as? MetadataError {
                throw CLIError(description: error.description)
            }
            if let error = error as? CaptureTimeError {
                throw CLIError(description: error.description)
            }
            throw error
        }
    }

    static func metadataQuery(_ text: String) throws -> LibraryQuery {
        do {
            return try LibraryQuery(parsing: text)
        } catch {
            let caret = String(repeating: " ", count: error.range.lowerBound)
                + String(repeating: "^", count: max(error.range.count, 1))
            throw CLIError(description: "\(text)\n\(caret)\n\(error.message)")
        }
    }

    /// The IDs of the photos `query` finds.
    static func queriedPhotoIDs(_ query: LibraryQuery, in index: LibraryIndex) async throws -> [Int64] {
        let engine = QueryEngine(index: index)
        try await engine.load()
        var found: [Int64] = []
        for try await result in engine.search(query) {
            found = Array(result.ids)
        }
        return found
    }

    static func describeState(_ state: BatchState) -> String {
        switch state {
        case .planned: "planned"
        case .running: "unfinished"
        case .finished: "done"
        case .rollingBack: "rolling back"
        case .rolledBack: "rolled back"
        case .undone: "undone"
        }
    }

    /// `20,000`, whatever the locale.
    static func metadataCount(_ value: Int) -> String {
        value.formatted(.number.locale(Locale(identifier: "en_US")))
    }
}
