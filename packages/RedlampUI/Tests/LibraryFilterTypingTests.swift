import AppKit
import CoreGraphics
import Foundation
import ImageIO
import RedlampDocument
import RedlampEngineAPI
import RedlampLibrary
import Testing
import UniformTypeIdentifiers
@_spi(Harness) @testable import RedlampUI

@MainActor
extension LibraryFilterTests {
    // MARK: - Keys, typing and the selection

    @Test func `the backslash shows the bar in Library, where Develop keeps it for Before and After`() {
        #expect(ShortcutAction.resolve(.char("\\"), in: .library)?.action == .toggleFilterBar)
        #expect(ShortcutAction.resolve(.char("\\"), in: .develop)?.action == .beforeAfter)
        #expect(ShortcutAction.resolve(.char("l", command: true), in: .library)?.action == .toggleFilters)
        #expect(ShortcutAction.allCases.filter { $0.sortField != nil }.count == LibrarySortField.allCases.count)
    }

    @Test func `the bar lays its sections out above the grid, its controls apart, its text taking the keyboard`(
    ) async throws {
        defer { cleanUp() }
        let (model, _) = try await open()
        let filters = try #require(model.libraryFilters)
        filters.setFilter(LibraryFilter(text: "rating>=3", sections: [.text, .attribute, .metadata]))
        model.showLibrary(.grid)
        let window = NSWindow(
            contentRect: CGRect(x: 0, y: 0, width: 1600, height: 1000), styleMask: [.titled], backing: .buffered,
            defer: false,
        )
        window.contentViewController = ModuleViews.make(model: model, theme: ThemeSettings())
        window.setContentSize(NSSize(width: 1600, height: 1000))
        defer { window.contentViewController = nil }
        model.perform(.toggleFilterBar)
        try await eventually { filters.columns.count == 4 }
        window.contentView?.layoutSubtreeIfNeeded()
        let bar = try #require(Self.find(LibraryFilterBarView.self, in: window.contentView))
        let grid = try #require(Self.find(LibraryGridView.self, in: window.contentView))
        #expect(bar.frame.height == LibraryFilterBarView.headerHeight + LibraryFilterBarView.textHeight
            + LibraryFilterBarView.attributeHeight + LibraryFilterBarView.metadataHeight)
        #expect(grid.convert(grid.bounds, to: nil).maxY <= bar.convert(bar.bounds, to: nil).minY + 0.5)
        let controls = bar.subviews.filter { !$0.isHidden && $0.frame.width > 0 && !($0 is FilterAttributeRow) }
            .filter { !($0 is FilterColumnsView) && $0.accessibilityIdentifier() != "library.filter.clear" }
        for (index, control) in controls.enumerated() {
            #expect(bar.bounds.contains(control.frame), "\(type(of: control)) inside the bar")
            for other in controls[(index + 1)...] {
                #expect(!control.frame.insetBy(dx: 1, dy: 1).intersects(other.frame), "\(control) and \(other)")
            }
        }
        #expect((window.firstResponder as? NSTextView)?.delegate === bar.field)
        if let path = ProcessInfo.processInfo.environment["REDLAMP_FILTER_BAR_IMAGE"],
           let view = window.contentView, let image = view.bitmapImageRepForCachingDisplay(in: view.bounds) {
            view.cacheDisplay(in: view.bounds, to: image)
            try image.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
        }
        model.perform(.toggleFilterBar)
        try await eventually { bar.isHidden }
        #expect(bar.isHidden && !filters.isBarShown)
    }

    @Test func `a key typed shows in the bar without laying its columns out again`() async throws {
        defer { cleanUp() }
        let (model, _) = try await open()
        let filters = try #require(model.libraryFilters)
        filters.setFilter(LibraryFilter(sections: [.text, .metadata]))
        model.showLibrary(.grid)
        let window = NSWindow(
            contentRect: CGRect(x: 0, y: 0, width: 1600, height: 1000), styleMask: [.titled], backing: .buffered,
            defer: false,
        )
        window.contentViewController = ModuleViews.make(model: model, theme: ThemeSettings())
        window.setContentSize(NSSize(width: 1600, height: 1000))
        defer { window.contentViewController = nil }
        model.perform(.toggleFilterBar)
        try await eventually { filters.columns.count == 4 }
        window.contentView?.layoutSubtreeIfNeeded()
        let bar = try #require(Self.find(LibraryFilterBarView.self, in: window.contentView))
        let columns = try #require(Self.find(FilterColumnsView.self, in: window.contentView))
        let frames = columns.subviews.map(\.frame)
        for text in ["r", "ra", "rating>=3"] {
            filters.setText(text)
            try await eventually { bar.field.stringValue == text }
            #expect(bar.field.stringValue == text)
            #expect(!columns.needsLayout, "the columns laid out again after \(text)")
        }
        try await listed(model)
        window.contentView?.layoutSubtreeIfNeeded()
        #expect(columns.subviews.map(\.frame) == frames)
    }

    @Test func `a click on a column's row chooses its photos, ⌘-click adds another, and All takes them out`(
    ) async throws {
        defer { cleanUp() }
        let (model, _) = try await open()
        let filters = try #require(model.libraryFilters)
        filters.setFilter(LibraryFilter(sections: [.text, .metadata], columns: [.kind, .camera]))
        model.showLibrary(.grid)
        let window = NSWindow(
            contentRect: CGRect(x: 0, y: 0, width: 1600, height: 1000), styleMask: [.titled], backing: .buffered,
            defer: false,
        )
        window.contentViewController = ModuleViews.make(model: model, theme: ThemeSettings())
        window.setContentSize(NSSize(width: 1600, height: 1000))
        defer { window.contentViewController = nil }
        model.perform(.toggleFilterBar)
        try await eventually { filters.columns[0]?.values.contains { $0.name == "png" } == true }

        try await click("library.filter.column.0.value.png", in: window)
        try await listed(model)
        #expect(filters.filter.text == "ext:png" && names(model) == ["IMG_0004.PNG"])
        try await click("library.filter.column.0.value.jpeg", in: window, modifiers: .command)
        try await listed(model)
        #expect(filters.filter.text.contains("jpeg") && filters.filter.text.contains("png"))
        #expect(model.items.count == 5)
        try await click("library.filter.column.0.all", in: window)
        try await listed(model)
        #expect(filters.filter.text.isEmpty && !model.library.isFiltered)
    }

    /// Presses and releases the mouse on the view under `identifier`'s middle, as the e2e driver does, once a click
    /// there reaches what takes it (`clickable`). A press that reached another view could start that view's own
    /// tracking loop (a pop-up's menu, a text selection, the grid's rubber band), which would hold the test waiting
    /// for a release that only comes after the press returns.
    func click(_ identifier: String, in window: NSWindow, modifiers: NSEvent.ModifierFlags = []) async throws {
        var target: (hit: NSView, location: NSPoint)?
        try await eventually {
            target = Self.clickable(identifier, in: window)
            return target != nil
        }
        let (hit, location) = try #require(target, "\(identifier) on screen, where a click reaches it")
        for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
            let event = try #require(NSEvent.mouseEvent(
                with: type, location: location, modifierFlags: modifiers,
                timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber, context: nil,
                eventNumber: 0, clickCount: 1, pressure: type == .leftMouseUp ? 0 : 1,
            ))
            if type == .leftMouseDown {
                hit.mouseDown(with: event)
            } else {
                hit.mouseUp(with: event)
            }
        }
    }

    /// The view a click on the middle of `identifier`'s view reaches, and where in the window, when it's inside what
    /// takes that click: the table the view is a row of, or the view itself. The middle mustn't be scrolled out of
    /// sight.
    static func clickable(_ identifier: String, in window: NSWindow) -> (hit: NSView, location: NSPoint)? {
        window.contentView?.layoutSubtreeIfNeeded()
        guard let view = Self.view(identifier, in: window.contentView) else { return nil }
        let middle = NSPoint(x: view.bounds.midX, y: view.bounds.midY)
        guard view.visibleRect.contains(middle) else { return nil }
        let location = view.convert(middle, to: nil)
        let taker = sequence(first: view, next: \.superview).first { $0 is NSTableView } ?? view
        guard let hit = window.contentView?.superview?.hitTest(location),
              hit === taker || hit.isDescendant(of: taker) else { return nil }
        return (hit, location)
    }

    @Test func `a term being typed is completed where it is, its field's values or a field`() {
        let term = FilterTerm("rating>=3 -camera:\"X-T", cursor: 22)
        #expect(term?.range == 10 ..< 22 && term?.negated == true && term?.field == .camera && term?.value == "X-T")
        #expect(FilterTerm("sunset kw:bir", cursor: 13)?.field == .keyword)
        #expect(FilterTerm("rating>=3", cursor: 9) == nil, "a comparison isn't completed")
        #expect(FilterTerm("sunset ", cursor: 7) == nil)
        #expect(FilterTerm.fields(startingWith: "ra").map(\.text) == ["rating:"])
        let completion = FilterCompletion(QueryCompletion(field: .camera, value: "Fujifilm X-T5")).negated(true)
        let (text, cursor) = FilterTerm.inserting(completion, in: "rating>=3 -camera:\"X-T", at: 10 ..< 22)
        #expect(text == "rating>=3 -camera:\"Fujifilm X-T5\" " && cursor == text.count)
    }

    @Test(.measuresSpeed)
    func `typing never waits on the engine on the main thread`() async throws {
        defer { cleanUp() }
        let (model, _) = try await open()
        let filters = try #require(model.libraryFilters)
        var typed = ""
        var slowest = Duration.zero
        let clock = ContinuousClock()
        for character in "camera:\"Canon EOS R5\" rating>=4 -flag:reject" {
            typed.append(character)
            let started = clock.now
            filters.setText(typed)
            slowest = max(slowest, clock.now - started)
        }
        #expect(slowest < .milliseconds(4), "a key's work on the main thread: \(slowest)")
    }

    @Test func `a filter typed a key at a time lists once the main thread turns, and the latest one wins`(
    ) async throws {
        defer { cleanUp() }
        let (model, _) = try await open()
        let filters = try #require(model.libraryFilters)
        var typed = ""
        for character in "camera:\"Canon EOS R5\" rating>=4 -flag:reject" {
            typed.append(character)
            filters.setText(typed)
        }
        #expect(model.items.count == 5, "the list follows once the main thread turns")
        try await eventually {
            filters.lastListed?.query?.description == "camera:\"Canon EOS R5\" rating>=4 -flag:reject"
        }
        #expect(names(model) == ["DSC_0005.JPG"])
    }

    @Test func `a key that finds the photos the last one found changes nothing shown`() async throws {
        defer { cleanUp() }
        let (model, _) = try await open()
        try await filtered(model, "IMG_0")
        let shown = model.items
        try #require(shown.count == 4)
        var changes = 0
        let observation = model.library.observe { _ in changes += 1 }
        defer { observation.invalidate() }
        try await filtered(model, "IMG_00")
        #expect(model.items == shown)
        #expect(changes == 0, "the same photos in the same order: nothing to change")
        try await filtered(model, "IMG_000")
        try await filtered(model, "IMG_0001")
        #expect(names(model) == ["IMG_0001.JPG"] && changes == 1)
    }

    @Test func `every photo a filter shows has its content key, as the filter narrows and widens`() async throws {
        defer { cleanUp() }
        let (model, _) = try await open()
        let library = model.library
        let keys = Dictionary(uniqueKeysWithValues: library.items.compactMap { item in
            library.storeThumbnail(for: item).map { (item.url, $0.1) }
        })
        try #require(keys.count == library.items.count, "each photo has a key before any filter")
        for text in ["IMG_0", "DSC", "IMG_0001", ""] {
            try await filtered(model, text)
            #expect(!library.items.isEmpty, "\(text)")
            #expect(library.items.allSatisfy { library.storeThumbnail(for: $0)?.1 == keys[$0.url] }, "\(text)")
        }
    }

    @Test func `the selection keeps the photos that remain as the filter changes`() async throws {
        defer { cleanUp() }
        let (model, _) = try await open()
        let first = try #require(model.items.first { $0.name == "IMG_0001.JPG" }?.url)
        let second = try #require(model.items.first { $0.name == "IMG_0002.JPG" }?.url)
        let third = try #require(model.items.first { $0.name == "IMG_0003.JPG" }?.url)
        model.select(first)
        model.click(second, toggling: true)
        model.click(third, toggling: true)
        #expect(Set(model.selectedPhotos) == [first, second, third])
        try await filtered(model, "camera:X-T5")
        #expect(Set(model.selectedPhotos) == [first, second], "the X-T5's photos stay selected")
        #expect(model.photoSelection.active.flatMap(model.library.url(ofPhoto:)) != nil)
        try await filtered(model, "camera:X-T5 rating:5")
        #expect(model.selectedPhotos == [first] && model.selection == first)
        try await filtered(model, "camera:\"EOS R5\"")
        #expect(model.items.count == 2)
        #expect(
            model.selection.map { url in model.items.contains { $0.url == url } } == true,
            "a photo found is active",
        )
        try await filtered(model, "")
        #expect(model.items.count == 5)
    }

    @Test func `changes made while the main thread is busy reach it as one, filtered or not`() async throws {
        defer { cleanUp() }
        let (model, service) = try await open()
        let library = model.library
        let core = try #require(service.core)
        var changes = 0
        let observation = library.observe { _ in changes += 1 }
        defer { observation.invalidate() }
        for (round, text) in ["", "IMG"].enumerated() {
            if !text.isEmpty {
                try await filtered(model, text)
            }
            let urls = library.items.map(\.url)
            let stores = urls.map { library.sidecars.store(for: $0) }
            let ratings = urls.indices.map { 1 + ($0 + round + 1) % 5 }
            changes = 0
            let written = DispatchSemaphore(value: 0)
            Task.detached {
                // Each photo rated twice, each in its own write, further apart than LibraryLive gathers changes.
                for wave in [ratings.map { 6 - $0 }, ratings] {
                    for (place, url) in urls.enumerated() {
                        let metadata = PhotoMetadata(rating: wave[place])
                        try? stores[place].save(Sidecar(recipe: EditRecipe(), metadata: metadata), for: url)
                        core.sidecarSaved(url, store: stores[place])
                        try? await Task.sleep(for: .milliseconds(150))
                    }
                }
                written.signal()
            }
            Self.hold(until: written, then: 2)
            try await eventually { library.items.map(\.metadata.rating) == ratings }
            #expect(library.items.map(\.metadata.rating) == ratings)
            #expect(changes <= 3, "\(changes) changes for \(2 * urls.count) writes made while the main thread was busy")
        }
    }

    /// Keeps the main thread busy until `done` is signalled, and for `seconds` after.
    private static func hold(until done: DispatchSemaphore, then seconds: Double) {
        _ = done.wait(timeout: .now() + 60)
        Thread.sleep(forTimeInterval: seconds)
    }
}
