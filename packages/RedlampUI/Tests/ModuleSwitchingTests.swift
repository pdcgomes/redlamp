import AppKit
import Foundation
import RedlampDocument
import RedlampEngineAPI
import Testing
@_spi(Harness) @testable import RedlampUI

/// Library and Develop as modules of one window (LIB-13, DEC-42): keys, menu items and the picker switch
/// them; the source, the selection, the active photo and the filmstrip's place carry across; each module's
/// views are built once; a switch opens, lists and decodes nothing.
@MainActor
struct ModuleSwitchingTests {
    @Test func `the modules' keys are Lightroom Classic's G, E, C, N, D, ⌥⌘1, ⌥⌘2 and ⌥⌘↑, and D stays the Edit tool`() {
        let keys: [(KeyCombo, ShortcutAction)] = [
            (.char("g"), .gridView), (.char("e"), .loupeView), (.char("c"), .compareView), (.char("n"), .surveyView),
            (.char("d"), .editTool), (.char("1", option: true, command: true), .libraryModule),
            (.char("2", option: true, command: true), .developModule),
            (KeyCombo(.up, option: true, command: true), .previousModule),
        ]
        for (combo, action) in keys {
            #expect(ShortcutAction.resolve(combo)?.action == action, "\(combo.display) isn't \(action.title)")
        }
        for action in [ShortcutAction.libraryModule, .developModule, .previousModule] {
            #expect(action.isMenuShortcut && action.combos.first?.keyboardShortcut != nil, "\(action) has no item key")
        }
        #expect(ShortcutAction.compareView.title.contains("Loupe for Now"))
        #expect(ShortcutAction.surveyView.title.contains("Loupe for Now"))
        #expect(ShortcutAction.allCases.filter { $0.category == .modules }.count == 7)
    }

    @Test func `each module action switches modules, as its key and menu item run it`() async throws {
        let fixture = ModuleFixture()
        defer { fixture.cleanUp() }
        try await fixture.open(count: 5)
        let model = fixture.model
        #expect(model.module == .develop && model.previousModule == nil)
        #expect(!model.canPerform(.previousModule))

        #expect(model.perform(.gridView))
        #expect(model.module == .library && model.libraryView == .grid)
        #expect(model.perform(.loupeView))
        #expect(model.libraryView == .loupe)
        #expect(model.perform(.gridView) && model.libraryView == .grid)
        for action in [ShortcutAction.compareView, .surveyView] {
            #expect(model.perform(action))
            #expect(model.libraryView == .loupe, "\(action.title) shows the loupe until LIB-16")
            #expect(model.perform(.cancel) && model.libraryView == .grid, "Esc goes back to the grid")
        }
        model.activeTool = .crop
        #expect(model.perform(.editTool))
        #expect(model.module == .develop && model.activeTool == .edit, "D opens Develop on the Edit tool")
        #expect(model.perform(.libraryModule) && model.module == .library)
        #expect(model.perform(.developModule) && model.module == .develop)
        #expect(model.canPerform(.previousModule))
        #expect(model.perform(.previousModule) && model.module == .library)
        #expect(model.perform(.previousModule) && model.module == .develop)
        #expect(model.perform(.cropTool) && model.activeTool == .crop, "R in Develop is still the Crop tool")
        model.showModule(.library)
        #expect(model.perform(.healTool))
        #expect(model.module == .develop && model.activeTool == .heal, "Q in Library opens Develop's Healing tool")
    }

    @Test func `the Library module leaves Develop's canvas, tools and edit alone`() async throws {
        let fixture = ModuleFixture()
        defer { fixture.cleanUp() }
        try await fixture.open(count: 3)
        let model = fixture.model
        model.focusedParameter = .exposure
        model.showModule(.library)
        for action in [ShortcutAction.increaseSetting, .toggleZoom, .beforeAfter, .undo, .resetAll, .linearMask] {
            #expect(!model.canPerform(action), "\(action.title) is available in Library")
            #expect(!model.perform(action), "\(action.title) ran in Library")
        }
        #expect(model.value(.exposure) == 0 && !model.showBefore)
        #expect(model.perform(.rating3) && model.photoMetadata.rating == 3, "ratings reach the active photo")
        #expect(model.canPerform(.selectAllPhotos) && model.canPerform(.toggleFilmstrip))
    }

