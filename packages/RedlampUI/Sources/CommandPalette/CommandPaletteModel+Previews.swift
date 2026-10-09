import AppKit
import Foundation
import RedlampEngineAPI
import RedlampLibrary
import RedlampRecipes

/// Choices previewing on the photo while highlighted, and applying them.
extension CommandPaletteModel {
    func highlightChanged() {
        previewTask?.cancel()
        guard !isSpecimen else { return }
        guard let item = selectedItem, item.kind.isChoice, Self.previews(item.kind) else {
            clearPreview()
            return
        }
        previewTask = Task { [weak self] in
            try? await Task.sleep(for: Self.previewDelay)
            guard !Task.isCancelled else { return }
            await self?.preview(item.kind)
        }
    }

    static func previews(_ kind: PaletteItemKind) -> Bool {
        switch kind {
        case .compareLayout, .filterPreset, .customLabel: false
        default: true
        }
    }

    func preview(_ kind: PaletteItemKind) async {
        switch kind {
        case let .baseLook(id):
            guard let look = editor.recipes.currentBaseLooks.first(where: { $0.id == id }) else { return }
            editor.preview(nil)
            editor.previewRecipe(BaseLookBrowser.previewRecipe(for: look))
        case let .recipe(id):
            guard let recipe = editor.recipes.recipe(id: id) else { return }
            editor.preview(nil)
            editor.previewRecipe(recipe)
        case let .whiteBalance(mode):
            guard let edit = await editor.edit(withWhiteBalance: mode), selectedItem?.kind == kind else { return }
            editor.preview(edit)
        case let .treatment(treatment):
            var edit = editor.recipe
            edit.treatment = treatment
            editor.preview(edit)
        case let .snapshot(id):
            guard let snapshot = editor.snapshots.first(where: { $0.id == id }) else { return }
            editor.preview(snapshot.recipe)
        case let .historyStep(index):
            guard editor.history.indices.contains(index) else { return }
            editor.preview(editor.history[index].recipe)
        default:
            return
        }
        previewing = kind
        report(.previewed(kind))
    }

    func clearPreview() {
        previewTask?.cancel()
        guard previewing != nil else { return }
        previewing = nil
        editor.previewRecipe(nil)
        editor.preview(nil)
        report(.previewed(nil))
    }

    /// The previewing choice's title, for the line beside the hint bar.
    var previewingTitle: String? {
        previewing.flatMap { kind in rows.first { $0.kind == kind }?.title }
    }

    func apply(_ kind: PaletteItemKind) {
        switch kind {
        case let .whiteBalance(mode):
            editor.setWhiteBalanceMode(mode)
        case let .treatment(treatment):
            editor.setTreatment(treatment)
        case let .baseLook(id):
            if let look = editor.recipes.currentBaseLooks.first(where: { $0.id == id }) {
                editor.setBaseLook(look.reference)
            }
        case let .recipe(id):
            if let recipe = editor.recipes.recipe(id: id) {
                editor.applyRecipe(recipe)
            }
        case let .compareLayout(layout):
            if let layout {
                editor.showComparison(in: layout)
            } else {
                editor.showBefore = false
            }
        case let .snapshot(id):
            if let snapshot = editor.snapshots.first(where: { $0.id == id }) {
                editor.applySnapshot(snapshot)
            }
        case let .historyStep(index):
            editor.goToHistory(index)
        case let .filterPreset(id):
            if let filters = editor.libraryFilters, let preset = filters.presets.first(where: { $0.id == id }) {
                filters.choose(preset)
            }
        case let .customLabel(name):
            editor.setCustomLabel(name)
        case let .libraryName(.folder, path):
            editor.open([URL(fileURLWithPath: path, isDirectory: true)])
        case let .libraryName(field, value):
            filterLibrary(by: LibraryQuery.Filter(field, .equal, [.text(value)]))
        case let .photo(path):
            editor.open([URL(fileURLWithPath: path)])
        case let .photosNamed(text):
            filterLibrary(by: LibraryQuery.Filter(.name, .equal, [.text(text)]))
        case let .queryTerm(term):
            filterLibrary(adding: term)
        default:
            break
        }
    }
}
