import AppKit
import RedlampEngine
import RedlampEngineAPI
@_spi(Harness) import RedlampUI
import SwiftUI

@main
struct RedlampApp: App {
    @State private var model: EditorModel
    @State private var keyboard = KeyboardShortcuts()
    @State private var theme = ThemeSettings()

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
        _model = State(initialValue: model)
    }

    var body: some Scene {
        Window("Redlamp", id: "editor") {
            EditorView(model: model, theme: theme, onOpen: openPanel, onExport: exportPanel)
                .frame(minWidth: 1100, minHeight: 700)
                .onAppear {
                    keyboard.install(model: model)
                    openInitialFolder()
                    #if DEBUG || REDLAMP_PROFILING
                        DebugSnapshot.scheduleIfRequested(model: model)
                        DebugPerformance.scheduleIfRequested(model: model)
                    #endif
                }
        }
        .windowToolbarStyle(.unified)
        .defaultSize(width: 1600, height: 1000)
        .commands {
            AppCommands(model: model, onOpen: openPanel, onExport: exportPanel)
        }

        Settings {
            SettingsView(theme: theme)
        }
    }

    /// Opens paths passed on the command line (`mise run run -- <folder>`), otherwise the
    /// folder from the previous session.
    private func openInitialFolder() {
        let arguments = LaunchArguments.all.dropFirst().prefix { !$0.hasPrefix("-") }
        let paths = arguments.isEmpty
            ? [UserDefaults.standard.string(forKey: "lastFolder")].compactMap(\.self)
            : Array(arguments)
        let urls = paths.map { URL(fileURLWithPath: $0) }.filter { FileManager.default.fileExists(atPath: $0.path) }
        if !urls.isEmpty {
            model.open(urls)
        }
    }

    private func openPanel() {
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

    private func exportPanel() {
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