    @Test func `the toolbar's picker switches modules and shows the one shown`() async throws {
        let fixture = ModuleFixture()
        defer { fixture.cleanUp() }
        try await fixture.open(count: 2)
        let model = fixture.model
        let picker = ModulePickerView(model: model)
        let window = NSWindow(
            contentRect: CGRect(x: 0, y: 0, width: 300, height: 40), styleMask: [.titled], backing: .buffered,
            defer: false,
        )
        window.contentView = picker
        picker.frame = CGRect(origin: .zero, size: picker.intrinsicContentSize)
        picker.layoutSubtreeIfNeeded()
        defer { window.contentView = nil }
        func click(_ module: AppModule) throws {
            let button = try #require(picker.subviews
                .first { $0.accessibilityIdentifier() == "module.\(module.rawValue)" })
            let point = picker.convert(CGPoint(x: button.frame.midX, y: button.frame.midY), to: nil)
            let event = try #require(NSEvent.mouseEvent(
                with: .leftMouseDown, location: point, modifierFlags: [], timestamp: 0,
                windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1,
            ))
            #expect(window.contentView?.superview?.hitTest(point) === picker, "the picker takes the click itself")
            picker.mouseDown(with: event)
        }
        try click(.library)
        #expect(model.module == .library)
        try await fixture.settle()
        let library = try #require(picker.subviews.first { $0.accessibilityIdentifier() == "module.library" })
        #expect(library.accessibilityValue() as? String == "shown")
        try click(.develop)
        #expect(model.module == .develop)
        #expect(model.activity.events.contains { $0.kind == .action && $0.text == "Library" })
    }

    @Test func `the source, the selection and the active photo carry across, and Develop keeps its photo open`()
        async throws {
        let fixture = ModuleFixture()
        defer { fixture.cleanUp() }
        try await fixture.open(count: 6)
        let model = fixture.model
        model.click(fixture.photos[2])
        try await fixture.eventually { model.info?.url == fixture.photos[2] }
        model.click(fixture.photos[4], extending: true)
        try await fixture.eventually { model.info?.url == fixture.photos[4] }
        let opened = fixture.engine.opened.withLock { $0.count }
        let before = (model.folder, model.selectedPhotos, model.selection, model.items.map(\.url), model.info?.url)

        model.showModule(.library)
        #expect(model.folder == before.0 && model.selectedPhotos == before.1 && model.selection == before.2)
        #expect(model.items.map(\.url) == before.3)
        #expect(model.info?.url == before.4, "Develop keeps the photo open while Library is shown")
        model.showModule(.develop)
        #expect(model.folder == before.0 && model.selectedPhotos == before.1 && model.selection == before.2)
        #expect(model.info?.url == before.4)
        #expect(fixture.engine.opened.withLock { $0.count } == opened, "the open photo wasn't opened again")
    }

    @Test func `the subfolder setting and the photos' order carry across`() async throws {
        let fixture = ModuleFixture()
        defer { fixture.cleanUp() }
        try await fixture.open(count: 3, subfolder: 2)
        let model = fixture.model
        model.showModule(.library)
        model.setIncludesSubfolders(true)
        try await fixture.eventually { model.items.count == 5 }
        let order = model.items.map(\.url)
        model.showModule(.develop)
        #expect(model.library.includesSubfolders && model.items.map(\.url) == order)
        model.showModule(.library)
        #expect(model.items.map(\.url) == order)
    }

    @Test func `returning to Develop opens the photo Library made active, from its thumbnail until its render lands`()
        async throws {
        let fixture = ModuleFixture()
        defer { fixture.cleanUp() }
        try await fixture.open(count: 4)
        let model = fixture.model
        let target = fixture.photos[3]
        _ = try await model.thumbnailLoader.image(for: #require(model.library.item(for: target)))
        model.showModule(.library)
        let opened = fixture.engine.opened.withLock { $0.count }
        model.click(target)
        #expect(model.selection == target && model.info == nil && !model.isLoading)
        #expect(fixture.engine.opened.withLock { $0.count } == opened, "Library doesn't open the photo")
        model.showModule(.develop)
        #expect(model.selectionThumbnail != nil, "Develop shows the photo at once")
        try await fixture.eventually { model.info?.url == target }
        #expect(model.info?.url == target)
        #expect(fixture.engine.opened.withLock { $0.last } == target)
    }

    @Test func `each module's views are built once, and a switch rebuilds and reloads nothing`() async throws {
        let fixture = ModuleFixture()
        defer { fixture.cleanUp() }
        try await fixture.open(count: 40)
        let model = fixture.model
        let modules = fixture.showModules()
        let built = modules.identities
        #expect(modules.content.library.alphaValue == 0 && !modules.grid.isInShownModule(model))
        #expect(modules.grid.reloads == 0, "the grid waits until Library is first shown")
        for index in 0 ..< 20 {
            model.showModule(index.isMultiple(of: 2) ? .library : .develop)
            try await fixture.settle()
            let library = model.module == .library
            #expect(modules.content.library.alphaValue == (library ? 1 : 0) && !modules.content.developView.isHidden)
            #expect(
                modules.grid.isInShownModule(model) == library,
                "Library's parts follow nothing while Develop is shown",
            )
            let middle = CGPoint(x: 800, y: 450)
            let hit = modules.content.view.hitTest(middle)
            let target = library ? modules.content.library : modules.content.developView
            #expect(hit.map { $0 === modules.content.view || $0.isDescendant(of: target) } == true)
            for column in [modules.left, modules.right] {
                let shown = library ? column.library : column.develop
                let other = library ? column.develop : column.library
                #expect(column.shown == model.module && shown.alphaValue == 1 && other.alphaValue == 0)
                let point = CGPoint(x: column.frame.midX, y: column.frame.minY + 60)
                let hit = column.hitTest(point)
                #expect(
                    hit.map { $0 === column || $0.isDescendant(of: shown) } == true,
                    "a click reaches the other module",
                )
                #expect(column.accessibilityChildren()?.count == 1)
            }
        }
        #expect(modules.identities == built, "a view was built again")
        #expect(modules.grid.reloads == 1, "the grid loaded once, when first shown")
        model.showModule(.library)
        try await fixture.settle()
        #expect(modules.window.firstResponder === modules.grid.content, "the grid takes the keyboard")
        model.showModule(.develop)
        try await fixture.settle()
        #expect(modules.window.firstResponder === modules.content.view, "Develop gives it back")
    }

    @Test func `a switch opens, lists, reads and decodes nothing`() async throws {
        let fixture = ModuleFixture()
        defer { fixture.cleanUp() }
        try await fixture.open(count: 60)
        let model = fixture.model
        let modules = fixture.showModules()
        model.showModule(.library)
        try await fixture.settle()
        model.showModule(.develop)
        try await fixture.eventually { model.thumbnailLoader.cachedCount >= 40 }
        try await fixture.settle()
        let decoded = fixture.decoded.value
        let opened = fixture.engine.opened.withLock { $0.count }
        let revision = model.library.revision
        for index in 0 ..< 200 {
            model.showModule(index.isMultiple(of: 2) ? .library : .develop)
            if index.isMultiple(of: 25) {
                try await fixture.settle()
            }
        }
        try await fixture.settle()
        #expect(fixture.engine.opened.withLock { $0.count } == opened, "a switch opened a photo")
        #expect(fixture.decoded.value == decoded, "a switch decoded a thumbnail")
        #expect(model.library.revision == revision && !model.library.isListing, "a switch listed the folder")
        #expect(model.previews.cached(fixture.photos[0]) == nil, "a switch decoded a preview")
        #expect(modules.grid.reloads == 1)
    }

    @Test func `the filmstrip goes back to its place in the other module`() async throws {
        let fixture = ModuleFixture()
        defer { fixture.cleanUp() }
        try await fixture.open(count: 300)
        let model = fixture.model
        func strip() -> (FilmstripStripView, NSWindow) {
            let window = NSWindow(
                contentRect: CGRect(x: 0, y: 0, width: 900, height: FilmstripStripView.height), styleMask: [.titled],
                backing: .buffered, defer: false,
            )
            let strip = FilmstripStripView(model: model)
            window.contentView = strip
            strip.layoutSubtreeIfNeeded()
            strip.collectionView.layoutSubtreeIfNeeded()
            return (strip, window)
        }
        let (develop, first) = strip()
        defer { first.contentView = nil }
        FilmstripViews.scroll(develop, to: 0.6)
        try await fixture.settle()
        let place = try #require(model.filmstripPlace)
        #expect(place != model.selection, "the strip was scrolled away from the active photo")
        let (library, second) = strip()
        defer { second.contentView = nil }
        let clip = library.scrollView.contentView
        let middle = library.collectionView.indexPathForItem(at: CGPoint(x: clip.bounds.midX, y: 40))?.item
        #expect(middle.map { model.items[$0].url } == place, "the other module's filmstrip isn't at the same place")
    }
}
