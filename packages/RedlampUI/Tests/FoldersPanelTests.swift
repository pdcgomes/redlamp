import AppKit
import Foundation
import RedlampDocument
import Testing
@testable import RedlampUI

/// The Folders panel: roots with counts, subfolders listed as they open, missing roots, and rows
/// made only for what's on screen.
@MainActor
struct FoldersPanelTests {
    private let root = FileManager.default.temporaryDirectory.appending(path: "panel-\(UUID().uuidString)")

    private func photos(_ paths: [String]) throws {
        for path in paths {
            let url = root.appending(path: path)
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(), withIntermediateDirectories: true,
            )
            FileManager.default.createFile(atPath: url.path, contents: Data([1]))
        }
    }

    private func eventually(_ condition: () -> Bool) async throws {
        for _ in 0 ..< 600 where !condition() {
            try await Task.sleep(for: .milliseconds(5))
        }
    }

    private func showPanel(_ model: EditorModel, height: CGFloat = 400) -> (SidebarListView, NSWindow) {
        _ = NSApplication.shared
        let window = NSWindow(
            contentRect: CGRect(x: 0, y: 0, width: 260, height: height), styleMask: [.titled], backing: .buffered,
            defer: false,
        )
        let list = SidebarListView(model: model)
        window.contentView = list
        list.layoutSubtreeIfNeeded()
        return (list, window)
    }

    private func rows(_ outline: SidebarOutlineView) -> [FolderRow] {
        (0 ..< outline.numberOfRows).compactMap { row in
            guard let node = outline.item(atRow: row) as? SidebarNode, case let .folder(folder) = node.kind else {
                return nil
            }
            return folder
        }
    }

    @Test func `roots show their photo counts, and subfolders appear when a root opens`() async throws {
        defer { try? FileManager.default.removeItem(at: root) }
        try photos(["Trip/a.ARW", "Trip/b.ARW", "Trip/Day 2/d.ARW"] + (0 ..< 1234).map { "Trip/Day 1/\($0).ARW" })
        let model = EditorModel(engine: StubEngine())
        model.open([root.appending(path: "Trip")])
        let (list, window) = showPanel(model)
        defer { window.contentView = nil }

        try await eventually { rows(list.folders).first?.count == 2 }
        let trip = try #require(rows(list.folders).first)
        #expect(trip.name == "Trip" && trip.isRoot && trip.hasSubfolders)
        try await eventually { rows(list.folders).first?.isOpen == true }
        #expect(rows(list.folders).count == 1, "collapsed")

        list.folders.expandItem(list.folders.item(atRow: 0))
        try await eventually { rows(list.folders).count == 3 && rows(list.folders)[1].count == 1234 }
        #expect(rows(list.folders).map(\.name) == ["Trip", "Day 1", "Day 2"])
        #expect(model.library.isExpanded(trip.url))
    }

    @Test func `the highlight moves to the folder that opens, not only its name`() async throws {
        defer { try? FileManager.default.removeItem(at: root) }
        try photos(["Trip/a.ARW", "Trip/Day 2/b.ARW"])
        let model = EditorModel(engine: StubEngine())
        model.open([root.appending(path: "Trip")])
        model.library.setExpanded(root.appending(path: "Trip"), true)
        let (list, window) = showPanel(model)
        defer { window.contentView = nil }
        func highlighted() -> [String] {
            // The row views draw the highlight, and a reload makes them again as the list next lays out.
            list.layoutSubtreeIfNeeded()
            return (0 ..< list.folders.numberOfRows).compactMap { index in
                guard (list.folders.rowView(atRow: index, makeIfNecessary: false) as? SidebarRowView)?.isCurrentStep
                    == true, let node = list.folders.item(atRow: index) as? SidebarNode,
                    case let .folder(folder) = node.kind else { return nil }
                return folder.name
            }
        }
        try await eventually { rows(list.folders).first?.isOpen == true && rows(list.folders).count == 2 }
        #expect(highlighted() == ["Trip"])

        let day2 = try #require(rows(list.folders).first { $0.name == "Day 2" })
        list.folders.open(day2)
        try await eventually { rows(list.folders).first { $0.name == "Day 2" }?.isOpen == true }
        #expect(highlighted() == ["Day 2"])
    }

    @Test func `a folder with no photos is dimmed and can't be opened, until photos arrive`() async throws {
        defer { try? FileManager.default.removeItem(at: root) }
        try photos(["Trip/a.ARW", "Trip/Day 2/b.ARW"])
        try FileManager.default.createDirectory(
            at: root.appending(path: "Trip/Empty"),
            withIntermediateDirectories: true,
        )
        let model = EditorModel(engine: StubEngine())
        model.open([root.appending(path: "Trip")])
        model.library.setExpanded(root.appending(path: "Trip"), true)
        let (list, window) = showPanel(model)
        defer { window.contentView = nil }
        func row(_ name: String) -> FolderRow? {
            rows(list.folders).first { $0.name == name }
        }
        try await eventually { row("Empty")?.count == 0 && row("Day 2")?.count == 1 }
        let empty = try #require(row("Empty"))
        #expect(empty.isEmpty && !empty.isSelectable)
        #expect(row("Day 2")?.isSelectable == true)

        list.folders.open(empty)
        try await Task.sleep(for: .milliseconds(100))
        #expect(model.folder?.lastPathComponent == "Trip", "clicking an empty folder doesn't open it")

        try photos(["Trip/Empty/c.ARW"])
        try await eventually { row("Empty")?.isSelectable == true }
        #expect(row("Empty")?.count == 1, "photos arriving undim it")
        try list.folders.open(#require(row("Empty")))
        try await eventually { model.folder?.lastPathComponent == "Empty" }
        #expect(model.folder?.lastPathComponent == "Empty")
    }

    @Test func `a folder holding only subfolders opens with Show Photos in Subfolders`() async throws {
        defer { try? FileManager.default.removeItem(at: root) }
        try photos(["Year/March/a.ARW"])
        let model = EditorModel(engine: StubEngine())
        model.library.add([root.appending(path: "Year")])
        let (list, window) = showPanel(model)
        defer { window.contentView = nil }
        try await eventually { rows(list.folders).first?.count == 0 }
        #expect(rows(list.folders).first?.isSelectable == false)

        model.library.setIncludesSubfolders(true)
        try await eventually { rows(list.folders).first?.isSelectable == true }
        #expect(rows(list.folders).first?.isSelectable == true)
    }

    @Test func `a missing root is flagged in the panel`() async throws {
        defer { try? FileManager.default.removeItem(at: root) }
        try photos(["Gone/a.ARW"])
        let model = EditorModel(engine: StubEngine())
        model.library.add([root.appending(path: "Gone")])
        try FileManager.default.removeItem(at: root.appending(path: "Gone"))
        var restored = false
        model.library.restore { _, _ in restored = true }
        try await eventually { restored }
        let (list, window) = showPanel(model)
        defer { window.contentView = nil }
        try await eventually { rows(list.folders).first?.isMissing == true }
        #expect(rows(list.folders).first?.isMissing == true)
        #expect(rows(list.folders).first?.count == nil)
    }

    @Test func `five thousand subfolders make only the rows on screen`() async throws {
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root.appending(path: "Big"), withIntermediateDirectories: true)
        for index in 0 ..< 5000 {
            try FileManager.default.createDirectory(
                at: root.appending(path: String(format: "Big/%05d", index)), withIntermediateDirectories: false,
            )
        }
        let model = EditorModel(engine: StubEngine())
        model.library.add([root.appending(path: "Big")])
        model.library.setExpanded(root.appending(path: "Big"), true)
        let (list, window) = showPanel(model)
        defer { window.contentView = nil }
        try await eventually { list.folders.numberOfRows == 5001 }
        #expect(list.folders.numberOfRows == 5001)
        list.layoutSubtreeIfNeeded()
        let made = (0 ..< list.folders.numberOfRows).count {
            list.folders.rowView(atRow: $0, makeIfNecessary: false) != nil
        }
        #expect(made < 60, "\(made) row views for a 400 pt column")
        try await Task.sleep(for: .milliseconds(200))
        #expect(model.library.tree.count < 80, "only the folders on screen are listed")

        let neighbour = list.folders.view(atColumn: 0, row: 3, makeIfNecessary: false)
        try FileManager.default.createDirectory(
            at: root.appending(path: "Big/00001/Inner"), withIntermediateDirectories: false,
        )
        let start = ContinuousClock.now
        model.library.listTree(root.appending(path: "Big/00001"))
        try await eventually { list.folders.isExpandable(list.folders.item(atRow: 2)) }
        #expect(list.folders.isExpandable(list.folders.item(atRow: 2)), "00001 has a subfolder now")
        #expect(list.folders.view(atColumn: 0, row: 3, makeIfNecessary: false) === neighbour, "only its row reloaded")
        #expect(ContinuousClock.now - start < .milliseconds(500))
    }
}
