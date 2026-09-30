import AppKit
import RedlampDesign
import RedlampEngineAPI
import Testing

/// ⌘-scroll over a slider adjusts it; plain scrolling leaves it for the panel column (UX-02).
@MainActor
struct SliderScrollTests {
    final class Editor: ParameterEditing {
        var values: [ParameterID: Double] = [:]
        var edits = 0
        var focusedParameter: ParameterID?
        var optionKeyHeld: Bool {
            false
        }

        func sliderValue(_ parameter: ParameterID) -> Double {
            values[parameter] ?? parameter.spec.defaultValue
        }

        func setSliderValue(_ parameter: ParameterID, _ value: Double) {
            values[parameter] = value
        }

        func isEdited(_ parameter: ParameterID) -> Bool {
            values[parameter] != nil
        }

        func resetSlider(_ parameter: ParameterID) {
            values[parameter] = nil
        }

        func resetParameters(_ parameters: [ParameterID], name _: String) {
            parameters.forEach { values[$0] = nil }
        }

        func beginEdit(_: ParameterID?) {
            edits += 1
        }

        func endEdit(name _: String?) {}
        func setTemporaryClipping(_: Bool) {}
    }

    private func scroll(lines: Int32, flags: CGEventFlags) throws -> NSEvent {
        let event = try #require(CGEvent(
            scrollWheelEvent2Source: nil, units: .line, wheelCount: 1, wheel1: lines, wheel2: 0, wheel3: 0,
        ))
        event.flags = flags
        return try #require(NSEvent(cgEvent: event))
    }

    @Test func `command-scroll adjusts the slider under the pointer`() throws {
        let editor = Editor()
        let row = SliderRowView(parameter: .contrast, editor: editor)
        let event = try scroll(lines: 3, flags: .maskCommand)
        row.scrollWheel(with: event)
        let expected = (event.isDirectionInvertedFromDevice ? -3 : 3) * ParameterID.contrast.spec.step
        #expect(editor.values[.contrast] == expected)
        #expect(editor.focusedParameter == .contrast)
        #expect(editor.edits == 1)
    }

    @Test func `plain scrolling leaves the slider alone`() throws {
        let editor = Editor()
        let row = SliderRowView(parameter: .contrast, editor: editor)
        try row.scrollWheel(with: scroll(lines: 3, flags: []))
        #expect(editor.values.isEmpty)
    }
}
