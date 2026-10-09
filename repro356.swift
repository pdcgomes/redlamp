// A copy of Redlamp's Export dialog setup, to reproduce bug #356 on macOS 27: "Export to" →
// "Choose…" needs two tries before the folder panel opens. The app is a SwiftUI App with an
// AppKit editor window, as Redlamp is; the dialog is a sheet on it that also runs an app-modal
// session (ExportActions.present). A driver thread opens the dialog and picks Choose… with real
// mouse and keyboard events, and logs what the app did.
//
// Build: swiftc -parse-as-library -swift-version 5 -O -target arm64-apple-macos26.0 repro356.swift -o repro356
// Run:   repro356 --variant v027 --open key --out /tmp/out [--attempts 3] [--initial edited|original]

import AppKit
import ApplicationServices
import SwiftUI

// MARK: - Options

nonisolated(unsafe) var variant = "v027"
nonisolated(unsafe) var opening = "key"
nonisolated(unsafe) var attempts = 3
nonisolated(unsafe) var outDir = "/tmp/repro356"
nonisolated(unsafe) var initial = "edited"
nonisolated(unsafe) var dry = false
nonisolated(unsafe) var shots = true
nonisolated(unsafe) var firstWait = 12.0
nonisolated(unsafe) var laterWait = 8.0
nonisolated(unsafe) var screenChoice = "main"

func parseArguments() {
    var it = CommandLine.arguments.dropFirst().makeIterator()
    while let a = it.next() {
        switch a {
        case "--variant": variant = it.next() ?? variant
        case "--open": opening = it.next() ?? opening
        case "--attempts": attempts = Int(it.next() ?? "") ?? attempts
        case "--out": outDir = it.next() ?? outDir
        case "--initial": initial = it.next() ?? initial
        case "--dry": dry = true
        case "--no-shots": shots = false
        case "--first-wait": firstWait = Double(it.next() ?? "") ?? firstWait
        case "--photos": photosOverride = it.next()
        case "--screen": screenChoice = it.next() ?? screenChoice
        default: break
        }
    }
    try? FileManager.default.createDirectory(atPath: outDir, withIntermediateDirectories: true)
    try? FileManager.default.createDirectory(at: editedFolder, withIntermediateDirectories: true)
}

nonisolated(unsafe) var photosOverride: String?
var photoFolder: URL { URL(fileURLWithPath: photosOverride ?? outDir + "/Photos", isDirectory: true) }
var editedFolder: URL { photoFolder.appendingPathComponent("Edited", isDirectory: true) }

// MARK: - Logging and shared state

let started = Date()
let logLock = NSLock()

func log(_ s: String) {
    let line = String(format: "[%7.3f] [%@] ", Date().timeIntervalSince(started), Thread.isMainThread ? "main" : "drv ") + s + "\n"
    logLock.lock()
    FileHandle.standardOutput.write(line.data(using: .utf8)!)
    logLock.unlock()
}

func ms(since d: Date) -> Int { Int(Date().timeIntervalSince(d) * 1000) }
func mode() -> String { RunLoop.current.currentMode?.rawValue ?? "none" }
func describe(_ w: NSWindow?) -> String { w.map { "\(type(of: $0))#\($0.windowNumber)" } ?? "nil" }

/// The run loop callouts on the stack, innermost first: whether we're inside a GCD main-queue
/// drain, a timer, a perform block, an event or a menu.
func callouts() -> String {
    let marks: [(String, String)] = [
        ("__CFRUNLOOP_IS_SERVICING_THE_MAIN_DISPATCH_QUEUE__", "mainQueue"),
        ("__CFRUNLOOP_IS_CALLING_OUT_TO_A_TIMER_CALLBACK_FUNCTION__", "timer"),
        ("__CFRUNLOOP_IS_CALLING_OUT_TO_A_BLOCK__", "block"),
        ("__CFRUNLOOP_IS_CALLING_OUT_TO_A_SOURCE0_PERFORM_FUNCTION__", "source0"),
        ("__CFRUNLOOP_IS_CALLING_OUT_TO_A_SOURCE1_PERFORM_FUNCTION__", "source1"),
        ("_runModalSession", "modalSession"),
        ("runModalForWindow", "runModalForWindow"),
        ("trackWithEvent", "menuTracking"),
        ("_NSHandleCarbonMenuEvent", "carbonMenu"),
        ("performKeyEquivalent", "keyEquivalent"),
        ("sendEvent", "sendEvent"),
        ("swift_job_run", "swiftJob"),
    ]
    var found: [String] = []
    for frame in Thread.callStackSymbols {
        for (symbol, name) in marks where frame.contains(symbol) {
            found.append(name)
        }
    }
    return found.joined(separator: "<")
}

