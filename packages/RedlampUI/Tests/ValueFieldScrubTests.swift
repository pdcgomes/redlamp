import AppKit
import RedlampDesign
import RedlampEngineAPI
import Testing

/// A slider's number scrubs when dragged and types when clicked (UX-29).
@MainActor
struct ValueFieldScrubTests {
    @MainActor final class Recorder {
        var begins = 0
        var changes: [Double] = []
        var ends = 0
        var commits: [Double] = []

        func attach(to field: ValueFieldView) {
            field.onBegin = { self.begins += 1 }
            field.onChange = { self.changes.append($0) }
            field.onEnd = { self.ends += 1 }
            field.onCommit = { self.commits.append($0) }
        }
    }

    private func mouse(_ type: NSEvent.EventType, x: CGFloat, flags: NSEvent.ModifierFlags = []) throws -> NSEvent {
        try #require(NSEvent.mouseEvent(
            with: type, location: CGPoint(x: x, y: 10), modifierFlags: flags, timestamp: 0,
            windowNumber: 0, context: nil, eventNumber: 0, clickCount: 1, pressure: 1,
        ))
    }

    private func field(_ parameter: ParameterID, value: Double) -> (ValueFieldView, Recorder) {
        let field = ValueFieldView(spec: parameter.spec, value: value)
        field.frame = CGRect(x: 0, y: 0, width: 48, height: 20)
        let recorder = Recorder()
        recorder.attach(to: field)
        return (field, recorder)
    }

    private func drag(_ field: ValueFieldView, by distance: CGFloat, flags: NSEvent.ModifierFlags = []) throws {
        try field.mouseDown(with: mouse(.leftMouseDown, x: 10))
        try field.mouseDragged(with: mouse(.leftMouseDragged, x: 10 + distance, flags: flags))
        try field.mouseUp(with: mouse(.leftMouseUp, x: 10 + distance))
    }

    @Test func `a drag scrubs across the range in the scrub span`() throws {
        let (field, recorder) = field(.contrast, value: 0)
        try drag(field, by: ValueFieldView.scrubSpan / 10)
        #expect(recorder.begins == 1)
        #expect(recorder.changes == [20])
        #expect(recorder.ends == 1)
        #expect(recorder.commits.isEmpty)
    }

    @Test func `Shift scrubs a tenth as far`() throws {
        let (field, recorder) = field(.contrast, value: 0)
        try drag(field, by: ValueFieldView.scrubSpan / 10, flags: .shift)
        #expect(recorder.changes == [2])
    }

    @Test func `Temp scrubs evenly in mireds, as its track moves`() throws {
        let spec = ParameterID.temperature.spec
        let (field, recorder) = field(.temperature, value: 5500)
        try drag(field, by: ValueFieldView.scrubSpan / 10)
        let expected = spec.quantize(spec.value(atPosition: spec.position(for: 5500) + 0.1))
        #expect(recorder.changes == [expected])
    }

    @Test func `a press that hardly moves types instead of scrubbing`() throws {
        let (field, recorder) = field(.contrast, value: 10)
        try drag(field, by: ValueFieldView.scrubThreshold - 1)
        #expect(recorder.begins == 0)
        #expect(recorder.changes.isEmpty)
        #expect(field.subviews.contains { $0 is NSTextField })
    }

    @Test func `a disabled number neither scrubs nor types`() throws {
        let (field, recorder) = field(.contrast, value: 0)
        field.isEnabled = false
        try drag(field, by: 100)
        try drag(field, by: 0)
        #expect(recorder.changes.isEmpty)
        #expect(!field.subviews.contains { $0 is NSTextField })
    }

    @Test func `scrubbing a slider row's number is one edit`() throws {
        let editor = SliderScrollTests.Editor()
        let row = SliderRowView(parameter: .contrast, editor: editor)
        row.frame = CGRect(x: 0, y: 0, width: 280, height: Metrics.rowHeight)
        row.layout()
        let field = try #require(row.subviews.compactMap { $0 as? ValueFieldView }.first)
        try field.mouseDown(with: mouse(.leftMouseDown, x: 10))
        for step in 1 ... 5 {
            try field.mouseDragged(with: mouse(.leftMouseDragged, x: 10 + CGFloat(step) * 10))
        }
        try field.mouseUp(with: mouse(.leftMouseUp, x: 60))
        #expect(editor.values[.contrast] == 20)
        #expect(editor.edits == 1)
        #expect(editor.focusedParameter == .contrast)
    }

    @Test func `a field spec of the interface's own formats, clamps and takes arithmetic`() {
        let spec = FieldSpec(range: 0 ... 100, unit: "%")
        #expect(spec.formatted(40) == "40%")
        #expect(spec.parse("x+5", current: 40) == 45)
        #expect(spec.parse("150%", current: nil) == 100)
        #expect(spec.parse("abc", current: nil) == nil)
        #expect(spec.quantize(12.6) == 13)
    }
}
