import AppKit
import OSLog
#if DEBUG || REDLAMP_PROFILING
    import RedlampAutomation
#endif
import RedlampDocument
import RedlampEngine
import RedlampEngineAPI
import RedlampGenerative
import RedlampServices
@_spi(Harness) import RedlampUI
import SwiftUI

@main
struct RedlampApp: App {
    @NSApplicationDelegateAdaptor private var appDelegate: AppDelegate
    @State private var model: EditorModel
    @State private var theme: ThemeSettings
    @State private var exports: ExportPresetStore
    @AppStorage(WhatsNewStore.opensKey) private var showsWhatsNew = true

    init() {
        #if DEBUG || REDLAMP_PROFILING
            DebugDecodeCheck.runIfRequested()
            Automation.listIfRequested(arguments: LaunchArguments.all)
            DevelopPanels.usesSwiftUI = LaunchArguments.all.contains("--swiftui-panels")
        #endif
        LensProfileIssues.current = { LCPProfileLibrary.user.issues }
        RedlampEngine.register(generativeFiller: { FluxFiller(model: $0) })
        let engine: any EditingEngine
        do {
            // Photos decode in the sandboxed decode service, so a damaged file can't crash the editor.
            engine = try RedlampEngine(decoder: DecodeServiceClient(), lensProfiles: .user)
        } catch {
            fatalError("Redlamp needs a Metal GPU: \(error.localizedDescription)")
        }
        let library = FolderLibrary(defaults: .standard)
        // The library opens off the main thread; until it has, and wherever it hasn't indexed a
        // folder, Folders lists folders itself, as it does with the library off.
        var service: LibraryService?
        if LibraryService.isEnabled(.standard), !Self.isMeasuringFolders {
            let opened = LibraryService(sidecars: library.sidecars, defaults: .standard) { [engine] url, size in
                engine.decodeThumbnail(for: url, maxPixelSize: size)
            }
            library.attach(opened)
            service = opened
        }
        AppDelegate.closeLibrary = { [service] in service?.close() }
        let model = EditorModel(engine: engine, library: library)
        // Sync and Paste onto a selection open the other photos in an engine of their own, and the
        // library renders edited photos' thumbnails in another.
        model.makeWorkerEngine = { try? RedlampEngine(decoder: DecodeServiceClient(), lensProfiles: .user) }
        model.editRenders.makeEngine = { try? RedlampEngine(decoder: DecodeServiceClient(), lensProfiles: .user) }
        if let layout = UserDefaults.standard.string(forKey: "compareLayout").flatMap(CompareLayout.init) {
            model.compareLayout = layout
        }
        model.onCompareLayoutChange = { layout in
            UserDefaults.standard.set(layout.rawValue, forKey: "compareLayout")
        }
        model.onToggleFullScreen = { NSApp.keyWindow?.toggleFullScreen(nil) }
        model.onToggleToolbar = { EditorWindowController.frontWindow?.toggleToolbarShown(nil) }
        model.onTestCamera = { AppDelegate.showCameraBench?() }
        model.onSendFeedback = { prefill in FeedbackActions.present(model: model, prefill: prefill) }
        AppDelegate.isEditorBusy = { model.isModalDialogOpen }
        AppDelegate.performWhatsNew = { action in
            switch action {
            case .app(.filmLooks, _): AppDelegate.performMenuItem(titled: ShortcutAction.filmLooks.title)
            case let .app(app, _): model.perform(app.shortcut)
            case let .link(url, _): NSWorkspace.shared.open(url)
            }
        }
        let theme = ThemeSettings()
        let exports = ExportPresetStore()
        _model = State(initialValue: model)
        _theme = State(initialValue: theme)
        _exports = State(initialValue: exports)

        let keyboard = KeyboardShortcuts()
        AppDelegate.saveBeforeQuitting = { model.saveBeforeQuitting() }
        CameraBenchWindow.sendFeedback = { prefill in model.onSendFeedback?(prefill) }
        AppDelegate.showCameraBench = { CameraBenchWindow.show(currentFolder: { model.folder }) }
        #if DEBUG || REDLAMP_PROFILING
            AppDelegate
                .openCameraBenchIfRequested = { CameraBenchWindow.openIfRequested(currentFolder: { model.folder }) }
        #endif
        AppDelegate.launch = {
            #if DEBUG || REDLAMP_PROFILING
                DebugDrawCounter.startIfRequested()
            #endif
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
                DebugLibraryPerformance.scheduleIfRequested(model: model)
                Automation.startIfRequested(
                    model: model, arguments: LaunchArguments.all, host: AutomationHost(theme: theme, exports: exports),
                )
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
                onWelcome: { appDelegate.showWelcome() },
                onWhatsNew: { appDelegate.showRecentNews() },
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
                showsWhatsNew: appDelegate.updates == nil ? nil : $showsWhatsNew,
            )
            .focusEffectDisabled()
        }
    }

    /// Opens paths passed on the command line (`mise run run -- <folder>`), otherwise the
    /// working set and the folder from the previous session.
    private static func openInitialFolder(model: EditorModel) {
        let arguments = LaunchArguments.all.dropFirst().prefix { !$0.hasPrefix("-") }
        // The measurement opens its own folder; the working set would compete with it.
        if isMeasuringFolders {
            return
        }
        guard !arguments.isEmpty else {
            model.restoreLibrary()
            return
        }
        let urls = arguments.map { URL(fileURLWithPath: $0) }.filter { FileManager.default.fileExists(atPath: $0.path) }
        if !urls.isEmpty {
            model.open(urls)
        }
    }

    /// `--folders-perf` and `--library-perf` measure folders and a library of their own: the working
    /// set, and the library over it, would compete with them.
    private static var isMeasuringFolders: Bool {
        #if DEBUG || REDLAMP_PROFILING
            LaunchArguments.all.contains("--folders-perf") || LaunchArguments.all.contains("--library-perf")
        #else
            false
        #endif
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
/// clicked with no window open; quitting waits for the last edits to be saved, and for the
/// AI models running.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    static var launch: (@MainActor () -> EditorWindowController)?
    static var saveBeforeQuitting: (@MainActor () -> QuitSaving)?
    /// Writes the library's store index files as the app quits.
    static var closeLibrary: (@MainActor () -> Void)?
    static var showCameraBench: (@MainActor () -> Void)?
    static var openCameraBenchIfRequested: (@MainActor () -> Void)?
    static var isEditorBusy: (@MainActor () -> Bool)?
    static var performWhatsNew: (@MainActor (WhatsNewItem.Action) -> Void)?
    /// How long after launch the highlights may still open; later, they wait for the next launch.
    static let newsWait: TimeInterval = 10
    let updates = Updates()
    private var editor: EditorWindowController?
    private var welcome: WelcomeWindowController?
    private var whatsNew: WhatsNewWindowController?
    /// Made when first needed, so a capture's `--whats-new-endpoint` is in place by then.
    private lazy var whatsNewLoader = WhatsNewLoader()

    func applicationDidFinishLaunching(_: Notification) {
        FocusRings.removeEverywhere()
        editor = Self.launch?()
        let welcomeOpens = Welcome.opensAtLaunch(arguments: LaunchArguments.all)
        if welcomeOpens {
            showWelcome()
        }
        lookForNews(firstLaunch: welcomeOpens && !LaunchArguments.all.contains("--welcome"))
        Self.openCameraBenchIfRequested?()
        Task.detached(priority: .background) {
            ExportStaging.removeLeftovers()
            await RedlampEngine.removeOutdatedModels()
        }
    }

    /// Builds from source have every highlight: their version is the last release's until the next.
    private var newsVersion: AppVersion? {
        updates == nil ? nil : AppVersion.current
    }

    /// After an update, the highlights not yet shown open over the editor if they're ready within
    /// a few seconds and nothing else has started; otherwise they wait for the next launch.
    private func lookForNews(firstLaunch: Bool) {
        let launch = WhatsNew.atLaunch(
            arguments: LaunchArguments.all, updatesItself: updates != nil,
            opensAfterUpdates: whatsNewLoader.store.opensAfterUpdates, welcomeOpens: firstLaunch,
        )
        guard launch != .nothing else { return }
        let started = Date.now
        Task {
            guard let pages = await whatsNewLoader.atLaunch(launch, version: newsVersion) else { return }
            let undisturbed = welcome == nil && NSApp.isActive && !(Self.isEditorBusy?() ?? false)
            guard launch == .open || (undisturbed && Date.now.timeIntervalSince(started) < Self.newsWait)
            else { return }
            showWhatsNew(pages)
        }
    }

    /// Help › What's New in Redlamp: the recent highlights, from the site or, offline, the last
    /// ones it sent. With neither, nothing opens, and the next launch or choice asks again.
    func showRecentNews() {
        if let whatsNew {
            whatsNew.showWindow(nil)
            return
        }
        Task {
            let pages = await whatsNewLoader.recent(version: newsVersion)
            guard !pages.items.isEmpty else { return }
            showWhatsNew(pages)
        }
    }

    private func showWhatsNew(_ pages: WhatsNewPages) {
        whatsNew?.close()
        let film = Bundle.main.url(forResource: "Welcome", withExtension: "mp4")
        let whatsNew = WhatsNewWindowController(
            pages: pages, film: film,
            onAction: { Self.performWhatsNew?($0) },
            onClose: { [weak self] in self?.whatsNew = nil },
        )
        self.whatsNew = whatsNew
        whatsNew.present(over: editor?.window)
        whatsNewLoader.markShown(pages)
    }

    /// Runs a menu item by its title, as choosing it would.
    static func performMenuItem(titled title: String) {
        func find(_ menu: NSMenu) -> (NSMenu, Int)? {
            for (index, item) in menu.items.enumerated() {
                if item.title == title {
                    return (menu, index)
                }
                if let found = item.submenu.flatMap(find) {
                    return found
                }
            }
            return nil
        }
        guard let menu = NSApp.mainMenu, let (owner, index) = find(menu) else { return }
        owner.performActionForItem(at: index)
    }

    /// The welcome window, over the editor: by itself at the first launch, and from Help ›
    /// Welcome to Redlamp.
    func showWelcome() {
        if let welcome {
            welcome.showWindow(nil)
            return
        }
        let film = Bundle.main.url(forResource: "Welcome", withExtension: "mp4")
        let welcome = WelcomeWindowController(film: film) { [weak self] in
            self?.welcome = nil
        }
        self.welcome = welcome
        welcome.present(over: editor?.window)
        Welcome.markShown()
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

    /// Exiting while an AI model runs on the GPU crashes on the way out (`Inference`): the
    /// predictions running finish first, and no other starts.
    func applicationWillTerminate(_: Notification) {
        if !RedlampEngine.stopModels(waitingAtMost: 10) {
            Logger(subsystem: "app.redlamp.mac", category: "models").error("Quit with an AI model still running")
        }
        Self.closeLibrary?()
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
/// silently drop `--args` and `--env`. Arguments left in `redlamp-launch-args` beside the bundle
/// come first, so launches close together from other checkouts (each with its own build) can't
/// take each other's. A copy under another bundle ID (the regression suite's
/// `app.redlamp.mac.e2e`) otherwise reads `/tmp/<bundle ID>-launch-args`, so it never takes
/// arguments left for the app.
enum LaunchArguments {
    static let all: [String] = {
        var arguments = CommandLine.arguments
        #if DEBUG || REDLAMP_PROFILING
            let bundle = Bundle.main.bundleIdentifier ?? "app.redlamp.mac"
            let beside = Bundle.main.bundleURL.deletingLastPathComponent().appending(path: "redlamp-launch-args").path
            let path = FileManager.default.fileExists(atPath: beside) ? beside
                : bundle == "app.redlamp.mac" ? "/tmp/redlamp-launch-args" : "/tmp/\(bundle)-launch-args"
            if let line = try? String(contentsOfFile: path, encoding: .utf8) {
                try? FileManager.default.removeItem(atPath: path)
                arguments += line.split(whereSeparator: \.isWhitespace).map(String.init)
            }
        #endif
        return arguments
    }()
}