final class Locked<T>: @unchecked Sendable {
    private var value: T
    private let lock = NSLock()
    init(_ v: T) { value = v }
    func get() -> T { lock.lock(); defer { lock.unlock() }; return value }
    func set(_ v: T) { lock.lock(); value = v; lock.unlock() }
    func update(_ f: (inout T) -> Void) { lock.lock(); f(&value); lock.unlock() }
}

let menuOpen = Locked(false)
let menuOpenCount = Locked(0)
let setterLog = Locked<[String]>([])
let chooseCount = Locked(0)
let panelActive = Locked(false)
let panelVisible = Locked(false)
let panelShownCount = Locked(0)
let panelResults = Locked<[Int]>([])
let dialogUp = Locked(false)
nonisolated(unsafe) var currentPanel: NSSavePanel?
nonisolated(unsafe) var dialogWindow: NSWindow?
nonisolated(unsafe) var editorWindow: NSWindow?

// MARK: - The folder panel, as ExportLocationSection makes it

@MainActor
func makePanel(directory: URL?) -> NSOpenPanel {
    chooseCount.update { $0 += 1 }
    log("making NSOpenPanel: mode \(mode()), menuOpen \(menuOpen.get()), modalWindow \(describe(NSApp.modalWindow)), key \(describe(NSApp.keyWindow)), active \(NSApp.isActive), callouts \(callouts())")
    let t = Date()
    let panel = NSOpenPanel()
    log("NSOpenPanel() took \(ms(since: t)) ms (\(type(of: panel)))")
    panel.canChooseDirectories = true
    panel.canChooseFiles = false
    panel.canCreateDirectories = true
    panel.prompt = "Choose"
    panel.message = "Choose the folder exports go to."
    panel.directoryURL = directory
    currentPanel = panel
    return panel
}

@MainActor
func runPanelModally(directory: URL?, chosen: (URL) -> Void) {
    let panel = makePanel(directory: directory)
    panelActive.set(true)
    let t = Date()
    log("runModal start")
    let r = panel.runModal()
    panelActive.set(false)
    panelResults.update { $0.append(r.rawValue) }
    log("runModal returned \(r.rawValue) after \(ms(since: t)) ms (url \(panel.url?.path ?? "nil"))")
    if r == .OK, let url = panel.url { chosen(url) }
}

@MainActor
func runPanelAsSheet(directory: URL?, chosen: @escaping (URL) -> Void) {
    guard let dialog = dialogWindow else { return log("no dialog window") }
    let panel = makePanel(directory: directory)
    panelActive.set(true)
    let t = Date()
    log("beginSheetModal(for: dialog) start")
    panel.beginSheetModal(for: dialog) { r in
        panelActive.set(false)
        panelResults.update { $0.append(r.rawValue) }
        log("sheet completion \(r.rawValue) after \(ms(since: t)) ms (url \(panel.url?.path ?? "nil"))")
        if r == .OK, let url = panel.url { chosen(url) }
    }
    log("beginSheetModal returned (visible \(panel.isVisible), attached \(describe(dialog.attachedSheet)))")
}

// MARK: - The dialog's view, as ExportSheet and ExportLocationSection lay it out

enum Choice: Hashable {
    case original, folder(URL), choose
}

func label(_ c: Choice) -> String {
    switch c {
    case .original: "original"
    case let .folder(url): "folder(\(url.lastPathComponent))"
    case .choose: "choose"
    }
}

struct ExportSettings: Equatable {
    var destinationFolder: URL?
    var naming = 0
    var suffix = "-redlamp"
    var existing = 0
    var format = 0
    var quality = 100.0
    var colorSpace = 0
    var resize = 0
    var metadata = 0
    var reveal = false
}

struct LocationSection: View {
    @Binding var settings: ExportSettings
    @State private var chosenFolder: URL?

    var body: some View {
        Section("Location") {
            if variant.hasPrefix("button") {
                LabeledContent("Export to") {
                    HStack {
                        Picker("Export to", selection: choice) {
                            Text("Same Folder as Original").tag(Choice.original)
                            if let folder = settings.destinationFolder ?? chosenFolder {
                                Text(folder.lastPathComponent).tag(Choice.folder(folder))
                            }
                        }
                        .labelsHidden()
                        .fixedSize()
                        Button("Choose…") {
                            log("Choose… button: mode \(mode()), callouts \(callouts())")
                            setterLog.update { $0.append("button") }
                            choose()
                        }
                    }
                }
            } else {
                Picker("Export to", selection: choice) {
                    Text("Same Folder as Original").tag(Choice.original)
                    if let folder = settings.destinationFolder ?? chosenFolder {
                        Text(folder.lastPathComponent).tag(Choice.folder(folder))
                    }
                    Divider()
                    Text("Choose…").tag(Choice.choose)
                }
            }
            Picker("File name", selection: $settings.naming) {
                Text("Original").tag(0)
                Text("Custom").tag(1)
            }
            TextField("Suffix", text: $settings.suffix, prompt: Text("None"))
            LabeledContent("Saves as") {
                Text("P1117458-redlamp.jpg").foregroundStyle(.secondary).truncationMode(.middle).lineLimit(1)
            }
            Picker("If the file exists", selection: $settings.existing) {
                Text("Ask").tag(0)
                Text("Add a Number").tag(1)
                Text("Overwrite").tag(2)
            }
        }
        .onAppear { chosenFolder = settings.destinationFolder }
        .onChange(of: settings, initial: true) {
            log("settings: destination \(settings.destinationFolder?.lastPathComponent ?? "nil")")
        }
    }

