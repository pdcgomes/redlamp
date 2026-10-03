import AppKit
import RedlampEngine
import RedlampEngineAPI
import RedlampServices
@_spi(Harness) import RedlampUI
import SwiftUI

@main
struct RedlampApp: App {
    @NSApplicationDelegateAdaptor private var appDelegate: AppDelegate
    @State private var model: EditorModel
    @State private var theme: ThemeSettings
    @State private var exports: ExportPresetStore

    init() {
        #if DEBUG || REDLAMP_PROFILING
            DebugDecodeCheck.runIfRequested()
            DevelopPanels.usesSwiftUI = LaunchArguments.all.contains("--swiftui-panels")
        #endif
        let engine: any EditingEngine
        do {
            // Photos decode in the sandboxed decode service, so a damaged file can't crash the editor.
            engine = try RedlampEngine(decoder: DecodeServiceClient(), lensProfiles: .user)
        } catch {
            fatalError("Redlamp needs a Metal GPU: \(error.localizedDescription)")
        }
        let model = EditorModel(engine: engine, library: FolderLibrary(defaults: .standard))
        // Sync and Paste onto a selection open the other photos in an engine of their own.
        model.makeWorkerEngine = { try? RedlampEngine(decoder: DecodeServiceClient(), lensProfiles: .user) }
        if let layout = UserDefaults.standard.string(forKey: "compareLayout").flatMap(CompareLayout.init) {
            model.compareLayout = layout
        }
        model.onCompareLayoutChange = { layout in
            UserDefaults.standard.set(layout.rawValue, forKey: "compareLayout")
        }
        model.onToggleFullScreen = { NSApp.keyWindow?.toggleFullScreen(nil) }
        model.onToggleToolbar = { NSApp.keyWindow?.toggleToolbarShown(nil) }
        let theme = ThemeSettings()
        let exports = ExportPresetStore()
        _model = State(initialValue: model)
        _theme = State(initialValue: theme)
        _exports = State(initialValue: exports)

        let keyboard = KeyboardShortcuts()
        AppDelegate.launch = {
            let editor = EditorWindowController(
                model: model, theme: theme,
                onOpen: { Self.openPanel(model: model) },
                onExport: { ExportActions.present(model: model, store: exports) },
                onExportWithPrevious: { ExportActions.exportWithPrevious(model: model, store: exports) },
            )
            editor.showWindow(nil)
            keyboard.install(model: model)
            Self.openInitialFolder(model: model)
            #if DEBUG || REDLAMP_PROFILING
                DebugSnapshot.scheduleIfRequested(model: model)
                DebugPerformance.scheduleIfRequested(model: model)
            #endif
            return editor
        }
    }

    /// The editor is an AppKit window (`EditorWindowController`), opened by `AppDelegate`.
    var body: some Scene {
        Window("Film Looks", id: FilmCatalogView.windowID) {
            FilmCatalogView()
                .environment(model)
                .frame(minWidth: 760, minHeight: 520)
                .focusEffectDisabled()
        }
        .defaultSize(width: 1180, height: 820)
        .defaultLaunchBehavior(.suppressed)
        .commands {
            AppCommands(
                model: model,
                updates: appDelegate.updates,
                onOpen: { Self.openPanel(model: model) },
                onExport: { ExportActions.present(model: model, store: exports) },
                onExportWithPrevious: { ExportActions.exportWithPrevious(model: model, store: exports) },
            )
        }

        Settings {
            SettingsView(
                theme: theme,
                engine: model.engine,
                checksForUpdates: appDelegate.updates.map { updates in
                    Binding(get: { updates.checksAutomatically }, set: { updates.setChecksAutomatically($0) })
                },
            )
            .focusEffectDisabled()
        }
    }

    /// Opens paths passed on the command line (`mise run run -- <folder>`), otherwise the
    /// working set and the folder from the previous session.
    private static func openInitialFolder(model: EditorModel) {
        let arguments = LaunchArguments.all.dropFirst().prefix { !$0.hasPrefix("-") }
        #if DEBUG || REDLAMP_PROFILING
            // The measurement opens its own folder; the working set would compete with it.
            if LaunchArguments.all.contains("--folders-perf") {
                return
            }
        #endif
        guard !arguments.isEmpty else {
            model.restoreLibrary()
            return
        }
        let urls = arguments.map { URL(fileURLWithPath: $0) }.filter { FileManager.default.fileExists(atPath: $0.path) }
        if !urls.isEmpty {
            model.open(urls)
        }
    }

    /// File › Open (⌘O): folders join the working set; photos add their folder and open.
    private static func openPanel(model: EditorModel) {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = true
        panel.prompt = "Add"
        panel.message = "Choose folders of photos to add to Folders, or individual photos."
        if panel.runModal() == .OK {
            model.open(panel.urls)
        }
    }
}

/// Opens the editor window once the app has launched, and again when the Dock icon is
/// clicked with no window open.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    static var launch: (@MainActor () -> EditorWindowController)?
    let updates = Updates()
    private var editor: EditorWindowController?

    func applicationDidFinishLaunching(_: Notification) {
        editor = Self.launch?()
    }

    func applicationShouldHandleReopen(_: NSApplication, hasVisibleWindows: Bool) -> Bool {
        if !hasVisibleWindows {
            editor?.showWindow(nil)
        }
        return true
    }
}

/// The command line, plus (in development builds) one line of arguments left in
/// `/tmp/redlamp-launch-args`, consumed on launch. Tooling launches through `open`, since a
/// process started straight from a non-GUI shell may never get a window, and `open` can
/// silently drop `--args` and `--env`.
enum LaunchArguments {
    static let all: [String] = {
        var arguments = CommandLine.arguments
        #if DEBUG || REDLAMP_PROFILING
            let path = "/tmp/redlamp-launch-args"
            if let line = try? String(contentsOfFile: path, encoding: .utf8) {
                try? FileManager.default.removeItem(atPath: path)
                arguments += line.split(whereSeparator: \.isWhitespace).map(String.init)
            }
        #endif
        return arguments
    }()
}
