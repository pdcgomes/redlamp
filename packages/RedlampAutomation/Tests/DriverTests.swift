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

    @Test func `the driver's thread gets answers from the main thread`() async {
        let answer = await withCheckedContinuation { (continuation: CheckedContinuation<Int, Never>) in
            Thread.detachNewThread {
                let value = (try? MainThread.run { Thread.isMainThread ? 42 : 0 }) ?? -1
                continuation.resume(returning: value)
            }
        }
        #expect(answer == 42)
    }

    @Test func `the main thread's own calls run in place`() throws {
        #expect(try MainThread.run { 7 } == 7)
    }
}
