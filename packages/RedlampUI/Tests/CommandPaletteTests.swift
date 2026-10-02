import Foundation
import RedlampDesign
import RedlampEngineAPI
import Testing
@_spi(Harness) @testable import RedlampUI

/// The command palette (UX-07): search, actions and the slider bar, driven through the
/// same calls its keys make.
@MainActor
struct CommandPaletteTests: PaletteTesting {
    // MARK: - Search and actions

    @Test func `every listed action appears once`() async throws {
        let (model, _, cleanup) = try await openEditor()
        defer { cleanup() }
        model.openCommandPalette()
        let rows = try palette(model).rows
        for action in ShortcutAction.allCases where !PaletteCatalog.keyOnlyActions.contains(action) {
            #expect(rows.count(where: { $0.kind == .action(action) }) == 1, "\(action)")
        }
        for action in PaletteCatalog.keyOnlyActions {
            #expect(!rows.contains { $0.kind == .action(action) }, "\(action) only makes sense as a key")
        }
    }

    @Test func `search ranks the slider people mean first`() async throws {
        let (model, _, cleanup) = try await openEditor()
        defer { cleanup() }
        model.openCommandPalette()
        let palette = try palette(model)
        palette.setText("exp")
        #expect(palette.rows.first?.kind == .slider(.exposure))
        palette.setText("b&w")
        #expect(palette.rows.prefix(3).contains { $0.kind == .action(.toggleBlackAndWhite) })
        palette.setText("haze")
        #expect(palette.rows.first?.kind == .slider(.dehaze))
        palette.setText("orange saturation")
        #expect(palette.rows.first?.title == "Orange Saturation")
    }

    @Test func `pressing Esc at the top level closes the palette`() async throws {
        let (model, events, cleanup) = try await openEditor()
        defer { cleanup() }
        model.openCommandPalette()
        try palette(model).handle(.escape)
        #expect(model.commandPalette == nil)
        #expect(events.all == [.opened(.all), .closed(.escape)])
    }

    @Test func `running an action closes the palette and performs it`() async throws {
        let (model, events, cleanup) = try await openEditor()
        defer { cleanup() }
        _ = try open("convert to black", in: model)
        #expect(model.commandPalette == nil)
        #expect(model.treatment == .blackAndWhite)
        #expect(events.all.contains(.ran(.toggleBlackAndWhite)))
    }

    @Test func `actions that can't run are dimmed, like Paste Settings before a copy`() async throws {
        let (model, events, cleanup) = try await openEditor()
        defer { cleanup() }
        model.openCommandPalette()
        let palette = try palette(model)
        palette.setText("paste settings")
        let paste = try #require(palette.rows.first { $0.kind == .action(.pasteSettings) })
        #expect(!palette.isEnabled(paste))
        palette.activate(paste)
        #expect(events.all.last == .unavailable(.action(.pasteSettings)))
        #expect(model.commandPalette != nil)
        model.copySettings()
        #expect(palette.isEnabled(paste))
    }

    @Test func `the first hint names what Return does`() async throws {
        let (model, _, cleanup) = try await openEditor()
        defer { cleanup() }
        model.openCommandPalette()
        let palette = try palette(model)
        palette.setText("exposure")
        #expect(palette.hints == [PaletteHint("Adjust", ["↵"]), PaletteHint("Close", ["Esc"])])
        palette.setText("auto settings")
        #expect(palette.hints.first == PaletteHint("Run", ["↵"]))
    }

    @Test func `each opening shows the next tip, starting again after the last`() throws {
        let defaults = try #require(UserDefaults(suiteName: "CommandPaletteTests-\(UUID().uuidString)"))
        let tips = (0 ..< PaletteTips.all.count + 1).map { _ in PaletteTips.next(defaults) }
        #expect(tips == Array(PaletteTips.all.indices) + [0])
    }

