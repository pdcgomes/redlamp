// Drives the Redlamp app itself, from outside it, to reproduce bug #356 on macOS 27: launches it
// on a photo, opens the Export dialog, and picks Export to → Choose… with real clicks, three
// times, watching for the folder panel's window.
//
// Build: swiftc -swift-version 5 -O -target arm64-apple-macos26.0 drive356.swift -o drive356
// Run:   drive356 --app Redlamp.app --photo photo.RW2 --out dir [--open key|toolbar|previous] [--attempts 3]

import AppKit
import ApplicationServices

let started = Date()
func log(_ s: String) {
    print(String(format: "[%7.3f] ", Date().timeIntervalSince(started)) + s)
    fflush(stdout)
}

var appPath = ""
var photo = ""
var outDir = "/tmp/drive356"
var opening = "key"
var attempts = 3
var firstWait = 15.0
var screenChoice = "main"
do {
    var it = CommandLine.arguments.dropFirst().makeIterator()
    while let a = it.next() {
        switch a {
        case "--app": appPath = it.next() ?? ""
        case "--photo": photo = it.next() ?? ""
        case "--out": outDir = it.next() ?? outDir
        case "--open": opening = it.next() ?? opening
        case "--attempts": attempts = Int(it.next() ?? "") ?? attempts
        case "--first-wait": firstWait = Double(it.next() ?? "") ?? firstWait
        case "--screen": screenChoice = it.next() ?? screenChoice
        default: break
        }
    }
}
try? FileManager.default.createDirectory(atPath: outDir, withIntermediateDirectories: true)

func waitFor(_ seconds: Double, every: UInt32 = 50000, _ cond: () -> Bool) -> Bool {
    let end = Date().addingTimeInterval(seconds)
    while Date() < end {
        if cond() { return true }
        usleep(every)
    }
    return cond()
}

func screenshot(_ name: String) {
    var count: UInt32 = 0
    CGGetActiveDisplayList(0, nil, &count)
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
    p.arguments = ["-x", "-t", "jpg"] + (1 ... max(1, Int(count))).map { "\(outDir)/\(name)-d\($0).jpg" }
    try? p.run()
    p.waitUntilExit()
}

// MARK: Windows

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

func describe(_ ws: [Win]) -> String {
    ws.map { "#\($0.number) \($0.owner)/'\($0.name)' L\($0.layer) \(Int($0.bounds.minX)),\(Int($0.bounds.minY)) \(Int($0.bounds.width))x\(Int($0.bounds.height))" }.joined(separator: "; ")
}

func appWindows(_ pid: Int32) -> [Win] {
    windows().filter { $0.pid == pid || $0.owner.localizedCaseInsensitiveContains("open and save") || $0.owner.localizedCaseInsensitiveContains("panel") }
}

// MARK: Events

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

