import AppKit
import Foundation
import Observation
import RedlampEngineAPI
import SwiftUI
import Testing
@testable import RedlampAutomation
@_spi(Harness) import RedlampUI

/// The driver's own parts: the events it makes, the names it looks for, what it writes.
@MainActor
struct DriverTests {
    init() {
        _ = NSApplication.shared
    }

    @Test func `a shifted shortcut types the shifted character over the unshifted key`() throws {
        let event = try Keyboard.event(.char("c", shift: true, command: true))
        #expect(event.type == .keyDown)
        #expect(event.charactersIgnoringModifiers == "c")
        #expect(event.characters == "C")
        #expect(event.modifierFlags.contains(.shift))
        #expect(event.modifierFlags.contains(.command))
        #expect(!event.modifierFlags.contains(.option))
    }

    @Test func `named keys have their own key codes`() throws {
        #expect(try Keyboard.event(KeyCombo(.escape)).keyCode == 53)
        #expect(try Keyboard.event(KeyCombo(.tab)).keyCode == 48)
        #expect(try Keyboard.event(KeyCombo(.left)).keyCode == 123)
        #expect(try Keyboard.event(KeyCombo(.function(6))).keyCode == 97)
    }

    @Test func `targets name the identifiers the views carry`() {
        #expect(Target.slider(.exposure).identifier == "slider.basic.exposure.track")
        #expect(Target.sliderLabel(.exposure).identifier == "slider.basic.exposure.label")
        #expect(Target.panelHeader(.basic).identifier == "panel.basic.header")
        #expect(Target.tool(.masking).identifier == "tool.masking")
        #expect(Target.histogram(.whites).identifier == "histogram.basic.whites")
        #expect(Target.filmstrip("DSC_0750.NEF").identifier == "filmstrip.DSC_0750.NEF")
    }

    @Test func `a planned action's menu item says when it arrives`() {
        let title = Menus.title(of: .virtualCopy)
        #expect(title.hasPrefix(ShortcutAction.virtualCopy.title))
        #expect(title.contains(ShortcutAction.virtualCopy.plannedPhase ?? "-"))
        #expect(Menus.title(of: .export) == ShortcutAction.export.title)
    }

    @Test func `claims are named as the coverage report names them`() {
        #expect(Claim.action(.beforeAfter).description == "action.beforeAfter")
        #expect(Claim.parameter(.exposure).description == "parameter.basic.exposure")
        #expect(Claim.feature("masking.sky").description == "feature.masking.sky")
    }

    @Test func `the recorder writes one JSON object per line, and keeps what was there`() throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: "recorder-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let first = Recorder(directory: directory, launch: "main")
        first.currentScenario = "smoke.export"
        first.write("step", ["name": "export", "status": "passed"])
        let second = Recorder(directory: directory, launch: "main")
        second.write("launch-end")
        second.cover(.action(.export), via: .menu)
        second.writeCoverage(menuItems: ["File › Export…"])

