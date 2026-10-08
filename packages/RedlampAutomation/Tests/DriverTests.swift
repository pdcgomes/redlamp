import AppKit
import Foundation
import RedlampEngineAPI
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