func click(_ p: CGPoint) {
    move(to: p)
    usleep(150_000)
    mouse(.leftMouseDown, p)
    usleep(70000)
    mouse(.leftMouseUp, p)
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

// MARK: Accessibility

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

func axSearch(_ pid: Int32, role: String, names: [String], timeLimit: Double = 5) -> CGRect? {
    let app = AXUIElementCreateApplication(pid)
    AXUIElementSetMessagingTimeout(app, 2)
    var queue: [(AXUIElement, Int)] = [(app, 0)]
    let t = Date()
    var visited = 0
    while !queue.isEmpty, Date().timeIntervalSince(t) < timeLimit {
        let (el, depth) = queue.removeFirst()
        visited += 1
        let r = axString(el, kAXRoleAttribute)
        if r == role {
            let found = [kAXTitleAttribute, kAXValueAttribute, kAXDescriptionAttribute].compactMap { axString(el, $0) }
            if found.contains(where: names.contains), let frame = axFrame(el) {
                log("AX: \(role) \(found) at \(frame) (\(visited) elements)")
                return frame
            }
        }
        if depth < 22, r != "AXMenuBar" {
            queue.append(contentsOf: axChildren(el).map { ($0, depth + 1) })
        }
    }
    log("AX: no \(role) named \(names) (\(visited) elements)")
    return nil
}

func axWindowTitles(_ pid: Int32) -> [String] {
    let app = AXUIElementCreateApplication(pid)
    var v: CFTypeRef?
    guard AXUIElementCopyAttributeValue(app, kAXWindowsAttribute as CFString, &v) == .success, let ws = v as? [AXUIElement] else { return [] }
    return ws.map { (axString($0, kAXTitleAttribute) ?? "?") + "(" + (axString($0, kAXSubroleAttribute) ?? "") + ")" }
}

func frontmost(_ pid: Int32) {
    let app = AXUIElementCreateApplication(pid)
    let r = AXUIElementSetAttributeValue(app, kAXFrontmostAttribute as CFString, kCFBooleanTrue)
    log("AX frontmost: \(r.rawValue); frontmost app now \(NSWorkspace.shared.frontmostApplication?.localizedName ?? "?")")
}

// MARK: Launch

guard let bundle = Bundle(path: appPath), let bundleID = bundle.bundleIdentifier else {
    log("FAIL: no app at \(appPath)")
    exit(2)
}
log("app \(bundleID) \(bundle.infoDictionary?["CFBundleShortVersionString"] ?? "?") (\(bundle.infoDictionary?["CFBundleVersion"] ?? "?")), photo \(photo), open \(opening), macOS \(ProcessInfo.processInfo.operatingSystemVersionString)")
log("trusted: ax \(AXIsProcessTrusted()), postEvent \(CGPreflightPostEventAccess()), screenCapture \(CGPreflightScreenCaptureAccess())")
let open = Process()
open.executableURL = URL(fileURLWithPath: "/usr/bin/open")
open.arguments = ["-n", "-a", appPath, "--args", photo]
try open.run()
open.waitUntilExit()

var pid: Int32 = 0
_ = waitFor(20, every: 250_000) {
    pid = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first?.processIdentifier ?? 0
    if pid == 0 {
        let pgrep = Process()
        let pipe = Pipe()
        pgrep.executableURL = URL(fileURLWithPath: "/usr/bin/pgrep")
        pgrep.arguments = ["-n", "-x", bundle.infoDictionary?["CFBundleExecutable"] as? String ?? "Redlamp"]
        pgrep.standardOutput = pipe
        try? pgrep.run()
        pgrep.waitUntilExit()
        pid = Int32(String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0
    }
    return pid != 0
}
guard pid != 0 else {
    log("FAIL: the app didn't start")
    exit(2)
}
log("launched pid \(pid)")
let photoName = URL(fileURLWithPath: photo).lastPathComponent
let editorUp = waitFor(60, every: 500_000) { axWindowTitles(pid).contains { $0.hasPrefix(photoName) } }
log("editor \(editorUp ? "shows the photo" : "never showed the photo"): windows \(axWindowTitles(pid)); \(describe(appWindows(pid)))")
screenshot("0-launched")
guard editorUp else { exit(2) }
Thread.sleep(forTimeInterval: 4)
log("windows: \(axWindowTitles(pid))")
var ids = [CGDirectDisplayID](repeating: 0, count: 8)
var displayCount: UInt32 = 0
CGGetActiveDisplayList(8, &ids, &displayCount)
let displays = ids.prefix(Int(displayCount)).map { ($0, CGDisplayBounds($0), CGDisplayPixelsWide($0)) }
log("displays: main \(CGMainDisplayID()); " + displays.map { "\($0.0) \($0.1) \($0.2) px wide" }.joined(separator: "; "))
if screenChoice == "external", let external = displays.filter({ $0.0 != CGMainDisplayID() }).max(by: { $0.1.width < $1.1.width }) {
    let app = AXUIElementCreateApplication(pid)
    var v: CFTypeRef?
    if AXUIElementCopyAttributeValue(app, kAXWindowsAttribute as CFString, &v) == .success, let ws = v as? [AXUIElement],
       let editor = ws.first(where: { axString($0, kAXTitleAttribute)?.hasPrefix(photoName) == true }) {
        var point = CGPoint(x: external.1.minX + 60, y: external.1.minY + 60)
        let r = AXUIElementSetAttributeValue(editor, kAXPositionAttribute as CFString, AXValueCreate(.cgPoint, &point)!)
        Thread.sleep(forTimeInterval: 1)
        log("moved the editor to display \(external.0): \(r.rawValue), now at \(axFrame(editor).map { "\($0)" } ?? "?")")
    }
}
frontmost(pid)
Thread.sleep(forTimeInterval: 1)

// MARK: Open the dialog

let before = Set(appWindows(pid).map(\.number))
switch opening {
case "toolbar":
    if let r = axSearch(pid, role: "AXButton", names: ["Export"]) {
        click(CGPoint(x: r.midX, y: r.midY))
    }
case "previous":
    key(14, [.maskCommand, .maskShift, .maskAlternate])
default:
    key(14, [.maskCommand, .maskShift])
}
var sheet: Win?
_ = waitFor(10) {
    sheet = appWindows(pid).first { !before.contains($0.number) && $0.pid == pid && $0.layer == 0 && $0.bounds.width > 400 }
    return sheet != nil
}
guard let sheet else {
    log("FAIL: the Export dialog didn't open: \(describe(appWindows(pid)))")
    screenshot("0-no-dialog")
    exit(2)
}
log("dialog: #\(sheet.number) \(sheet.bounds)")
Thread.sleep(forTimeInterval: 2)
screenshot("0-dialog")
let shownNames = ["Same Folder as Original", "Edited"]
guard let popup = axSearch(pid, role: "AXPopUpButton", names: shownNames, timeLimit: 8) else {
    log("FAIL: no Export to pop-up")
    exit(2)
}

// MARK: Attempts

var results: [String] = []
for k in 1 ... attempts {
    log("===== attempt \(k)")
    var menu: Win?
    for _ in 0 ..< 3 where menu == nil {
        let p = CGPoint(x: popup.midX, y: popup.midY)
        move(to: p)
        usleep(150_000)
        mouse(.leftMouseDown, p)
        _ = waitFor(2, every: 20000) {
            menu = appWindows(pid).first { $0.pid == pid && $0.layer >= 100 && $0.layer < 1000 }
            return menu != nil
        }
        usleep(30000)
        mouse(.leftMouseUp, p)
        usleep(400_000)
        if menu != nil, !appWindows(pid).contains(where: { $0.number == menu!.number }) {
            log("the menu closed on release")
            menu = nil
        }
        if menu == nil { Thread.sleep(forTimeInterval: 1) }
    }
    guard let menu else {
        results.append("a\(k): menu never opened")
        screenshot("a\(k)-no-menu")
        continue
    }
    Thread.sleep(forTimeInterval: 0.5)
    log("menu: \(menu.bounds)")
    let item = axSearch(pid, role: "AXMenuItem", names: ["Choose…"], timeLimit: 3)
        ?? CGRect(x: menu.bounds.minX + 12, y: menu.bounds.maxY - 28, width: menu.bounds.width - 24, height: 22)
    screenshot("a\(k)-1-menu")
    let p = CGPoint(x: item.midX, y: item.midY)
    move(to: p)
    usleep(300_000)
    mouse(.leftMouseDown, p)
    usleep(60000)
    mouse(.leftMouseUp, p)
    log("clicked Choose… at \(p)")
    let clicked = Date()
    var panel: Win?
    var tookLate = false
    var last = ""
    while Date().timeIntervalSince(clicked) < (k == 1 ? firstWait : 10) {
        usleep(100_000)
        let ws = appWindows(pid)
        let d = describe(ws)
        if d != last {
            log(String(format: "@%.1fs windows: ", Date().timeIntervalSince(clicked)) + d)
            last = d
        }
        panel = ws.first { $0.number != sheet.number && $0.layer != 0 && $0.layer < 100 && $0.bounds.width > 300 && $0.bounds.height > 200 }
            ?? ws.first { $0.owner.localizedCaseInsensitiveContains("open and save") && $0.bounds.width > 300 }
        if panel != nil { break }
        if !tookLate, Date().timeIntervalSince(clicked) > 2 {
            tookLate = true
            screenshot("a\(k)-2-after-2s")
        }
    }
    let elapsed = Date().timeIntervalSince(clicked)
    if let panel {
        log(String(format: "PANEL after %.1fs: ", elapsed) + describe([panel]))
        Thread.sleep(forTimeInterval: 1)
        screenshot("a\(k)-3-panel")
        key(53)
        _ = waitFor(5) { !appWindows(pid).contains { $0.number == panel.number } }
        results.append(String(format: "a%d: panel after %.1fs", k, elapsed))
    } else {
        screenshot("a\(k)-3-no-panel")
        results.append("a\(k): NO panel")
    }
    Thread.sleep(forTimeInterval: 2)
}
log("SUMMARY real app, open \(opening): " + results.joined(separator: " | "))
key(53)
Thread.sleep(forTimeInterval: 1)
NSRunningApplication(processIdentifier: pid)?.forceTerminate()
exit(0)
