import AppKit
import RedlampLab
@_spi(Harness) import RedlampUI
import SwiftUI

@main
struct HarnessApp: App {
    @NSApplicationDelegateAdaptor(HarnessAppDelegate.self) private var appDelegate

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

/// The Recipe Lab's bench hub runs for as long as the harness does, so the iPhone app can reach
/// it from any scene; a `.redtask` opened from the Finder or AirDrop is filed by it.
final class HarnessAppDelegate: NSObject, NSApplicationDelegate {
    @MainActor
    func applicationDidFinishLaunching(_: Notification) {
        LabBench.shared.startIfEnabled()
        HarnessLab.connectBench()
        if let path = HarnessLaunch.value(after: "--snapshot") {
            let delay = HarnessLaunch.value(after: "--snapshot-delay").flatMap(Double.init) ?? 8
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { Self.snapshot(to: URL(fileURLWithPath: path)) }
        }
    }

    /// `--snapshot <path>`: the window as its views draw it, without Screen Recording, then quit.
    /// Views backed by Metal layers draw blank, so it suits SwiftUI scenes like the Lab's tabs.
    @MainActor
    private static func snapshot(to url: URL) {
        if let view = NSApp.windows.first(where: \.isVisible)?.contentView,
           let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) {
            view.cacheDisplay(in: view.bounds, to: rep)
            try? rep.representation(using: .png, properties: [:])?.write(to: url)
        }
        NSApp.terminate(nil)
    }

    @MainActor
    func application(_: NSApplication, open urls: [URL]) {
        for url in urls where url.pathExtension.lowercased() == "redtask" {
            LabBench.shared.receive(url)
        }
    }
}