    private var choice: Binding<Choice> {
        Binding(
            get: { settings.destinationFolder.map(Choice.folder) ?? .original },
            set: { choice in
                let event = NSApp.currentEvent.map { "\($0.type.rawValue)" } ?? "nil"
                log("setter(\(label(choice))): mode \(mode()), menuOpen \(menuOpen.get()), event \(event), callouts \(callouts())")
                setterLog.update { $0.append(label(choice)) }
                switch choice {
                case .original: settings.destinationFolder = nil
                case let .folder(url): settings.destinationFolder = url
                case .choose: chooseFromPicker()
                }
            },
        )
    }

    private func chooseFromPicker() {
        switch variant {
        case "v026", "noAppModalSync", "sheetSync":
            choose()
        case "async":
            DispatchQueue.main.async { choose() }
        default:
            RunLoop.main.perform(inModes: [.default, .modalPanel]) {
                MainActor.assumeIsolated { choose() }
            }
        }
    }

    private func choose() {
        let directory = settings.destinationFolder ?? photoFolder
        let chosen: (URL) -> Void = { url in
            chosenFolder = url
            settings.destinationFolder = url
        }
        if variant.lowercased().contains("sheet") {
            runPanelAsSheet(directory: directory, chosen: chosen)
        } else {
            runPanelModally(directory: directory, chosen: chosen)
        }
    }
}

struct ExportSheetCopy: View {
    let height: CGFloat
    let onCancel: () -> Void
    @State private var settings = ExportSettings(destinationFolder: initial == "edited" ? editedFolder : nil)

    var body: some View {
        VStack(spacing: 0) {
            Form {
                Section {
                    LabeledContent("Preset") {
                        Menu("Full Size JPEG (edited)") {
                            Section {
                                Button("Full Size JPEG") {}
                                Button("Web, 2048 px") {}
                            }
                            Divider()
                            Button("Save as Preset…") {}
                        }
                        .fixedSize()
                    }
                }
                LocationSection(settings: $settings)
                Section("File") {
                    Picker("Format", selection: $settings.format) {
                        Section("Lossy") {
                            Text("JPEG").tag(0)
                            Text("HEIC").tag(1)
                        }
                        Section("Lossless") {
                            Text("TIFF").tag(2)
                            Text("PNG").tag(3)
                        }
                    }
                    LabeledContent("Quality") {
                        Slider(value: $settings.quality, in: 0 ... 100)
                    }
                    Picker("Color space", selection: $settings.colorSpace) {
                        Text("sRGB").tag(0)
                        Text("Display P3").tag(1)
                    }
                }
                Section("Size") {
                    Picker("Resize", selection: $settings.resize) {
                        Text("Full Size").tag(0)
                        Text("Long Edge").tag(1)
                    }
                }
                Section {
                    Picker("Metadata", selection: $settings.metadata) {
                        Text("All").tag(0)
                        Text("None").tag(1)
                    }
                    Toggle("Show in Finder after export", isOn: $settings.reveal)
                }
            }
            .formStyle(.grouped)
            .frame(maxHeight: .infinity)
            .tint(.orange)
            .focusEffectDisabled()
            Divider()
            HStack {
                Spacer()
                Button("Cancel", role: .cancel, action: onCancel).keyboardShortcut(.cancelAction)
                Button("Export") {}.keyboardShortcut(.defaultAction)
            }
            .padding(16)
        }
        .frame(width: 540, height: height)
        .tint(.orange)
    }
}

final class RinglessWindow: NSWindow {
    private var focusObservation: NSKeyValueObservation?

    override init(contentRect: NSRect, styleMask style: NSWindow.StyleMask, backing: NSWindow.BackingStoreType, defer flag: Bool) {
        super.init(contentRect: contentRect, styleMask: style, backing: backing, defer: flag)
        focusObservation = observe(\.firstResponder, options: [.initial, .new]) { window, _ in
            var view = window.firstResponder as? NSView
            if let editor = view as? NSTextView, editor.isFieldEditor {
                view = editor.delegate as? NSView
            }
            view?.focusRingType = .none
        }
    }
}

// MARK: - Presenting it, as ExportActions.present does

