import AppKit
import RedlampDesign
import RedlampEngineAPI
import Testing
@testable import RedlampUI

/// A row of labelled values keeps a gap between each value and the next label, so a wheel's
/// Hue 30 and Saturation 10 don't read "30S" (UX-28).
@MainActor
struct LabelledValuesViewTests {
    private func allSubviews(of view: NSView) -> [NSView] {
        view.subviews + view.subviews.flatMap(allSubviews)
    }

    private func layOut(_ view: NSView) {
        view.layout()
        view.subviews.forEach(layOut)
    }

    /// The number is drawn right-aligned, `trailingInset` in from the field's right edge.
    private func textEnd(of field: ValueFieldView) -> CGFloat {
        field.frame.maxX - field.trailingInset
    }

    @Test func `each 3-way wheel's hue ends a gap before the S label`() throws {
        let wheels = ThreeWayWheelsView(model: EditorModel(engine: StubEngine()))
        wheels.frame = CGRect(x: 0, y: 0, width: 280, height: wheels.height(forWidth: 280))
        layOut(wheels)
        let rows = allSubviews(of: wheels).compactMap { $0 as? LabelledValuesView }
        try #require(rows.count == 3)
        for row in rows {
            #expect(row.columns[1].minX - textEnd(of: row.fields[0]) >= LabelledValuesView.columnGap)
        }
    }

    @Test func `the selected point's Input ends a gap before the Output label`() throws {
        let view = PointValuesView(model: EditorModel(engine: StubEngine()), state: ToneCurveState())
        view.frame = CGRect(x: 0, y: 0, width: 280, height: Metrics.rowHeight)
        layOut(view)
        let row = try #require(allSubviews(of: view).compactMap { $0 as? LabelledValuesView }.first)
        #expect(row.columns[1].minX - textEnd(of: row.fields[0]) >= LabelledValuesView.columnGap)
    }
}
