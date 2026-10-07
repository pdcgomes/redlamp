import AppKit
import RedlampDesign
import RedlampEngineAPI
import Testing
@testable import RedlampUI

/// The point curve's selected point takes a typed Input and Output (UX-28).
@MainActor
struct ToneCurveValuesTests {
    /// The view is kept with its fields: they reach it weakly, as the panel holds it in the app.
    private func pointValues() throws
        -> (EditorModel, ToneCurveState, input: ValueFieldView, output: ValueFieldView, view: PointValuesView) {
        let model = EditorModel(engine: StubEngine())
        model.setPointCurve([CurvePoint(x: 0, y: 0), CurvePoint(x: 0.5, y: 0.5), CurvePoint(x: 1, y: 1)])
        let state = ToneCurveState()
        let view = PointValuesView(model: model, state: state)
        let fields = allSubviews(of: view).compactMap { $0 as? ValueFieldView }
        try #require(fields.count == 2)
        return (model, state, fields[0], fields[1], view)
    }

    private func allSubviews(of view: NSView) -> [NSView] {
        view.subviews + view.subviews.flatMap(allSubviews)
    }

    @Test func `a typed Output moves the selected point`() throws {
        let (model, state, _, output, view) = try pointValues()
        defer { withExtendedLifetime(view) {} }
        state.selectedPoint = 1
        output.onCommit(204)
        #expect(abs(model.pointCurve[1].y - 0.8) < 1e-9)
        #expect(model.pointCurve[1].x == 0.5)
    }

    @Test func `a typed Input stays between the point's neighbours`() throws {
        let (model, state, input, _, view) = try pointValues()
        defer { withExtendedLifetime(view) {} }
        state.selectedPoint = 1
        input.onCommit(255)
        #expect(abs(model.pointCurve[1].x - 0.99) < 1e-9)
    }

    @Test func `the curve's end points keep their Input`() throws {
        let (model, state, input, output, view) = try pointValues()
        defer { withExtendedLifetime(view) {} }
        state.selectedPoint = 0
        input.onCommit(100)
        output.onCommit(51)
        #expect(model.pointCurve[0].x == 0)
        #expect(abs(model.pointCurve[0].y - 0.2) < 1e-9)
    }

    @Test func `with no point selected, nothing moves`() throws {
        let (model, _, input, output, view) = try pointValues()
        defer { withExtendedLifetime(view) {} }
        let before = model.pointCurve
        input.onCommit(100)
        output.onCommit(100)
        #expect(model.pointCurve == before)
    }
}