    @Test func `⌘F searches sliders only, and ⌫ on the empty field searches everything`() async throws {
        let (model, events, cleanup) = try await openEditor()
        defer { cleanup() }
        model.openCommandPalette(scope: .sliders)
        let palette = try palette(model)
        #expect(palette.rows.allSatisfy {
            if case .slider = $0.kind {
                true
            } else {
                false
            }
        })
        #expect(palette.handle(.deleteBackward))
        #expect(palette.scope == .all)
        #expect(events.all.contains(.scopeRemoved))
        #expect(!palette.handle(.deleteBackward), "with everything searched, ⌫ is the field's")
    }

    @Test func `⌘K and ⌘F open and close the palette`() async throws {
        let (model, events, cleanup) = try await openEditor()
        defer { cleanup() }
        #expect(model.perform(.commandPalette))
        #expect(model.commandPalette?.scope == .all)
        model.perform(.findAdjustment)
        #expect(model.commandPalette?.scope == .sliders, "⌘F over the palette narrows it to sliders")
        model.perform(.findAdjustment)
        #expect(model.commandPalette == nil)
        model.perform(.findAdjustment)
        #expect(model.commandPalette?.scope == .sliders)
        model.perform(.commandPalette)
        #expect(model.commandPalette == nil)
        #expect(events.all.last == .closed(.toggle))
        #expect(ShortcutAction.resolve(.char("k", command: true))?.action == .commandPalette)
    }

    // MARK: - The slider bar

    @Test func `presses close together make one history step`() async throws {
        let (model, _, cleanup) = try await openEditor()
        defer { cleanup() }
        let palette = try open("exposure", in: model)
        #expect(palette.sliderParameter == .exposure)
        #expect(model.focusedParameter == .exposure)
        let steps = model.history.count
        for _ in 0 ..< 3 {
            palette.handle(.right([]))
        }
        #expect(palette.hasOpenStep)
        palette.handle(.escape)
        #expect(model.history.count == steps + 1)
        #expect(model.history.last?.name == "Exposure: 0.00 → +0.15")
    }

    @Test func `shift steps ten times further and stops at the slider's range`() async throws {
        let (model, _, cleanup) = try await openEditor()
        defer { cleanup() }
        let palette = try open("exposure", in: model)
        palette.handle(.right(.shift))
        #expect(model.value(.exposure) == 0.5)
        palette.handle(.right(.option))
        #expect(model.value(.exposure) == 0.51)
        for _ in 0 ..< 20 {
            palette.handle(.right(.shift))
        }
        #expect(model.value(.exposure) == 5)
    }

    @Test func `up and down follow the panel's order and skip sliders this photo can't use`() async throws {
        let (model, events, cleanup) = try await openEditor()
        defer { cleanup() }
        let palette = try open("exposure", in: model)
        // The stub photo has no white balance, so Temp and Tint are skipped.
        #expect(palette.neighbours(of: .exposure) == (nil, .contrast))
        palette.handle(.down)
        #expect(palette.sliderParameter == .contrast)
        #expect(model.focusedParameter == .contrast)
        palette.handle(.up)
        palette.handle(.up)
        #expect(palette.sliderParameter == .exposure)
        #expect(events.all.contains(.steppedSlider(.contrast)))
    }

    @Test func `typed values set the slider, and x is the current value`() async throws {
        let (model, events, cleanup) = try await openEditor()
        defer { cleanup() }
        let palette = try open("exposure", in: model)
        palette.setText("0.2")
        palette.handle(.submit)
        #expect(model.value(.exposure) == 0.2)
        palette.setText("x+0.3")
        palette.handle(.submit)
        #expect(model.value(.exposure) == 0.5)
        #expect(model.history.last?.name == "Exposure: +0.20 → +0.50")
        palette.setText("1..2")
        palette.handle(.submit)
        #expect(palette.typedIsInvalid)
        #expect(events.all.last == .invalidValue("1..2"))
        #expect(model.value(.exposure) == 0.5)
    }

    @Test func `a letter returns to the search with that letter typed`() async throws {
        let (model, events, cleanup) = try await openEditor()
        defer { cleanup() }
        let palette = try open("exposure", in: model)
        palette.setText("c")
        #expect(palette.sliderParameter == nil)
        #expect(palette.text == "c")
        #expect(events.all.last?.isHighlightOrSearch == true)
        #expect(events.all.contains(.searchedFromSlider("c")))
    }

    @Test func `delete on the empty value goes back with the search restored`() async throws {
        let (model, events, cleanup) = try await openEditor()
        defer { cleanup() }
        let palette = try open("exposure", in: model)
        palette.handle(.deleteBackward)
        #expect(palette.sliderParameter == nil)
        #expect(palette.text == "exposure")
        #expect(palette.selectsTextOnRevision)
        #expect(events.all.contains(.wentBack(.delete)))
    }

    @Test func `⌘Z straight after a burst undoes the whole burst`() async throws {
        let (model, _, cleanup) = try await openEditor()
        defer { cleanup() }
        let palette = try open("exposure", in: model)
        for _ in 0 ..< 3 {
            palette.handle(.right([]))
        }
        model.undo()
        #expect(model.value(.exposure) == 0)
        #expect(!palette.hasOpenStep)
        model.redo()
        #expect(model.value(.exposure) == 0.15)
    }

    @Test func `undo is on during a burst, even before the photo has any history`() async throws {
        let (model, _, cleanup) = try await openEditor()
        defer { cleanup() }
        let palette = try open("exposure", in: model)
        #expect(!model.canPerform(.undo))
        palette.handle(.right([]))
        #expect(model.canPerform(.undo))
    }

    @Test func `command-delete resets the slider, and return with nothing typed closes`() async throws {
        let (model, events, cleanup) = try await openEditor()
        defer { cleanup() }
        let palette = try open("contrast", in: model)
        palette.handle(.right(.shift))
        #expect(model.value(.contrast) == 10)
        palette.handle(.reset)
        #expect(model.value(.contrast) == 0)
        #expect(events.all.contains(.reset(.contrast)))
        palette.handle(.submit)
        #expect(model.commandPalette == nil)
        #expect(events.all.last == .closed(.done))
    }

    @Test func `the bar's hints follow what's typed and held`() async throws {
        let (model, _, cleanup) = try await openEditor()
        defer { cleanup() }
        let palette = try open("exposure", in: model)
        #expect(palette.hints.map(\.title) == ["×10", "Fine", "Reset", "Done", "Back"])
        palette.setText("1")
        #expect(palette.hints.map(\.title).contains("Set"))
        palette.heldModifiers = .shift
        #expect(palette.hints.first == PaletteHint("×10", ["⇧"], isActive: true))
    }
}
