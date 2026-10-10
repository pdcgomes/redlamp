import Foundation
import RedlampDesign
import RedlampEngineAPI
import Testing
@_spi(Harness) @testable import RedlampUI

/// The palette's commands run last, its actions on the selection, and what else a row can do on ⌘↵ (LIB-19), each
/// test with recents of its own.
@MainActor
struct CommandPaletteSelectionTests: PaletteTesting {
    private func withRecents(_ body: (PaletteRecents) async throws -> Void) async throws {
        let recents = PaletteRecents(defaults: nil)
        try await PaletteRecents.$override.withValue(recents) { try await body(recents) }
    }

    private func duplicates(_ palette: CommandPaletteModel) -> [PaletteItemKind] {
        Dictionary(grouping: palette.rows, by: \.kind).filter { $0.value.count > 1 }.map(\.key)
    }

    // MARK: - Recent commands

    @Test func `the commands run last are listed first while the field is empty, the latest first`() async throws {
        try await withRecents { _ in
            let (model, _, cleanup) = try await openEditor()
            defer { cleanup() }
            _ = try open("show clipping", in: model)
            _ = try open("cycle info overlay", in: model)
            model.openCommandPalette()
            var palette = try palette(model)
            #expect(palette.sections.first?.title == "Recent")
            #expect(palette.sections.first?.items.map(\.kind) == [.action(.infoOverlay), .action(.clipping)])
            #expect(duplicates(palette).isEmpty, "a recent command isn't listed again in its category")
            model.closeCommandPalette()

            _ = try open("exposure", in: model)
            #expect(try self.palette(model).sliderParameter == .exposure)
            model.closeCommandPalette()
            model.openCommandPalette()
            palette = try self.palette(model)
            #expect(palette.sections.first?.items.first?.kind == .slider(.exposure))
            #expect(duplicates(palette).isEmpty)
            palette.setText("clipping")
            #expect(palette.sections.first?.title == nil, "searching ranks every row as before")
        }
    }

    @Test func `the recents keep six commands, and pass over what this version doesn't know`() throws {
        let suite = "palette-recents-tests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(
            ["action:flagPick", "slider:someLaterSlider", "page:whiteBalance", "bogus"],
            forKey: "app.redlamp.paletteRecents",
        )
        let recents = PaletteRecents(defaults: defaults)
        #expect(recents.kinds == [.action(.flagPick), .page(.whiteBalance)])
        recents.record(.treatment(.blackAndWhite))
        #expect(recents.kinds.count == 2, "a choice isn't a command")
        let actions: [ShortcutAction] = [.rating1, .rating2, .rating3, .rating4, .rating5, .unflag, .flagPick]
        actions.forEach { recents.record(.action($0)) }
        #expect(recents.kinds == [.flagPick, .unflag, .rating5, .rating4, .rating3, .rating2]
            .map(PaletteItemKind.action))
        #expect(PaletteRecents(defaults: defaults).kinds == recents.kinds, "kept in the app's defaults")
    }

    @Test func `the app's recents keep nothing while tests run`() {
        PaletteRecents.shared.record(.action(.flagPick))
        #expect(PaletteRecents.shared.kinds.isEmpty)
    }

    // MARK: - The selection

    @Test func `what the menus can do to the selection comes first, with its keys, and runs as they do`() async throws {
        try await withRecents { _ in
            let (model, events, cleanup) = try await openEditor()
            defer { cleanup() }
            model.openCommandPalette()
            let palette = try palette(model)
            let selection = try #require(palette.sections.first)
            #expect(selection.title == "Selection · IMG_0001.ARW")
            let kinds = selection.items.map(\.kind)
            for action in [ShortcutAction.rating3, .flagPick, .labelRed, .rotateLeft, .showInFinder] {
                #expect(kinds.contains(.action(action)), "\(action)")
            }
            #expect(!kinds.contains(.action(.stackPhotos)), "a stack takes more than one photo")
            #expect(duplicates(palette).isEmpty)
            let rotate = try #require(selection.items.first { $0.kind == .action(.rotateRight) })
            palette.select(rotate)
            palette.activate(rotate)
            #expect(events.all.contains(.ran(.rotateRight)))
            #expect(model.commandPalette == nil)
            #expect(model.recipe.orientation != EditRecipe().orientation)
        }
    }

    // MARK: - What else a row can do

    @Test func `⌘↵ on a slider lists what ↵ does and Reset, which puts the slider back`() async throws {
        try await withRecents { _ in
            let (model, _, cleanup) = try await openEditor()
            defer { cleanup() }
            model.setSliderValue(.exposure, 1)
            model.openCommandPalette()
            let palette = try palette(model)
            palette.setText("exposure")
            #expect(palette.selectedItem?.kind == .slider(.exposure))
            #expect(palette.hints.contains(PaletteHint("Actions", ["⌘", "↵"])))
            palette.handle(.rowActions)
            #expect(palette.page == .actions)
            #expect(palette.subject?.kind == .slider(.exposure))
            #expect(palette.rows.map(\.kind) == [.rowAction(.primary), .rowAction(.resetSlider)])
            #expect(palette.rows.first?.title == "Adjust “Exposure”")
            palette.handle(.down)
            palette.handle(.submit)
            #expect(model.commandPalette == nil)
            #expect(model.sliderValue(.exposure) == 0)
        }
    }

    @Test func `Esc on the Actions page goes back to the row's list, and ↵ there does what the row's ↵ does`()
        async throws {
        try await withRecents { _ in
            let (model, events, cleanup) = try await openEditor()
            defer { cleanup() }
            model.openCommandPalette()
            let palette = try palette(model)
            palette.setText("exposure")
            palette.handle(.rowActions)
            palette.handle(.escape)
            #expect(palette.page == nil)
            #expect(palette.subject == nil)
            #expect(palette.text == "exposure")
            #expect(events.all.contains(.wentBack(.escape)))

            palette.handle(.rowActions)
            palette.handle(.submit)
            #expect(palette.sliderParameter == .exposure, "the slider bar, as ↵ on the row opens it")
        }
    }

    @Test func `⌘↵ on a row that can do nothing more stays where it is`() async throws {
        try await withRecents { _ in
            let (model, events, cleanup) = try await openEditor()
            defer { cleanup() }
            model.openCommandPalette()
            let palette = try palette(model)
            palette.setText("show clipping")
            #expect(palette.selectedItem?.kind == .action(.clipping))
            #expect(!palette.hints.contains(PaletteHint("Actions", ["⌘", "↵"])))
            palette.handle(.rowActions)
            #expect(palette.page == nil)
            #expect(events.all.contains(.unavailable(.action(.clipping))))
        }
    }
}
