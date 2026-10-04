import AppKit
import OSLog
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
        LensProfileIssues.current = { LCPProfileLibrary.user.issues }
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
        model.onSendFeedback = { prefill in FeedbackActions.present(model: model, prefill: prefill) }
        let theme = ThemeSettings()
        let exports = ExportPresetStore()
        _model = State(initialValue: model)
        _theme = State(initialValue: theme)
        _exports = State(initialValue: exports)

        let keyboard = KeyboardShortcuts()
        AppDelegate.saveBeforeQuitting = { model.saveBeforeQuitting() }
        AppDelegate.launch = {
            let editor = EditorWindowController(
                model: model, theme: theme,
                onOpen: { Self.openPanel(model: model) },
                onExport: { ExportActions.present(model: model, store: exports) },
                onExportWithPrevious: { ExportActions.exportWithPrevious(model: model, store: exports) },
            )
            editor.showWindow(nil)
            keyboard.install(model: model)
            FeedbackActions.start()
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
/// clicked with no window open; quitting waits for the last edits to be saved.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    static var launch: (@MainActor () -> EditorWindowController)?
    static var saveBeforeQuitting: (@MainActor () -> QuitSaving)?
    let updates = Updates()
    private var editor: EditorWindowController?

    func applicationDidFinishLaunching(_: Notification) {
        editor = Self.launch?()
    }

    /// Quit, log out, shut down and an update's relaunch all come here. It waits at most about
    /// 2 s for a disk that doesn't answer, then quits anyway; edits that can't be saved are
    /// only left behind if the user says so.
    func applicationShouldTerminate(_: NSApplication) -> NSApplication.TerminateReply {
        switch Self.saveBeforeQuitting?() {
        case let .unsaved(photos):
            return Self.quitsWithout(photos) ? .terminateNow : .terminateCancel
        case .timedOut:
            Logger(subsystem: "app.redlamp.mac", category: "saving").error("Quit before the last edits were saved")
            return .terminateNow
        case .saved, nil:
            return .terminateNow
        }
    }

    private static func quitsWithout(_ photos: [URL]) -> Bool {
        let names = photos.map { $0.deletingPathExtension().lastPathComponent }
        let alert = NSAlert()
        alert.messageText = photos.count == 1
            ? "Edits to \(names[0]) can't be saved"
            : "Edits to \(photos.count) photos can't be saved"
        alert.informativeText = (photos.count == 1 ? "" : names.prefix(10).joined(separator: ", ") + "\n\n")
            + "Quitting now loses them."
        alert.addButton(withTitle: "Don't Quit")
        alert.addButton(withTitle: "Quit Anyway")
        return alert.runModal() == .alertSecondButtonReturn
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
