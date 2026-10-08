import AppKit
import Foundation
import Observation
import RedlampDesign
import Testing

/// The inspector's column measures its rows once per layout pass, however many of them change.
@MainActor
@Suite(.serialized)
struct ColumnLayoutTests {
    /// A row of a set height that counts how often it is measured.
    private final class Row: NSView, HeightProviding {
        var height: CGFloat = 20
        var measured = 0

        func height(forWidth _: CGFloat) -> CGFloat {
            measured += 1
            return height
        }
    }

    @Observable final class Expanded {
        var value: Bool

        init(_ value: Bool) {
            self.value = value
        }
    }

    private func section(_ rows: [NSView], expanded: Expanded) -> PanelSectionView {
        PanelSectionView(title: "Panel", rows: rows, actions: .init(
            isExpanded: { expanded.value },
            isEdited: { false },
            toggle: { _ in expanded.value.toggle() },
            reset: {},
        ))
    }

    private func window(_ content: NSView) -> NSWindow {
        _ = NSApplication.shared
        let window = NSWindow(
            contentRect: CGRect(x: 0, y: 0, width: 300, height: 700), styleMask: [.titled], backing: .buffered,
            defer: false,
        )
        window.contentView = content
        return window
    }

    @Test func `rows that change together are measured once, at their new heights`() async throws {
        let first = (0 ..< 12).map { _ in Row() }
        let second = (0 ..< 12).map { _ in Row() }
        let column = PanelColumnScrollView(views: [
            section(first, expanded: Expanded(true)), section(second, expanded: Expanded(true)),
        ])
        let window = window(column)
        defer { window.contentView = nil }
        try await Task.sleep(for: .milliseconds(20))
        window.contentView?.layoutSubtreeIfNeeded()
        let below = try #require(second.last)
        let top = below.convert(below.bounds, to: column.document).minY
        let rows = first + second
        rows.forEach { $0.measured = 0 }

        for row in first.prefix(6) {
            row.height = 32
            row.invalidateColumnLayout()
        }
        window.contentView?.layoutSubtreeIfNeeded()

        #expect(rows.map(\.measured).max() == 1, "measured \(rows.map(\.measured).max() ?? 0) times")
        #expect(first.prefix(6).allSatisfy { $0.frame.height == 32 })
        #expect(below.convert(below.bounds, to: column.document).minY == top + 6 * 12)
        let document = column.document
        #expect(document.frame.height == document.height(forWidth: document.frame.width))
    }

    @Test func `a panel that opens is laid out before its rows fade in`() async throws {
        let expanded = Expanded(false)
        let rows = (0 ..< 8).map { _ in Row() }
        let panel = section(rows, expanded: expanded)
        let column = PanelColumnScrollView(views: [panel, section([Row()], expanded: Expanded(true))])
        let window = window(column)
        defer { window.contentView = nil }
        try await Task.sleep(for: .milliseconds(20))
        window.contentView?.layoutSubtreeIfNeeded()
        window.display()
        let closed = panel.frame.height

        expanded.value = true
        try await Task.sleep(for: .milliseconds(20))

        #expect(panel.frame.height > closed + 8 * 20)
        #expect(panel.frame.height == panel.height(forWidth: panel.frame.width))
        let document = column.document
        #expect(document.frame.height == document.height(forWidth: document.frame.width))
    }
}
