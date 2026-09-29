import RedlampUI
import SwiftUI

struct AppCommands: Commands {
    let model: EditorModel
    let onOpen: () -> Void
    let onExport: () -> Void

    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button("Open Folder…", action: onOpen)
                .keyboardShortcut("o")
            Divider()
            Button("Export…", action: onExport)
                .keyboardShortcut("e", modifiers: [.command, .shift])
                .disabled(model.info == nil)
        }

        CommandGroup(replacing: .undoRedo) {
            Button("Undo") { model.undo() }
                .keyboardShortcut("z")
                .disabled(!model.canUndo)
            Button("Redo") { model.redo() }
                .keyboardShortcut("z", modifiers: [.command, .shift])
                .disabled(!model.canRedo)
        }

        CommandMenu("Photo") {
            Button("Copy Settings") { model.copySettings() }
                .keyboardShortcut("c", modifiers: [.command, .shift])
                .disabled(model.info == nil)
            Button("Paste Settings") { model.pasteSettings() }
                .keyboardShortcut("v", modifiers: [.command, .shift])
                .disabled(!model.hasClipboard || model.info == nil)
            Divider()
            Button("Auto Settings") { model.autoTone() }
                .keyboardShortcut("u")
                .disabled(model.info == nil)
            Button("Reset All Settings") { model.resetAll() }
                .keyboardShortcut("r", modifiers: [.command, .shift])
                .disabled(model.info == nil)
            Button("New Snapshot") { model.createSnapshot() }
                .keyboardShortcut("n")
                .disabled(model.info == nil)
            Divider()
            Button("Previous Photo") { model.selectPrevious() }
                .keyboardShortcut(.leftArrow, modifiers: [.command])
            Button("Next Photo") { model.selectNext() }
                .keyboardShortcut(.rightArrow, modifiers: [.command])
        }

        CommandGroup(after: .toolbar) {
            Section {
                Text("Before / After  \\")
                Text("Show Clipping  J")
                Text("Zoom  Z")
                Text("White Balance Selector  W")
                Text("Hide Panels  Tab")
            }
            .disabled(true)
        }
    }
}
