import Foundation
import RedlampEngineAPI

/// Opening and closing the command palette, and the previews it shows.
public extension EditorModel {
    /// The command palette (⌘K), while it's open.
    @_spi(Harness) var commandPalette: CommandPaletteModel? {
        presentedPalette
    }

    /// Opens the palette, on everything or only sliders. The app binds ⌘K and ⌘F to this;
    /// the harness calls it directly.
    @_spi(Harness) func openCommandPalette(scope: PaletteScope = .all) {
        presentedPalette?.finish()
        let palette = CommandPaletteModel(editor: self, scope: scope, tip: PaletteTips.next())
        presentedPalette = palette
        palette.report(.opened(scope))
    }

    @_spi(Harness) func closeCommandPalette(_ reason: PaletteCloseReason = .escape) {
        guard let palette = presentedPalette else { return }
        palette.finish()
        presentedPalette = nil
        palette.report(.closed(reason))
    }

    /// ⌘K: opens the palette, or closes it from any level.
    @_spi(Harness) func toggleCommandPalette(scope: PaletteScope = .all) {
        if commandPalette == nil {
            openCommandPalette(scope: scope)
        } else {
            closeCommandPalette(.toggle)
        }
    }

    /// Renders `edit` in place of the photo's edit without applying it; `nil` stops.
    func preview(_ edit: EditRecipe?) {
        guard previewingEdit != edit else { return }
        previewingEdit = edit
        if edit != nil {
            previewingRecipe = nil
        }
        requestRender()
    }

    /// The edit with `mode`'s white balance, for previewing it.
    func edit(withWhiteBalance mode: WhiteBalanceMode) async -> EditRecipe? {
        if mode == .auto, autoWhiteBalance == nil {
            let visit = currentVisit
            let wb = await engine.autoWhiteBalance()
            guard visit != nil, currentVisit == visit else { return nil }
            autoWhiteBalance = wb
        }
        guard let wb = resolveWhiteBalance(mode) else { return nil }
        var edit = recipe
        edit.whiteBalanceMode = mode
        edit[.temperature] = ParameterID.temperature.spec.quantize(wb.temperature)
        edit[.tint] = ParameterID.tint.spec.quantize(wb.tint)
        return edit
    }
}
