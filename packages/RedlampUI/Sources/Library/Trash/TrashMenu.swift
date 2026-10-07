import AppKit
import RedlampDesign
import RedlampLibrary

/// A Recently Trashed photo's context menu, in the filmstrip and, after the grid's own items, in the grid
/// (LIB-26): Put Back, for the selection when the photo is in it and for the photo alone when it isn't, and
/// Put Back for every photo of the batch that moved it to the Trash.
@MainActor
enum TrashMenu {
    /// The menu for `photo`; nil for a photo that isn't in Recently Trashed.
    static func menu(for photo: URL, model: EditorModel) -> NSMenu? {
        guard let trashed = model.library.trashedPhoto(at: photo), !model.isModalDialogOpen else { return nil }
        let menu = NSMenu()
        let count = model.trashedPhotos(for: photo).count
        let putBack = NSMenuItem(title: count > 1 ? "Put Back \(count) Photos" : ShortcutAction.putBack.title) {
            model.putBack(photo)
            model.activity.record(.action, ShortcutAction.putBack.title)
        }
        putBack.keyEquivalent = "\u{7F}"
        putBack.keyEquivalentModifierMask = [.command]
        putBack.setAccessibilityIdentifier("library.menu.putBack")
        menu.addItem(putBack)
        let batch = NSMenuItem(title: "Put Back All of “\(trashed.title)”") {
            model.putBackBatch(of: photo)
            model.activity.record(.action, ShortcutAction.putBackBatch.title)
        }
        batch.toolTip = "Every photo still in the Trash that went there with this one, "
            + trashed.trashed.formatted(date: .abbreviated, time: .shortened)
        batch.setAccessibilityIdentifier("library.menu.putBackBatch")
        menu.addItem(batch)
        return menu
    }
}
