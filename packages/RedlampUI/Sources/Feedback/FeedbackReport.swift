import Foundation

/// A report as the person writes it, and the GitHub issue it becomes.
///
/// The issue's body names its attachments `attachment:<name>`; the relay uploads them and puts
/// their addresses in. Everything in the body and in `diagnostics.json` goes through
/// `FeedbackRedactor` first, because issues are public.
public struct FeedbackReport: Codable, Sendable, Hashable {
    public enum Kind: String, CaseIterable, Codable, Sendable, Identifiable {
        case bug, idea, question

        public var id: String {
            rawValue
        }

        public var title: String {
            switch self {
            case .bug: "Bug"
            case .idea: "Idea"
            case .question: "Question"
            }
        }

        /// The repository's own labels for each.
        public var label: String {
            switch self {
            case .bug: "bug"
            case .idea: "enhancement"
            case .question: "question"
            }
        }
    }

    public enum Frequency: String, CaseIterable, Codable, Sendable, Identifiable {
        case everyTime, sometimes, once

        public var id: String {
            rawValue
        }

        public var title: String {
            switch self {
            case .everyTime: "Every time"
            case .sometimes: "Sometimes"
            case .once: "Once"
            }
        }
    }

    public enum OtherPhotos: String, CaseIterable, Codable, Sendable, Identifiable {
        case yes, no, notTried

        public var id: String {
            rawValue
        }

        public var title: String {
            switch self {
            case .yes: "Yes, those too"
            case .no: "No, only this one"
            case .notTried: "Haven't tried"
            }
        }
    }

    /// What goes with the person's own words; the sheet shows all of it before it's sent.
    public struct Details: Codable, Sendable, Hashable {
        public var system = true
        /// The open photo, its edit and its history.
        public var photo = true
        /// What happened before the report, the editor's state and the messages on screen.
        public var activity = true
        public var log = true
        /// Off: photos are Photo A, Photo B.
        public var fileNames = false

        public init() {}
    }

    public struct Screenshot: Codable, Sendable, Hashable, Identifiable {
        public var id = UUID()
        public var jpeg: Data
        public var width: Int
        public var height: Int
        /// "Redlamp's window", "Pasted", or the file's name.
        public var source: String

        public init(jpeg: Data, width: Int, height: Int, source: String) {
            self.jpeg = jpeg
            self.width = width
            self.height = height
            self.source = source
        }
    }

    public var id = UUID()
    public var kind = Kind.bug
    public var featureID: String?
    public var title = ""
    /// What happened (a bug), what they'd like to do (an idea), or the message (a question).
    public var body = ""
    /// What they expected (a bug), or how it could work (an idea).
    public var expected = ""
    public var steps = ""
    public var frequency: Frequency?
    public var otherPhotos: OtherPhotos?
    public var githubUsername = ""
    public var details = Details()
    public var screenshots: [Screenshot] = []

    public static let titleLimit = 120
    /// GitHub's 65,536 characters, less room for the addresses the relay puts in.
    public static let bodyLimit = 60000
    public static let screenshotLimit = 3
    /// How far back the activity in the issue goes; diagnostics.json has the whole session.
    public static let activityWindow: TimeInterval = 15 * 60
    public static let diagnosticsName = "diagnostics.json"

    public init() {}

    public var topic: FeedbackTopic? {
        featureID.flatMap(FeedbackArea.topic)
    }