@MainActor
enum Presenter {
    static func present() {
        log("present: mode \(mode()), callouts \(callouts())")
        guard let editor = editorWindow, editor.attachedSheet == nil else { return log("present: no editor or a sheet is up") }
        let height = min(720, max(editor.contentLayoutRect.height - 24, 400))
        let dialog = RinglessWindow(
            contentRect: CGRect(x: 0, y: 0, width: 540, height: height),
            styleMask: [.titled],
            backing: .buffered,
            defer: false,
        )
        dialogWindow = dialog
        let appModal = !variant.hasPrefix("noAppModal")
        let close = {
            log("Cancel")
            if appModal { NSApp.stopModal() }
            editor.endSheet(dialog)
            dialogUp.set(false)
        }
        dialog.contentViewController = NSHostingController(rootView: ExportSheetCopy(height: height, onCancel: close).focusEffectDisabled())
        DispatchQueue.main.async { log("probe: the main queue ran while the dialog was up") }
        Task { @MainActor in log("probe: a main-actor task ran while the dialog was up") }
        editor.beginSheet(dialog)
        dialogUp.set(true)
        if appModal {
            log("runModal(for: dialog) start")
            let r = NSApp.runModal(for: dialog)
            log("runModal(for: dialog) returned \(r.rawValue)")
        }
    }
}

// MARK: - The app

@main
struct Repro356App: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var body: some Scene {
        Settings { Text("Repro 356") }
            .commands {
                CommandGroup(after: .newItem) {
                    Button("Export…") {
                        log("command Export…: mode \(mode()), callouts \(callouts())")
                        Presenter.present()
                    }
                    .keyboardShortcut("e", modifiers: [.command, .shift])
                    Button("Export with Previous") {
                        log("command Export with Previous: mode \(mode()), callouts \(callouts())")
                        Task { @MainActor in
                            log("export with previous: no previous export, presenting from a task")
                            Presenter.present()
                        }
                    }
                    .keyboardShortcut("e", modifiers: [.command, .shift, .option])
                }
            }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSToolbarDelegate {
    func applicationDidFinishLaunching(_: Notification) {
        parseArguments()
        log("launched: \(ProcessInfo.processInfo.operatingSystemVersionString), variant \(variant), open \(opening), initial \(initial), bundle \(Bundle.main.bundleIdentifier ?? "none")")
        log("trusted: ax \(AXIsProcessTrusted()), postEvent \(CGPreflightPostEventAccess()), screenCapture \(CGPreflightScreenCaptureAccess())")
        installObservers()
        log("screens: \(NSScreen.screens.map { "\($0.frame) visible \($0.visibleFrame) @\($0.backingScaleFactor)x" })")
        let others = NSScreen.screens.dropFirst().sorted { $0.frame.width > $1.frame.width }
        let target = screenChoice == "external" ? (others.first ?? NSScreen.screens[0]) : NSScreen.screens[0]
        log("editor goes on \(target.localizedName) \(target.frame) @\(target.backingScaleFactor)x")
        let visible = target.visibleFrame
        let size = NSSize(width: min(1100, visible.width - 40), height: min(760, visible.height - 20))
        let editor = RinglessWindow(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered, defer: false,
        )
        editor.title = "P1117458.RW2"
        editor.subtitle = "Panasonic DC-S5M2"
        editor.toolbarStyle = .unified
        editor.titlebarAppearsTransparent = true
        let toolbar = NSToolbar(identifier: "Editor")
        toolbar.delegate = self
        toolbar.displayMode = .iconOnly
        editor.toolbar = toolbar
        editor.contentView = NSHostingView(rootView: Color(white: 0.16).ignoresSafeArea())
        editor.setFrameOrigin(NSPoint(x: visible.minX + 20, y: visible.minY + (visible.height - size.height) / 2))
        editor.makeKeyAndOrderFront(nil)
        editorWindow = editor
        NSApp.activate(ignoringOtherApps: true)
        if variant == "warm" {
            let t = Date()
            _ = NSOpenPanel()
            log("warm-up NSOpenPanel() took \(ms(since: t)) ms")
        }
        Thread { dry ? dryRun() : drive() }.start()
        Thread {
            Thread.sleep(forTimeInterval: 240)
            log("WATCHDOG: giving up")
            finish(code: 3)
        }.start()
    }

    func toolbarDefaultItemIdentifiers(_: NSToolbar) -> [NSToolbarItem.Identifier] {
        [.flexibleSpace, NSToolbarItem.Identifier("export"), .flexibleSpace]
    }

    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        toolbarDefaultItemIdentifiers(toolbar)
    }

    func toolbar(_: NSToolbar, itemForItemIdentifier identifier: NSToolbarItem.Identifier, willBeInsertedIntoToolbar _: Bool) -> NSToolbarItem? {
        let item = NSToolbarItem(itemIdentifier: identifier)
        item.label = "Export"
        item.image = NSImage(systemSymbolName: "square.and.arrow.up", accessibilityDescription: "Export")
        item.toolTip = "Export (⇧⌘E)"
        item.isBordered = true
        item.target = self
        item.action = #selector(export)
        return item
    }

