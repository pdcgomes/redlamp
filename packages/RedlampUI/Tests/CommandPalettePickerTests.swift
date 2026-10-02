import Foundation
import RedlampDesign
import RedlampEngineAPI
import Testing
@_spi(Harness) @testable import RedlampUI

/// The command palette (UX-07): typed values, pickers and its own theme.
@MainActor
struct CommandPalettePickerTests: PaletteTesting {
    // MARK: - Typed values from search

    @Test func `a name and a value make a Set row`() async throws {
        let (model, _, cleanup) = try await openEditor()
        defer { cleanup() }
        model.openCommandPalette()
        let palette = try palette(model)
        palette.setText("exposure 0.7")
        #expect(palette.rows.first?.kind == .setValue(.exposure, 0.7))
        #expect(palette.rows.first?.title == "Set Exposure to +0.70")
        palette.setText("temp 5600k")
        #expect(palette.rows.first?.kind == .setValue(.temperature, 5600))
        palette.setText("contrast x+10")
        #expect(palette.rows.first?.kind == .setValue(.contrast, 10))
        palette.setText("shadows 20")
        let values = palette.rows.filter {
            if case .setValue = $0.kind {
                true
            } else {
                false
            }
        }
        #expect(values.first?.kind == .setValue(.shadows, 20))
        #expect(values.count > 1, "every slider the name matches as well gets a row")
        palette.setText("exposure abc")
        #expect(!palette.rows.contains {
            if case .setValue = $0.kind {
                true
            } else {
                false
            }
        })
    }

    @Test func `return on a Set row applies it and closes`() async throws {
        let (model, events, cleanup) = try await openEditor()
        defer { cleanup() }
        _ = try open("exposure 0.7", in: model)
        #expect(model.value(.exposure) == 0.7)
        #expect(model.commandPalette == nil)
        #expect(model.history.last?.name == "Exposure: 0.00 → +0.70")
        #expect(events.all.contains(.applied(.setValue(.exposure, 0.7))))
    }

    // MARK: - Pickers

    @Test func `highlighting a recipe previews it, and Esc clears the preview`() async throws {
        let (model, events, cleanup) = try await openEditor()
        defer { cleanup() }
        let palette = try open("recipes", in: model)
        #expect(palette.page == .recipes)
        #expect(palette.hints.first == PaletteHint("Preview", ["↑", "↓"]))
        palette.handle(.down)
        try await eventually { model.previewingRecipe != nil }
        #expect(model.previewingRecipe != nil)
        #expect(events.all.contains {
            if case .previewed(.recipe?) = $0 {
                true
            } else {
                false
            }
        })
        palette.handle(.escape)
        #expect(model.previewingRecipe == nil)
        #expect(palette.page == nil)
    }

    @Test func `return on a recipe applies it`() async throws {
        let (model, _, cleanup) = try await openEditor()
        defer { cleanup() }
        let palette = try open("recipes", in: model)
        let recipe = try #require(palette.selectedItem)
        palette.handle(.submit)
        try await eventually { model.history.last?.name.hasPrefix("Recipe: ") == true }
        #expect(model.history.last?.name == "Recipe: \(recipe.title)")
        #expect(model.commandPalette == nil)
        #expect(model.previewingRecipe == nil)
    }

    @Test func `return on a History step goes to that step`() async throws {
        let (model, _, cleanup) = try await openEditor()
        defer { cleanup() }
        model.setValue(.exposure, 0.5)
        model.setValue(.contrast, 20)
        let palette = try open("history", in: model)
        #expect(palette.page == .history)
        #expect(palette.rows.first?.kind == .historyStep(model.historyIndex))
        palette.handle(.down)
        try await eventually { model.previewingEdit != nil }
        #expect(model.previewingEdit?[.contrast] == 0)
        palette.handle(.submit)
        #expect(model.historyIndex == model.history.count - 2)
        #expect(model.value(.contrast) == 0)
        #expect(model.previewingEdit == nil)
    }

    @Test func `a treatment previews before it's applied`() async throws {
        let (model, _, cleanup) = try await openEditor()
        defer { cleanup() }
        let palette = try open("treatment", in: model)
        palette.handle(.down)
        try await eventually { model.previewingEdit != nil }
        #expect(model.previewingEdit?.treatment == .blackAndWhite)
        #expect(model.treatment == .color)
        palette.handle(.submit)
        #expect(model.treatment == .blackAndWhite)
    }

    @Test func `the top-level search reaches inside the pickers`() async throws {
        let (model, _, cleanup) = try await openEditor()
        defer { cleanup() }
        model.openCommandPalette()
        let palette = try palette(model)
        palette.setText("portra")
        #expect(palette.rows.contains { row in
            switch row.kind {
            case .baseLook, .recipe: row.title.contains("Portra")
            default: false
            }
        })
        palette.setText("side by side")
        #expect(palette.rows.contains { $0.kind == .compareLayout(.sideBySide) })
    }

    @Test func `every list's rows are distinct`() async throws {
        let (model, _, cleanup) = try await openEditor()
        defer { cleanup() }
        model.openCommandPalette()
        let palette = try palette(model)
        func duplicates() -> [PaletteItemKind] {
            Dictionary(grouping: palette.rows, by: \.kind).filter { $0.value.count > 1 }.map(\.key)
        }
        #expect(duplicates().isEmpty, "browsing")
        for query in ["white", "portra", "b&w", "color", "mono", "film"] {
            palette.setText(query)
            #expect(duplicates().isEmpty, "searching “\(query)”")
        }
        for page in PalettePage.allCases {
            palette.setText(page.title.lowercased())
            guard palette.rows.first?.kind == .page(page) else { continue }
            palette.handle(.submit)
            #expect(palette.page == page)
            #expect(duplicates().isEmpty, "\(page.title)")
            palette.handle(.escape)
        }
    }

    // MARK: - Its own theme

    @Test func `the palette's own theme is kept, and clearing it follows the app's again`() throws {
        let suite = "CommandPaletteTests-theme-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = ThemeSettings(defaults: defaults)
        #expect(settings.paletteSelection == nil, "it follows the app's theme by default")
        settings.paletteSelection = ThemeSelection(familyID: "tokyo-night", appearance: .light, tint: 0.5)
        #expect(ThemeSettings(defaults: defaults).paletteSelection == settings.paletteSelection)
        settings.paletteSelection = nil
        #expect(ThemeSettings(defaults: defaults).paletteSelection == nil)
    }

    @Test func `the White Balance picker is hidden for photos without white balance`() async throws {
        let (model, _, cleanup) = try await openEditor()
        defer { cleanup() }
        model.openCommandPalette()
        let palette = try palette(model)
        #expect(!palette.rows.contains { $0.kind == .page(.whiteBalance) })
        #expect(palette.rows.contains { $0.kind == .page(.treatment) })
    }
}