        let lines = try String(contentsOf: directory.appending(path: "events-main.jsonl"), encoding: .utf8)
            .split(separator: "\n")
        #expect(lines.count == 2)
        let step = try JSONSerialization.jsonObject(with: Data(lines[0].utf8)) as? [String: Any]
        #expect(step?["event"] as? String == "step")
        #expect(step?["scenario"] as? String == "smoke.export")
        let coverage = try JSONSerialization.jsonObject(
            with: Data(contentsOf: directory.appending(path: "coverage-main.json")),
        ) as? [String: Any]
        #expect((coverage?["claims"] as? [String: [String]])?["action.export"] == ["menu"])
    }

    @Test func `a failure's record is named for its scenario and step`() {
        #expect(FailureRecord
            .fileName("smoke.actions-by-key.openFolder by key") == "smoke.actions-by-key.openFolder-by-key")
        #expect(FailureRecord
            .fileName("smoke.photos-open.open Bracket/A.NEF") == "smoke.photos-open.open-Bracket-A.NEF")
    }

    @Test func `a press names what it found, up to the first view that carries an identifier`() {
        let panel = NSView()
        panel.setAccessibilityIdentifier("panel.basic")
        let row = NSView()
        let track = NSView()
        track.setAccessibilityIdentifier("slider.basic.exposure.track")
        let knob = NSView()
        panel.addSubview(row)
        row.addSubview(track)
        track.addSubview(knob)
        #expect(Views.ancestry(knob) == ["NSView", "NSView slider.basic.exposure.track"])
        #expect(Views.ancestry(track) == ["NSView slider.basic.exposure.track", "NSView", "NSView panel.basic"])
        #expect(Views.ancestry(nil) == ["nothing"])
    }

    @Test func `a view left in place inside a transparent one isn't on screen`() {
        let window = NSWindow(
            contentRect: CGRect(x: 0, y: 0, width: 200, height: 100), styleMask: [.borderless], backing: .buffered,
            defer: false,
        )
        window.isReleasedWhenClosed = false
        let strip = NSView(frame: CGRect(x: 0, y: 0, width: 200, height: 50))
        let cell = NSView(frame: CGRect(x: 10, y: 10, width: 40, height: 30))
        cell.setAccessibilityIdentifier("filmstrip.A.ARW")
        strip.addSubview(cell)
        window.contentView?.addSubview(strip)
        #expect(Views.find("filmstrip.A.ARW", in: window) != nil)
        strip.alphaValue = 0
        #expect(Views.find("filmstrip.A.ARW", in: window) == nil)
    }

    /// The Masks panel's controls are SwiftUI's, hosted in AppKit, and the run doesn't take the
    /// app's focus: a tap finds each by the identifier behind it and reaches it in a window that
    /// isn't key. SwiftUI's gestures (a row's tap) need a key window, as the canvas's do.
    @Test func `a tap reaches SwiftUI's buttons, checkbox and menu in a window that isn't key`() async throws {
        let state = TapState()
        let window = NSWindow(
            contentRect: CGRect(x: 200, y: 200, width: 320, height: 200), styleMask: [.titled], backing: .buffered,
            defer: false,
        )
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: TapSpecimen(state: state))
        window.orderFront(nil)
        defer { window.orderOut(nil) }
        func settle() async throws {
            for _ in 0 ..< 10 {
                window.layoutIfNeeded()
                try await Task.sleep(for: .milliseconds(10))
            }
        }
        func tap(_ identifier: String) async throws {
            let frame = try #require(Views.find(identifier, in: window), "no \(identifier)")
            #expect(window.contentView?.bounds.contains(NSPoint(x: frame.midX, y: frame.midY)) == true)
            Views.tap(
                at: NSPoint(x: frame.midX, y: frame.midY),
                inWindow: window.windowNumber,
                clicks: 1,
                modifiers: [],
            )
            try await settle()
        }
        try await settle()
        #expect(!window.isKeyWindow)

        try await tap("test.button")
        #expect(state.presses == ["button"])
        try await tap("test.plain")
        #expect(state.presses == ["button", "plain"])
        try await tap("test.checkbox")
        #expect(state.checked, "the checkbox tracks the press and reads the queued release")

        let opened = OpenedMenu()
        // As the driver chooses, from a block the menu's tracking runs rather than inside the
        // notification that it started.
        opened.watch { menu in
            nonisolated(unsafe) let menu = menu
            CFRunLoopPerformBlock(CFRunLoopGetMain(), CFRunLoopMode.commonModes.rawValue) {
                MainActor.assumeIsolated {
                    if let index = menu.items.firstIndex(where: { $0.title == "Second" }) {
                        menu.performActionForItem(at: index)
                    }
                    menu.cancelTracking()
                }
            }
            CFRunLoopWakeUp(CFRunLoopGetMain())
        }
        defer { opened.stop() }
        try await tap("test.menu")
        #expect(opened.menu != nil, "the menu opened")
        #expect(state.presses.last == "Second")
    }

    /// The Masks panel's picker opens in a popover, which takes no clicks until it has finished
    /// opening, though its window is up: the driver finds it from then.
    @Test func `a tap reaches a SwiftUI button in a popover once it has opened`() async throws {
        Views.watchPopovers()
        let state = TapState()
        let window = NSWindow(
            contentRect: CGRect(x: 200, y: 200, width: 320, height: 200), styleMask: [.titled], backing: .buffered,
            defer: false,
        )
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: PopoverSpecimen(state: state))
        window.orderFront(nil)
        defer { window.orderOut(nil) }
        func settle() async throws {
            for _ in 0 ..< 10 {
                window.layoutIfNeeded()
                try await Task.sleep(for: .milliseconds(10))
            }
        }
        func tap(_ identifier: String) throws {
            let place = try #require(Views.place(of: identifier), "no \(identifier)")
            Views.tap(
                at: NSPoint(x: place.frame.midX, y: place.frame.midY), inWindow: place.window, clicks: 1, modifiers: [],
            )
        }
        try await settle()
        let open = try #require(Views.find("test.open", in: window))
        Views.tap(at: NSPoint(x: open.midX, y: open.midY), inWindow: window.windowNumber, clicks: 1, modifiers: [])
        for _ in 0 ..< 300 where Views.popoverWindow == nil {
            try await Task.sleep(for: .milliseconds(10))
        }
        let popover = try #require(Views.popoverWindow, "the popover didn't finish opening")
        #expect(!popover.isKeyWindow)
        try tap("test.inside")
        try await settle()
        #expect(state.presses == ["inside"])
        #expect(Views.popoverWindow == nil, "a closing popover isn't one to click in")
    }

    @Test func `holding a modifier makes the event the app's flags handling reads`() throws {
        let event = try Keyboard.flags(.option)
        #expect(event.type == .flagsChanged)
        #expect(event.modifierFlags.contains(.option))
        #expect(try Keyboard.flags([]).modifierFlags.intersection(.deviceIndependentFlagsMask).isEmpty)
    }

    @Test func `the first responder names the field being typed in, not its field editor`() throws {
        let window = NSWindow(
            contentRect: CGRect(x: 0, y: 0, width: 200, height: 60), styleMask: [.titled], backing: .buffered,
            defer: false,
        )
        let field = NSTextField(frame: CGRect(x: 10, y: 10, width: 120, height: 24))
        field.setAccessibilityIdentifier("slider.basic.exposure.value")
        window.contentView?.addSubview(field)
        #expect(window.makeFirstResponder(field))
        let responder = try #require(window.firstResponder)
        #expect(Views.describe(responder) == "the field editor of NSTextField slider.basic.exposure.value")
    }

    @Test func `a window's snapshot draws its views, and leaves out those in a transparent view`() throws {
        let window = NSWindow(
            contentRect: CGRect(x: 0, y: 0, width: 200, height: 100), styleMask: [.borderless], backing: .buffered,
            defer: false,
        )
        window.isReleasedWhenClosed = false
        let panel = NSView(frame: CGRect(x: 0, y: 0, width: 100, height: 100))
        panel.wantsLayer = true
        panel.layer?.backgroundColor = NSColor.red.cgColor
        let module = NSView(frame: CGRect(x: 100, y: 0, width: 100, height: 100))
        module.alphaValue = 0
        let inModule = NSView(frame: module.bounds)
        module.addSubview(inModule)
        window.contentView?.addSubview(panel)
        window.contentView?.addSubview(module)
        window.orderFront(nil)
        defer { window.orderOut(nil) }
        #expect(panel.isDrawn)
        #expect(!inModule.isDrawn)

        let url = FileManager.default.temporaryDirectory.appending(path: "snapshot-\(UUID().uuidString).png")
        defer { try? FileManager.default.removeItem(at: url) }
        #expect(Snapshot.capture(window, to: url))
        let image = try #require(NSBitmapImageRep(data: Data(contentsOf: url)))
        let color = try #require(image.colorAt(x: image.pixelsWide / 4, y: image.pixelsHigh / 2)?
            .usingColorSpace(.sRGB))
        // The screen's colour space shifts it, but red dominates.
        #expect(color.redComponent > color.greenComponent + 0.4 && color.redComponent > color.blueComponent + 0.4)
    }

    @Test func `the driver's thread gets answers from the main thread`() async {
        let answer = await withCheckedContinuation { (continuation: CheckedContinuation<Int, Never>) in
            Thread.detachNewThread {
                let value = (try? MainThread.run { Thread.isMainThread ? 42 : 0 }) ?? -1
                continuation.resume(returning: value)
            }
        }
        #expect(answer == 42)
    }

    @Test func `the driver waits out a stall in system code the run knows of, and no other`() async {
        @Sendable func answer() async -> Int {
            await withCheckedContinuation { continuation in
                Thread.detachNewThread {
                    continuation.resume(returning: (try? MainThread.run(timeout: 0.25) { 7 }) ?? -1)
                }
            }
        }
        defer { MainThread.isInKnownStall = nil }
        MainThread.isInKnownStall = { true }
        async let known = answer()
        stall(0.6)
        #expect(await known == 7)
        MainThread.isInKnownStall = { false }
        async let other = answer()
        stall(0.6)
        #expect(await other == -1)
    }

    private func stall(_ seconds: Double) {
        Thread.sleep(forTimeInterval: seconds)
    }

    @Test func `the main thread's own calls run in place`() throws {
        #expect(try MainThread.run { 7 } == 7)
    }
}