    @objc func export() {
        log("toolbar Export: mode \(mode()), callouts \(callouts())")
        Presenter.present()
    }

    func installObservers() {
        let nc = NotificationCenter.default
        nc.addObserver(forName: NSMenu.didBeginTrackingNotification, object: nil, queue: nil) { n in
            let menu = n.object as? NSMenu
            let items = menu?.items.map(\.title) ?? []
            let isMainMenu = menu === NSApp.mainMenu || menu?.supermenu != nil
            if !isMainMenu {
                menuOpen.set(true)
                menuOpenCount.update { $0 += 1 }
            }
            log("menu began tracking: \(items), main \(isMainMenu), mode \(mode())")
        }
        nc.addObserver(forName: NSMenu.didEndTrackingNotification, object: nil, queue: nil) { n in
            let menu = n.object as? NSMenu
            if !(menu === NSApp.mainMenu || menu?.supermenu != nil) { menuOpen.set(false) }
            log("menu ended tracking: \(menu?.items.first?.title ?? "?"), mode \(mode())")
        }
        nc.addObserver(forName: NSWindow.didBecomeKeyNotification, object: nil, queue: nil) { n in
            log("key window: \(describe(n.object as? NSWindow))")
        }
        nc.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: nil) { _ in log("app became active") }
        nc.addObserver(forName: NSApplication.didResignActiveNotification, object: nil, queue: nil) { _ in log("app resigned active") }
        let timer = Timer(timeInterval: 0.15, repeats: true) { _ in
            MainActor.assumeIsolated {
                let visible = currentPanel?.isVisible ?? false
                if visible != panelVisible.get() {
                    panelVisible.set(visible)
                    if visible { panelShownCount.update { $0 += 1 } }
                    log("panel visible: \(visible) (key \(currentPanel?.isKeyWindow ?? false), modalWindow \(describe(NSApp.modalWindow)), frame \(currentPanel?.frame ?? .zero), mode \(mode()))")
                }
            }
        }
        RunLoop.main.add(timer, forMode: .common)
    }
}

// MARK: - Driver: real events, from a thread of its own

func onMain<T: Sendable>(timeout: Double = 5, _ body: @escaping @MainActor () -> T) -> T? {
    let sem = DispatchSemaphore(value: 0)
    let box = Locked<T?>(nil)
    CFRunLoopPerformBlock(CFRunLoopGetMain(), CFRunLoopMode.commonModes.rawValue) {
        box.set(MainActor.assumeIsolated { body() })
        sem.signal()
    }
    CFRunLoopWakeUp(CFRunLoopGetMain())
    guard sem.wait(timeout: .now() + timeout) == .success else {
        log("onMain timed out after \(timeout) s")
        return nil
    }
    return box.get()
}

struct Win {
    let number: Int
    let pid: Int32
    let owner: String
    let name: String
    let layer: Int
    let bounds: CGRect
}

