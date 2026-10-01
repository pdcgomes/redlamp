@_spi(Harness) import RedlampUI
import SwiftUI

@main
struct HarnessApp: App {
    var body: some Scene {
        WindowGroup("Redlamp Harness") {
            HarnessRootView()
                .frame(minWidth: 1000, minHeight: 640)
        }
        .defaultSize(width: 1400, height: 900)
        .commands {
            // The keys the app's menus bind, so the command palette scenes behave as the app.
            CommandGroup(replacing: .undoRedo) {
                Button("Undo") { PaletteSession.shared.undo() }
                    .keyboardShortcut("z", modifiers: .command)
                Button("Redo") { PaletteSession.shared.redo() }
                    .keyboardShortcut("z", modifiers: [.command, .shift])
            }
            CommandGroup(replacing: .textEditing) {
                Button("Command Palette…") { PaletteSession.shared.toggle(.all) }
                    .keyboardShortcut("k", modifiers: .command)
                Button("Find Slider…") { PaletteSession.shared.toggle(.sliders) }
                    .keyboardShortcut("f", modifiers: .command)
            }
        }
    }
}
