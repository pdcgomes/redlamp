import AppKit
import SwiftUI
import Testing
@testable import RedlampUI

@Observable
private final class Prompt {
    var text = "Name"
}

/// Redlamp draws no focus rings (`FocusRings`): whatever takes focus in the key window loses its
/// ring, and keeps it off while it has focus. AppKit draws rings only in a key window, which a
/// test can't count on having, so these read the ring each view would draw.
@MainActor @Suite(.serialized)
struct FocusRingsTests {
    private struct Controls: View {
        let prompt: Prompt
        @State private var name = ""
        @State private var secret = ""
        @State private var notes = ""
        @State private var on = false
        @State private var amount = 0.5
        @State private var choice = 0
        @State private var row: Int?

        var body: some View {
            VStack {
                TextField(prompt.text, text: $name)
                SecureField("Password", text: $secret)
                Toggle("Include", isOn: $on)
                Slider(value: $amount)
                Picker("Format", selection: $choice) { Text("JPEG").tag(0); Text("TIFF").tag(1) }
                Picker("Size", selection: $choice) { Text("Full").tag(0); Text("Half").tag(1) }.pickerStyle(.segmented)
                List(0 ..< 3, id: \.self, selection: $row) { Text("Photo \($0)") }.frame(height: 80)
                TextEditor(text: $notes).frame(height: 40)
            }
            .padding()
            .frame(width: 320)
            .focusEffectDisabled()
        }
    }

    private func window(_ content: NSView) -> NSWindow {
        _ = NSApplication.shared
        let window = NSWindow(
            contentRect: CGRect(x: 200, y: 200, width: 360, height: 480),
            styleMask: [.titled], backing: .buffered, defer: false,
        )
        window.isReleasedWhenClosed = false
        window.contentView = content
        return window
    }

    private func settle(_ window: NSWindow) async throws {
        for _ in 0 ..< 10 {
            window.layoutIfNeeded()
            try await Task.sleep(for: .milliseconds(10))
        }
    }

    private static func views<T: NSView>(_: T.Type, in view: NSView?) -> [T] {
        guard let view else { return [] }
        return ((view as? T).map { [$0] } ?? []) + view.subviews.flatMap { views(T.self, in: $0) }
    }

    @Test func `an AppKit control that takes focus draws no ring`() {
        let field = NSTextField(string: "")
        let controls: [NSControl] = [
            field,
            NSSearchField(),
            NSButton(checkboxWithTitle: "Include", target: nil, action: nil),
            NSPopUpButton(),
            NSSlider(),
            NSSegmentedControl(labels: ["Full", "Half"], trackingMode: .selectOne, target: nil, action: nil),
        ]
        let window = window(NSStackView(views: controls))
        FocusRings.watch(window)
        // Buttons, pop-ups and sliders take focus only with keyboard navigation on; text fields always do.
        #expect(field.acceptsFirstResponder)
        for control in controls where control.acceptsFirstResponder {
            #expect(window.makeFirstResponder(control))
            #expect(FocusRings.ringOwner(of: window.firstResponder) === control)
            #expect(control.focusRingType == .none, "\(type(of: control))")
        }
    }

    @Test func `a SwiftUI text field draws no ring as it takes focus, is typed in and updates`() async throws {
        let prompt = Prompt()
        let hosting = NSHostingView(rootView: Controls(prompt: prompt))
        let window = window(hosting)
        try await settle(window)
        FocusRings.watch(window)
        let field = try #require(Self.views(NSTextField.self, in: hosting).first {
            $0.isEditable && !($0 is NSSecureTextField)
        })

        #expect(window.makeFirstResponder(field))
        try await settle(window)
        let editor = try #require(window.firstResponder as? NSTextView)
        #expect(FocusRings.ringOwner(of: editor) === field)
        #expect(field.focusRingType == .none)

        editor.insertText("Kodachrome", replacementRange: NSRange(location: NSNotFound, length: 0))
        prompt.text = "Film"
        try await settle(window)
        #expect(field.focusRingType == .none)
    }

    @Test func `every SwiftUI control that takes focus draws no ring`() async throws {
        let hosting = NSHostingView(rootView: Controls(prompt: Prompt()))
        let window = window(hosting)
        try await settle(window)
        FocusRings.watch(window)
        let focusable = Self.views(NSView.self, in: hosting).filter(\.acceptsFirstResponder)
        // The text fields, the list and the text editor take focus with keyboard navigation off too.
        #expect(focusable.count >= 4)
        for view in focusable {
            window.makeFirstResponder(view)
            try await settle(window)
            let owner = try #require(FocusRings.ringOwner(of: window.firstResponder))
            #expect(owner.focusRingType == .none, "\(type(of: owner))")
        }
    }

    @Test func `a window is followed once it becomes key`() {
        let field = NSTextField(string: "")
        let window = window(NSStackView(views: [field]))
        FocusRings.removeEverywhere()
        NotificationCenter.default.post(name: NSWindow.didBecomeKeyNotification, object: window)

        #expect(window.makeFirstResponder(field))
        #expect(field.focusRingType == .none)
    }
}
