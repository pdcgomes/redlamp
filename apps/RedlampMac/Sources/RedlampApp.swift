import AppKit
import RedlampEngine
import RedlampEngineAPI
@_spi(Harness) import RedlampUI
import SwiftUI

@main
struct RedlampApp: App {
    @NSApplicationDelegateAdaptor private var appDelegate: AppDelegate
    @State private var model: EditorModel
    @State private var theme: ThemeSettings

    init() {
        #if DEBUG || REDLAMP_PROFILING
            DevelopPanels.usesSwiftUI = LaunchArguments.all.contains("--swiftui-panels")
        #endif
        let engine: any EditingEngine
        do {
            engine = try RedlampEngine()
        } catch {
            fatalError("Redlamp needs a Metal GPU: \(error.localizedDescription)")
        }
        let model = EditorModel(engine: engine)
        model.onFolderChange = { url in
            UserDefaults.standard.set(url.path, forKey: "lastFolder")
        }
        if let layout = UserDefaults.standard.string(forKey: "compareLayout").flatMap(CompareLayout.init) {
            model.compareLayout = layout
        }
        model.onCompareLayoutChange = { layout in
            UserDefaults.standard.set(layout.rawValue, forKey: "compareLayout")
        }
        model.onToggleFullScreen = { NSApp.keyWindow?.toggleFullScreen(nil) }
        model.onToggleToolbar = { NSApp.keyWindow?.toggleToolbarShown(nil) }
        let theme = ThemeSettings()
        _model = State(initialValue: model)
        _theme = State(initialValue: theme)

        let keyboard = KeyboardShortcuts()
        AppDelegate.launch = {
            let editor = EditorWindowController(
                model: model, theme: theme,
                onOpen: { Self.openPanel(model: model) }, onExport: { Self.exportPanel(model: model) },
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
                onOpen: { Self.openPanel(model: model) }, onExport: { Self.exportPanel(model: model) },
            )
        }

        Settings {
            SettingsView(theme: theme, engine: model.engine)
                .focusEffectDisabled()
        }
    }

    /// Opens paths passed on the command line (`mise run run -- <folder>`), otherwise the
    /// folder from the previous session.
    private static func openInitialFolder(model: EditorModel) {
        let arguments = LaunchArguments.all.dropFirst().prefix { !$0.hasPrefix("-") }
        let paths = arguments.isEmpty
            ? [UserDefaults.standard.string(forKey: "lastFolder")].compactMap(\.self)
            : Array(arguments)
        let urls = paths.map { URL(fileURLWithPath: $0) }.filter { FileManager.default.fileExists(atPath: $0.path) }
        if !urls.isEmpty {
            model.open(urls)
        }
    }

    private static func openPanel(model: EditorModel) {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = true
        panel.prompt = "Open"
        panel.message = "Choose a folder of photos, or individual images."
        if panel.runModal() == .OK {
            model.open(panel.urls)
        }
    }

    private static func exportPanel(model: EditorModel) {
        guard let info = model.info else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.jpeg]
        panel.nameFieldStringValue = info.url.deletingPathExtension().lastPathComponent + "-redlamp.jpg"
        panel.directoryURL = info.url.deletingLastPathComponent()
        guard panel.runModal() == .OK, let url = panel.url else { return }
        Task {
            do {
                try await model.exportCurrent(to: url, format: .jpeg)
                NSWorkspace.shared.activateFileViewerSelecting([url])
            } catch {
                NSAlert(error: error).runModal()
            }
        }
    }
}

/// Opens the editor window once the app has launched, and again when the Dock icon is
/// clicked with no window open.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    static var launch: (@MainActor () -> EditorWindowController)?
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