func windows() -> [Win] {
    guard let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] else { return [] }
    return list.map { d in
        Win(
            number: (d[kCGWindowNumber as String] as? NSNumber)?.intValue ?? 0,
            pid: (d[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value ?? 0,
            owner: d[kCGWindowOwnerName as String] as? String ?? "",
            name: d[kCGWindowName as String] as? String ?? "",
            layer: (d[kCGWindowLayer as String] as? NSNumber)?.intValue ?? 0,
            bounds: (d[kCGWindowBounds as String]).flatMap { CGRect(dictionaryRepresentation: $0 as! CFDictionary) } ?? .zero,
        )
    }
}

func logWindows(_ why: String) {
    let me = getpid()
    let mine = windows().filter { $0.pid == me || $0.owner.localizedCaseInsensitiveContains("panel") || $0.owner.localizedCaseInsensitiveContains("open and save") }
    log("windows (\(why)): " + mine.map { "#\($0.number) \($0.owner)/'\($0.name)' L\($0.layer) \(Int($0.bounds.minX)),\(Int($0.bounds.minY)) \(Int($0.bounds.width))x\(Int($0.bounds.height))" }.joined(separator: "; "))
}

func topWindow(at p: CGPoint) -> Win? {
    windows().first { $0.bounds.contains(p) && $0.layer < 1000 && $0.layer != 20 && $0.layer != 24 && $0.layer != 25 }
}

func mouse(_ type: CGEventType, _ p: CGPoint) {
    guard let e = CGEvent(mouseEventSource: nil, mouseType: type, mouseCursorPosition: p, mouseButton: .left) else { return }
    if type != .mouseMoved { e.setIntegerValueField(.mouseEventClickState, value: 1) }
    e.post(tap: .cghidEventTap)
}

func move(to p: CGPoint) {
    let from = CGEvent(source: nil)?.location ?? p
    for i in 1 ... 6 {
        let f = CGFloat(i) / 6
        mouse(.mouseMoved, CGPoint(x: from.x + (p.x - from.x) * f, y: from.y + (p.y - from.y) * f))
        usleep(25000)
    }
}

func isOurs(_ p: CGPoint) -> Bool {
    guard let top = topWindow(at: p) else { return false }
    if top.pid != getpid() {
        log("refusing to click at \(p): \(top.owner) is on top there")
        return false
    }
    return true
}

func click(_ p: CGPoint) {
    guard isOurs(p) else { return }
    move(to: p)
    usleep(120_000)
    mouse(.leftMouseDown, p)
    usleep(70000)
    mouse(.leftMouseUp, p)
    log("clicked \(p)")
}

/// Presses a pop-up button and lets go once its menu is up, as a quick click does, so the menu
/// stays open.
func openMenu(_ p: CGPoint) -> Bool {
    guard isOurs(p) else { return false }
    let before = menuOpenCount.get()
    move(to: p)
    usleep(120_000)
    mouse(.leftMouseDown, p)
    let opened = waitFor(2) { menuOpenCount.get() > before }
    usleep(30000)
    mouse(.leftMouseUp, p)
    usleep(400_000)
    let stayed = menuOpen.get()
    log("pressed \(p): menu \(opened ? "opened" : "didn't open")\(opened && !stayed ? ", then closed on release" : "")")
    return opened && stayed
}

func key(_ code: CGKeyCode, _ flags: CGEventFlags = []) {
    guard let down = CGEvent(keyboardEventSource: nil, virtualKey: code, keyDown: true),
          let up = CGEvent(keyboardEventSource: nil, virtualKey: code, keyDown: false) else { return }
    down.flags = flags
    up.flags = flags
    down.post(tap: .cghidEventTap)
    usleep(40000)
    up.post(tap: .cghidEventTap)
}

func waitFor(_ seconds: Double, _ cond: () -> Bool) -> Bool {
    let end = Date().addingTimeInterval(seconds)
    while Date() < end {
        if cond() { return true }
        usleep(30000)
    }
    return cond()
}

func screenshot(_ name: String) {
    guard shots else { return }
    var count: UInt32 = 0
    CGGetActiveDisplayList(0, nil, &count)
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
    p.arguments = ["-x", "-t", "jpg"] + (1 ... max(1, Int(count))).map { "\(outDir)/\(name)-d\($0).jpg" }
    do {
        try p.run()
        p.waitUntilExit()
        log("screenshot \(name): \(p.terminationStatus)")
    } catch {
        log("screenshot \(name) failed: \(error)")
    }
}

func axString(_ el: AXUIElement, _ attr: String) -> String? {
    var v: CFTypeRef?
    guard AXUIElementCopyAttributeValue(el, attr as CFString, &v) == .success else { return nil }
    return v as? String
}

func axChildren(_ el: AXUIElement) -> [AXUIElement] {
    var v: CFTypeRef?
    guard AXUIElementCopyAttributeValue(el, kAXChildrenAttribute as CFString, &v) == .success else { return [] }
    return v as? [AXUIElement] ?? []
}

func axFrame(_ el: AXUIElement) -> CGRect? {
    var pv: CFTypeRef?
    var sv: CFTypeRef?
    guard AXUIElementCopyAttributeValue(el, kAXPositionAttribute as CFString, &pv) == .success,
          AXUIElementCopyAttributeValue(el, kAXSizeAttribute as CFString, &sv) == .success,
          let pv, let sv else { return nil }
    var p = CGPoint.zero
    var s = CGSize.zero
    AXValueGetValue(pv as! AXValue, .cgPoint, &p)
    AXValueGetValue(sv as! AXValue, .cgSize, &s)
    return CGRect(origin: p, size: s)
}

func axSearch(role: String, names: [String], timeLimit: Double = 4) -> CGRect? {
    let app = AXUIElementCreateApplication(getpid())
    AXUIElementSetMessagingTimeout(app, 1.5)
    var queue: [(AXUIElement, Int)] = [(app, 0)]
    let t = Date()
    var visited = 0
    while !queue.isEmpty, Date().timeIntervalSince(t) < timeLimit {
        let (el, depth) = queue.removeFirst()
        visited += 1
        if axString(el, kAXRoleAttribute) == role {
            let found = [kAXTitleAttribute, kAXValueAttribute, kAXDescriptionAttribute].compactMap { axString(el, $0) }
            if found.contains(where: names.contains), let frame = axFrame(el) {
                log("AX: \(role) \(found) at \(frame) (\(visited) elements)")
                return frame
            }
        }
        if depth < 18, axString(el, kAXRoleAttribute) != "AXMenuBar" {
            queue.append(contentsOf: axChildren(el).map { ($0, depth + 1) })
        }
    }
    log("AX: no \(role) named \(names) (\(visited) elements, \(ms(since: t)) ms)")
    return nil
}

struct Geometry {
    var popup: CGRect?
    var chooseButton: CGRect?
    var dialog: CGRect
    var editorNumber: Int
    var dialogNumber: Int
}

func findGeometry() -> Geometry? {
    let g = onMain { () -> Geometry? in
        guard let dialog = dialogWindow, let editor = editorWindow, let content = dialog.contentView else { return nil }
        let flipY = NSScreen.screens[0].frame.height
        func cg(_ r: NSRect) -> CGRect { CGRect(x: r.minX, y: flipY - r.maxY, width: r.width, height: r.height) }
        func screenRect(_ v: NSView) -> CGRect { cg(dialog.convertToScreen(v.convert(v.bounds, to: nil))) }
        var popups: [NSPopUpButton] = []
        var buttons: [NSButton] = []
        func walk(_ v: NSView) {
            if let p = v as? NSPopUpButton { popups.append(p) } else if let b = v as? NSButton { buttons.append(b) }
            v.subviews.forEach(walk)
        }
        walk(content)
        for p in popups { log("popup \(type(of: p)) '\(p.title)' pullsDown \(p.pullsDown) items \(p.numberOfItems) at \(screenRect(p))") }
        for b in buttons { log("button \(type(of: b)) '\(b.title)' at \(screenRect(b))") }
        let target = initial == "edited" ? "Edited" : "Same Folder as Original"
        let popup = popups.first { $0.title == target || $0.titleOfSelectedItem == target }
        let choose = buttons.first { $0.title == "Choose…" }
        return Geometry(popup: popup.map(screenRect), chooseButton: choose.map(screenRect), dialog: cg(dialog.frame), editorNumber: editor.windowNumber, dialogNumber: dialog.windowNumber)
    } ?? nil
    guard var g else { return nil }
    if let server = windows().first(where: { $0.number == g.dialogNumber })?.bounds,
       abs(server.minX - g.dialog.minX) > 2 || abs(server.minY - g.dialog.minY) > 2 || abs(server.width - g.dialog.width) > 2 {
        log("the window server has the dialog at \(server), AppKit at \(g.dialog): mapping")
        let (sx, sy) = (server.width / g.dialog.width, server.height / g.dialog.height)
        func map(_ r: CGRect) -> CGRect {
            CGRect(x: server.minX + (r.minX - g.dialog.minX) * sx, y: server.minY + (r.minY - g.dialog.minY) * sy, width: r.width * sx, height: r.height * sy)
        }
        g.popup = g.popup.map(map)
        g.chooseButton = g.chooseButton.map(map)
        g.dialog = server
    }
    if g.popup == nil, !variant.hasPrefix("button") {
        g.popup = axSearch(role: "AXPopUpButton", names: [initial == "edited" ? "Edited" : "Same Folder as Original"])
    }
    if g.chooseButton == nil, variant.hasPrefix("button") {
        g.chooseButton = axSearch(role: "AXButton", names: ["Choose…"])
    }
    return g
}

func panelOnScreen(_ g: Geometry) -> Bool {
    let me = getpid()
    return windows().contains { w in
        (w.pid == me && w.number != g.editorNumber && w.number != g.dialogNumber && w.layer < 100 && w.bounds.width > 300 && w.bounds.height > 200)
            || (w.owner.localizedCaseInsensitiveContains("open and save") && w.bounds.width > 300)
    }
}

nonisolated(unsafe) var results: [String] = []

func finish(code: Int32 = 0) {
    log("SUMMARY variant \(variant) open \(opening) initial \(initial): " + results.joined(separator: " | "))
    let summary: [String: Any] = ["variant": variant, "open": opening, "initial": initial, "results": results]
    if let data = try? JSONSerialization.data(withJSONObject: summary, options: [.prettyPrinted]) {
        try? data.write(to: URL(fileURLWithPath: outDir).appendingPathComponent("summary.json"))
    }
    exit(code)
}

func ensureActive() {
    if onMain({ NSApp.isActive }) == true { return }
    log("app isn't active; clicking the editor's content")
    if let frame = onMain({ editorWindow.map { $0.frame } ?? .zero }) {
        let flipY = onMain { NSScreen.screens[0].frame.height } ?? 0
        click(CGPoint(x: frame.midX, y: flipY - frame.minY - 60))
        Thread.sleep(forTimeInterval: 1)
    }
    log("active: \(onMain({ NSApp.isActive }) ?? false)")
}

func openDialog() -> Bool {
    ensureActive()
    switch opening {
    case "key":
        log("pressing ⇧⌘E")
        key(14, [.maskCommand, .maskShift])
    case "previous":
        log("pressing ⌥⇧⌘E")
        key(14, [.maskCommand, .maskShift, .maskAlternate])
    case "toolbar":
        guard let rect = axSearch(role: "AXButton", names: ["Export"]) else { return false }
        click(CGPoint(x: rect.midX, y: rect.midY))
    default:
        _ = onMain { Presenter.present() }
    }
    return waitFor(5) { dialogUp.get() }
}

func drive() {
    Thread.sleep(forTimeInterval: 2)
    logWindows("start")
    guard openDialog() else {
        log("FAIL: the dialog didn't open")
        screenshot("0-no-dialog")
        return finish(code: 2)
    }
    Thread.sleep(forTimeInterval: 1.5)
    guard let g = findGeometry(), g.popup != nil || g.chooseButton != nil else {
        log("FAIL: no Export to pop-up or Choose… button")
        screenshot("0-no-geometry")
        return finish(code: 2)
    }
    log("geometry: popup \(String(describing: g.popup)), choose \(String(describing: g.chooseButton)), dialog \(g.dialog)")
    screenshot("0-dialog")
    for k in 1 ... attempts {
        attempt(k, g)
    }
    finish()
}

func attempt(_ k: Int, _ g: Geometry) {
    log("===== attempt \(k)")
    let setterBefore = setterLog.get().count
    let chooseBefore = chooseCount.get()
    if variant.hasPrefix("button"), let button = g.chooseButton {
        click(CGPoint(x: button.midX, y: button.midY))
    } else if let popup = g.popup {
        var opened = false
        for _ in 0 ..< 3 where !opened {
            opened = openMenu(CGPoint(x: popup.midX, y: popup.midY))
            if !opened { Thread.sleep(forTimeInterval: 1) }
        }
        guard opened else {
            results.append("a\(k): menu never opened")
            screenshot("a\(k)-no-menu")
            return
        }
        Thread.sleep(forTimeInterval: 0.6)
        logWindows("menu open")
        let menuWindow = windows().first { $0.pid == getpid() && $0.layer >= 100 && $0.layer < 1000 }
        let estimate = menuWindow.map { CGRect(x: $0.bounds.minX + 12, y: $0.bounds.maxY - 28, width: $0.bounds.width - 24, height: 22) }
        log("menu window \(menuWindow.map { "\($0.bounds) L\($0.layer)" } ?? "none"); last item estimated at \(String(describing: estimate))")
        let item = axSearch(role: "AXMenuItem", names: ["Choose…"], timeLimit: 3) ?? estimate
        guard let item else {
            results.append("a\(k): no Choose… item")
            screenshot("a\(k)-no-item")
            key(53)
            return
        }
        log("Choose… at \(item)")
        screenshot("a\(k)-1-menu")
        let p = CGPoint(x: item.midX, y: item.midY)
        move(to: p)
        usleep(300_000)
        mouse(.leftMouseDown, p)
        usleep(60000)
        mouse(.leftMouseUp, p)
        log("clicked Choose… at \(p)")
    }
    let clicked = Date()
    var shown: Double?
    var tookLate = false
    var last = ""
    let limit = k == 1 ? firstWait : laterWait
    while Date().timeIntervalSince(clicked) < limit {
        usleep(100_000)
        let elapsed = Date().timeIntervalSince(clicked)
        let onScreen = panelOnScreen(g)
        let s = "setter+\(setterLog.get().count - setterBefore) choose+\(chooseCount.get() - chooseBefore) active \(panelActive.get()) visible \(panelVisible.get()) onScreen \(onScreen) menuOpen \(menuOpen.get())"
        if s != last {
            log(String(format: "state @%.1fs: ", elapsed) + s)
            last = s
        }
        if shown == nil, panelVisible.get() || onScreen {
            shown = elapsed
            Thread.sleep(forTimeInterval: 1)
            logWindows("panel up")
            screenshot("a\(k)-2-panel")
            break
        }
        if !tookLate, elapsed > 2 {
            tookLate = true
            screenshot("a\(k)-2-after-2s")
        }
    }
    if shown == nil {
        logWindows("no panel")
        screenshot("a\(k)-3-no-panel")
    }
    if panelActive.get() || shown != nil {
        key(53)
        if !waitFor(5, { !panelActive.get() }) {
            log("Escape didn't close the panel; cancelling it")
            _ = onMain { currentPanel?.cancel(nil) }
            _ = waitFor(5) { !panelActive.get() }
        }
    }
    Thread.sleep(forTimeInterval: 2)
    let r = "a\(k): setter+\(setterLog.get().count - setterBefore) choose+\(chooseCount.get() - chooseBefore) panel " + (shown.map { String(format: "%.1fs", $0) } ?? "NO") + " results \(panelResults.get())"
    log("RESULT " + r)
    results.append(r)
}

func dryRun() {
    Thread.sleep(forTimeInterval: 1.5)
    _ = onMain { Presenter.present() }
    Thread.sleep(forTimeInterval: 0.5)
    _ = waitFor(5) { dialogUp.get() }
    Thread.sleep(forTimeInterval: 1.5)
    logWindows("dry")
    let g = findGeometry()
    log("dry geometry: \(String(describing: g))")
    finish()
}