    public var isComplete: Bool {
        !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// "[Masking › Objects] Clicking a second object drops the first".
    public var issueTitle: String {
        let title = String(Self.sanitized(title).trimmingCharacters(in: .whitespacesAndNewlines)
            .prefix(Self.titleLimit))
        return topic.map { "[\($0.path)] \(title)" } ?? title
    }

    public var labels: [String] {
        ["in-app", kind.label] + (topic.map { [$0.area.label] } ?? [])
    }

    public static func screenshotName(_ index: Int) -> String {
        "screenshot-\(index + 1).jpg"
    }

    /// A GitHub username to mention, so its owner hears about replies; `nil` unless it's valid.
    public var mention: String? {
        let name = githubUsername.trimmingCharacters(in: .whitespaces)
            .trimmingCharacters(in: CharacterSet(charactersIn: "@"))
        guard (1 ... 39).contains(name.count),
              name.range(of: #"^[A-Za-z0-9](?:[A-Za-z0-9]|-(?=[A-Za-z0-9]))*$"#, options: .regularExpression) != nil
        else { return nil }
        return "@\(name)"
    }

    var includesDetails: Bool {
        details.system || details.photo || details.activity || details.log
    }

    // MARK: - The issue

    public func issueBody(context: FeedbackContext, system: SystemSnapshot, log: [String]) -> String {
        let redactor = context.redactor(keepingFileNames: details.fileNames)
        var limits = Limits()
        while true {
            let body = redactor.redact(render(context: context, system: system, log: log, limits: limits))
            if body.count <= Self.bodyLimit {
                return body
            }
            guard limits.shrink() else {
                return String(body.prefix(Self.bodyLimit - 120))
                    + "\n\n*Shortened to fit GitHub's limit; \(Self.diagnosticsName) has everything.*\n"
            }
        }
    }

    /// How much of each long section the body takes, shrunk until it fits.
    private struct Limits {
        var activity = 150
        var log = 60
        var history = 40

        mutating func shrink() -> Bool {
            guard activity > 10 || log > 0 || history > 10 else { return false }
            activity = max(10, activity * 2 / 3)
            log = log > 10 ? log / 2 : 0
            history = max(10, history * 2 / 3)
            return true
        }
    }

    private func render(context: FeedbackContext, system: SystemSnapshot, log: [String], limits: Limits) -> String {
        var out: [String] = [marker(system: system)]
        var facts = [topic.map { "**Area:** \($0.path)" }, "**Kind:** \(kind.title)"]
        if kind == .bug {
            facts.append(frequency.map { "**How often:** \($0.title)" })
            facts.append(otherPhotos.map { "**Other photos:** \($0.title)" })
        }
        out.append(facts.compactMap(\.self).joined(separator: " · "))
        out.append(details.system
            ? "**From:** Redlamp \(system.version) on macOS \(system.macOS), \(system.model) (\(system.chip))"
            : "**From:** Redlamp \(system.version)")
        if let mention {
            out.append("**Reported by:** \(mention)")
        }

        switch kind {
        case .bug:
            out += section("What happened", body)
            out += section("What I expected", expected)
            out += section("Steps to reproduce", steps)
        case .idea:
            out += section("What I'd like to do", body)
            out += section("How it could work", expected)
        case .question:
            out += section("Message", body)
        }

        if !screenshots.isEmpty {
            out += ["", "### Screenshots", ""]
            out += screenshots.enumerated().map { index, shot in
                "![Screenshot \(index + 1): \(Self.sanitized(shot.source))](attachment:\(Self.screenshotName(index)))"
            }
        }

        if details.photo, let photo = context.photo {
            out += disclosure("Photo", table([
                ("Photo", photo.fileName), ("Format", photo.format), ("Camera", photo.camera), ("Lens", photo.lens),
                ("Exposure", photo.exposure), ("Size", photo.size), ("As-shot white balance", photo.asShotWhiteBalance),
                ("Look in the file", photo.embeddedLook), ("Lens correction", photo.lensCorrection),
                ("Disk", photo.volume), ("Notice", photo.protection),
            ]))
        }
        if details.photo, let edit = context.edit {
            out += disclosure("Edit (process version \(edit.processVersion))", editLines(edit))
        }
        if details.photo, context.history.count > 1 {
            out += disclosure(
                "This photo's history (\(context.history.count) steps)",
                historyLines(context, limit: limits.history),
            )
        }
        if details.activity {
            let since = context.captured.addingTimeInterval(-Self.activityWindow)
            let events = context.activity.filter { $0.time >= since }
            if !events.isEmpty {
                let shown = events.suffix(limits.activity)
                let rows = shown.map { event in
                    (
                        Self.before(event.time, context.captured),
                        event.text + (event.count > 1 ? " ×\(event.count)" : ""),
                    )
                }
                let title = shown.count < events.count
                    ? "What happened before (last 15 minutes, the latest \(shown.count) of \(events.count) events)"
                    : "What happened before (last 15 minutes, \(Self.count(events.count, "event")))"
                out += disclosure(title, table(rows.map { ($0.0, Optional($0.1)) }, headers: ("Before", "What")))
            }
            let state = context.state
            out += disclosure("Editor state", table([
                ("Tool", state.tool), ("Panels open", state.panels.joined(separator: ", ")), ("Zoom", state.zoom),
                ("Before / After", state.beforeAfter), ("Selected mask", state.selectedMask),
                ("Focused slider", state.focusedSlider), ("Photos in the folder", state.folderPhotos.map(String.init)),
                ("Photos selected", state.selectedPhotos > 1 ? "\(state.selectedPhotos)" : nil),
                ("Hidden", state.hidden.isEmpty ? nil : state.hidden.joined(separator: ", ")),
                ("On screen", context.messages.isEmpty ? nil : context.messages.joined(separator: " · ")),
            ]))
        }
        if details.system {
            out += disclosure("System", table(system.rows.map { ($0.0, Optional($0.1)) }))
        }
        if details.log, !log.isEmpty, limits.log > 0 {
            let shown = log.suffix(limits.log).map { $0.replacingOccurrences(of: "```", with: "'''") }
            out += disclosure(
                "Redlamp's log (\(Self.count(shown.count, "entry", "entries")))",
                ["```text"] + shown + ["```"],
            )
        }
        out += ["", "---"]
        if includesDetails {
            out.append("[\(Self.diagnosticsName)](attachment:\(Self.diagnosticsName)) has these details in full, "
                + "with the photo's edit in Redlamp's sidecar format.")
        }
        out.append("<sub>Sent from Redlamp's Report a Bug or Send Feedback.</sub>")
        return out.joined(separator: "\n") + "\n"
    }

    /// A hidden line tooling can group reports by. Its JSON never holds the person's words.
    private func marker(system: SystemSnapshot) -> String {
        var fields = ["report": id.uuidString, "kind": kind.rawValue, "version": system.version]
        fields["area"] = featureID
        let data = (try? JSONSerialization.data(
            withJSONObject: fields,
            options: [.sortedKeys, .withoutEscapingSlashes],
        )) ?? Data()
        return "<!-- redlamp-feedback v1 \(String(decoding: data, as: UTF8.self)) -->"
    }

    private func section(_ title: String, _ text: String) -> [String] {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? [] : ["", "### \(title)", "", Self.sanitized(text)]
    }

    private func disclosure(_ summary: String, _ lines: [String]) -> [String] {
        lines.isEmpty ? [] : ["", "<details><summary>\(summary)</summary>", ""] + lines + ["", "</details>"]
    }

    private func table(_ rows: [(String, String?)], headers: (String, String) = ("", "")) -> [String] {
        let rows = rows.compactMap { name, value in value.map { (name, $0) } }.filter { !$0.1.isEmpty }
        guard !rows.isEmpty else { return [] }
        return ["| \(headers.0) | \(headers.1) |", "| --- | --- |"]
            + rows.map { "| \(Self.cell($0.0)) | \(Self.cell($0.1)) |" }
    }

    private func editLines(_ edit: FeedbackContext.Edit) -> [String] {
        var lines =
            [
                "- **Treatment:** \(edit.treatment) · **Base Look:** \(edit.baseLook) · **White balance:** \(edit.whiteBalance)",
            ]
        if let recipe = edit.recipe {
            lines.append("- **Recipe:** \(recipe)")
        }
        lines += edit.settings.map { "- **\($0.panel):** \($0.values.joined(separator: ", "))" }
        if edit.pointCurve {
            lines.append("- **Point curve:** edited")
        }
        if !edit.masks.isEmpty {
            lines.append("- **Masks (\(edit.masks.count)):**")
            lines += edit.masks.map { "  - \(Self.sanitized($0))" }
        }
        let extras = [
            edit.crop.map { "**Crop:** \($0)" }, edit.orientation.map { "**Orientation:** \($0)" },
            edit.spots > 0 ? "**Healing spots:** \(edit.spots)" : nil,
            edit.snapshots > 0 ? "**Snapshots:** \(edit.snapshots)" : nil,
        ].compactMap(\.self)
        if !extras.isEmpty {
            lines.append("- " + extras.joined(separator: " · "))
        }
        return lines
    }

    private func historyLines(_ context: FeedbackContext, limit: Int) -> [String] {
        let start = max(0, context.history.count - limit)
        var lines = start > 0 ? ["(the first \(start) steps are in \(Self.diagnosticsName))", ""] : []
        for index in start ..< context.history.count {
            let note = index == context.historyIndex && index < context.history.count - 1
                ? " **(current)**" : index > context.historyIndex ? " (undone)" : ""
            lines.append("\(index + 1). \(Self.sanitized(context.history[index]))\(note)")
        }
        return lines
    }

    static func count(_ number: Int, _ singular: String, _ plural: String? = nil) -> String {
        "\(number) \(number == 1 ? singular : plural ?? singular + "s")"
    }

    /// How long before the report an event was: "4:05", "1:02:09".
    static func before(_ time: Date, _ captured: Date) -> String {
        let seconds = max(0, Int(captured.timeIntervalSince(time).rounded()))
        let (hours, minutes, rest) = (seconds / 3600, seconds / 60 % 60, seconds % 60)
        return hours > 0
            ? String(format: "%d:%02d:%02d", hours, minutes, rest)
            : String(format: "%d:%02d", minutes, rest)
    }

    /// The person's words can't hide markup in the issue: an HTML comment there could pass for
    /// the tracker's own markers.
    static func sanitized(_ text: String) -> String {
        text.replacingOccurrences(of: "<!--", with: "&lt;!--").replacingOccurrences(of: "-->", with: "--&gt;")
    }

    private static func cell(_ text: String) -> String {
        sanitized(text).replacingOccurrences(of: "|", with: "\\|").replacingOccurrences(of: "\n", with: " ")
    }
}

// MARK: - diagnostics.json

extension FeedbackReport {
    private struct Diagnostics: Encodable {
        let format = "app.redlamp.feedback-diagnostics"
        let formatVersion = 1
        let report: UUID
        let kind: Kind
        let area: String?
        let captured: Date
        let system: SystemSnapshot?
        let photo: FeedbackContext.Photo?
        let edit: FeedbackContext.Edit?
        let history: [String]?
        let historyIndex: Int?
        let state: FeedbackContext.State?
        let messages: [String]?
        let activity: [ActivityLog.Event]?
        let log: [String]?
        let photoNames: [PhotoName]?
    }

    /// Everything the issue summarises, in full, and the photo's edit as its sidecar holds it.
    /// `nil` when the person sends none of the details.
    public func diagnostics(context: FeedbackContext, system: SystemSnapshot, log: [String]) throws -> Data? {
        guard includesDetails else { return nil }
        let document = Diagnostics(
            report: id, kind: kind, area: featureID, captured: context.captured,
            system: details.system ? system : nil,
            photo: details.photo ? context.photo : nil,
            edit: details.photo ? context.edit : nil,
            history: details.photo ? context.history : nil,
            historyIndex: details.photo ? context.historyIndex : nil,
            state: details.activity ? context.state : nil,
            messages: details.activity ? context.messages : nil,
            activity: details.activity ? context.activity : nil,
            log: details.log ? log : nil,
            photoNames: details.fileNames ? context.photos : nil,
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        let redactor = context.redactor(keepingFileNames: details.fileNames)
        let text = try redactor.redact(String(decoding: encoder.encode(document), as: UTF8.self))
        guard var object = try JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any] else { return nil }
        if details.photo, let sidecar = context.sidecar,
           var edit = try JSONSerialization.jsonObject(with: Data(redactor.redact(String(
               decoding: sidecar,
               as: UTF8.self,
           )).utf8))
           as? [String: Any] {
            // A long session's history can make the sidecar large; the edit itself stays small.
            if sidecar.count > 1_000_000 {
                edit["session"] = nil
            }
            object["sidecar"] = edit
        }
        return try JSONSerialization.data(
            withJSONObject: object,
            options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes],
        )
    }
}
