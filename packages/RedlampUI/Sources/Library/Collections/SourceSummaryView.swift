import AppKit
import RedlampLibrary

/// A source's summary in words (LIB-23, LIB-41): its photos and picks, the days they were taken on, its cameras
/// and lenses with how many photos each has, its ISO, shutter and aperture ranges, and its pairs and stacks.
@_spi(Harness) public enum SourceSummaryText {
    /// The most cameras or lenses named; the rest are counted.
    static let named = 6

    public static func lines(_ summary: SourceSummary) -> [String] {
        var lines = [count(summary.photos, "photo") + (summary.picks > 0 ? ", " + count(summary.picks, "pick") : "")]
        if let first = summary.firstDay.flatMap(day), let last = summary.lastDay.flatMap(day) {
            lines.append(
                (summary.days == 1 ? "Taken on \(first)" : "Taken over \(summary.days) days, from \(first) to \(last)")
                    + (summary.undated > 0 ? "; " + count(summary.undated, "photo") + " without a capture time" : ""),
            )
        } else if summary.photos > 0 {
            lines.append("No capture times")
        }
        for (title, values, none) in [("Cameras", summary.cameras, "no camera"), ("Lenses", summary.lenses, "no lens")]
            where !values.isEmpty {
            let shown = values.prefix(named).map { "\($0.name ?? none) (\($0.count.formatted()))" }
            let more = values.count > named ? ", and \(values.count - named) more" : ""
            lines.append("\(title): " + shown.joined(separator: ", ") + more)
        }
        let settings = [
            summary.iso.map { "ISO " + range($0) { String(Int($0)) } },
            summary.shutter.map { range($0, shutter) },
            summary.aperture.map { range($0) { "f/" + number($0) } },
        ].compactMap(\.self)
        if !settings.isEmpty {
            lines.append(settings.joined(separator: " · "))
        }
        let stacks = [
            (Stack.Kind.pair, "raw and JPEG pair"), (.burst, "burst"), (.manual, "manual stack"),
            (.focus, "focus-stack suggestion"),
        ].compactMap { kind, name in summary.stacks[kind].map { count($0, name) } }
        lines.append(stacks.isEmpty ? "No pairs or stacks" : "Stacks: " + stacks.joined(separator: ", "))
        return lines
    }

    /// A day the summary names, as the Mac writes dates: `14 June 2025`.
    public static func day(_ date: QueryDate) -> String? {
        guard case let .day(year, month, day) = date else { return nil }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC") ?? .current
        guard let date = calendar.date(from: DateComponents(year: year, month: month, day: day)) else { return nil }
        var style = Date.FormatStyle.dateTime.day().month(.wide).year()
        style.timeZone = calendar.timeZone
        return date.formatted(style)
    }

    /// `1/8000 s`, `30 s`.
    static func shutter(_ seconds: Double) -> String {
        if seconds > 0, seconds < 1 {
            let denominator = (1 / seconds).rounded()
            if abs(1 / denominator - seconds) < seconds * 0.01 {
                return "1/\(Int(denominator)) s"
            }
        }
        return number(seconds) + " s"
    }

    /// Whole numbers without a point, others to a tenth.
    static func number(_ value: Double) -> String {
        value == value.rounded() ? String(Int(value)) : String(format: "%.1f", value)
    }

    private static func range(_ range: ClosedRange<Double>, _ text: (Double) -> String) -> String {
        range.lowerBound == range.upperBound ? text(range.lowerBound)
            : "\(text(range.lowerBound)) to \(text(range.upperBound))"
    }

    private static func count(_ value: Int, _ noun: String) -> String {
        "\(value.formatted()) \(noun)\(value == 1 ? "" : "s")"
    }
}

/// A source's summary beside its row in the left panel, worked out as it opens.
@MainActor
@_spi(Harness) public enum SourceSummaryPopover {
    private static var current: NSPopover?

    /// What the summary shown says, its title first; empty while none is shown.
    @_spi(Harness) public static var shownLines: [String] {
        guard let current, current.isShown, let stack = current.contentViewController?.view as? NSStackView else {
            return []
        }
        return stack.arrangedSubviews.compactMap { ($0 as? NSTextField)?.stringValue }
    }

    /// Shows `title`'s summary beside `view`, "Counting…" until `summary` is worked out.
    static func show(
        _ title: String, relativeTo view: NSView, summary: @escaping @MainActor () async -> SourceSummary?,
    ) {
        current?.close()
        let heading = NSTextField(labelWithString: title)
        heading.font = .boldSystemFont(ofSize: NSFont.systemFontSize)
        heading.setAccessibilityIdentifier("summary.title")
        let counting = NSTextField(labelWithString: "Counting…")
        counting.textColor = .secondaryLabelColor
        let stack = NSStackView(views: [heading, counting])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 4
        stack.edgeInsets = NSEdgeInsets(top: 12, left: 14, bottom: 12, right: 14)
        stack.setAccessibilityIdentifier("summary")
        let controller = NSViewController()
        controller.view = stack
        let popover = NSPopover()
        popover.behavior = .transient
        popover.contentViewController = controller
        popover.show(relativeTo: view.bounds, of: view, preferredEdge: .maxX)
        current = popover
        Task {
            let found = await summary()
            guard current === popover else { return }
            stack.removeArrangedSubview(counting)
            counting.removeFromSuperview()
            let lines = found.map(SourceSummaryText.lines) ?? ["The library isn't open"]
            for (place, line) in lines.enumerated() {
                let label = NSTextField(wrappingLabelWithString: line)
                label.preferredMaxLayoutWidth = 360
                label.isSelectable = true
                label.setAccessibilityIdentifier("summary.line.\(place)")
                stack.addArrangedSubview(label)
            }
            popover.contentSize = stack.fittingSize
        }
    }

    /// Closes the summary shown.
    @_spi(Harness) public static func close() {
        current?.close()
        current = nil
    }
}