@MainActor @Observable
private final class TapState {
    var presses: [String] = []
    var checked = false
    var open = false
}

/// A button that opens a popover, as New Mask opens its picker, with a tile-like button in it.
private struct PopoverSpecimen: View {
    @Bindable var state: TapState

    var body: some View {
        Button("Open") { state.open = true }
            .controlSize(.small)
            .automationIdentifier("test.open")
            .popover(isPresented: $state.open, arrowEdge: .leading) {
                Button {
                    state.presses.append("inside")
                    state.open = false
                } label: {
                    Image(systemName: "circle").frame(width: 60, height: 60)
                }
                .buttonStyle(.plain)
                .automationIdentifier("test.inside")
                .padding(20)
            }
            .padding(40)
    }
}

/// The kinds of SwiftUI control the Masks panel has, each with an identifier.
private struct TapSpecimen: View {
    @Bindable var state: TapState

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Button("Press") { state.presses.append("button") }
                .controlSize(.small)
                .automationIdentifier("test.button")
            Button {
                state.presses.append("plain")
            } label: {
                Image(systemName: "eye")
            }
            .buttonStyle(.plain)
            .automationIdentifier("test.plain")
            Toggle("Check", isOn: $state.checked)
                .toggleStyle(.checkbox)
                .automationIdentifier("test.checkbox")
            Menu {
                Button("First") { state.presses.append("First") }
                Button("Second") { state.presses.append("Second") }
            } label: {
                Image(systemName: "ellipsis.circle")
            }
            .menuStyle(.button)
            .buttonStyle(.plain)
            .menuIndicator(.hidden)
            .fixedSize()
            .automationIdentifier("test.menu")
        }
        .padding(20)
        .frame(width: 320, alignment: .leading)
    }
}
