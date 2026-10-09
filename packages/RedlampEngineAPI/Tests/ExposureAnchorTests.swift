import Foundation
import Testing
@testable import RedlampEngineAPI

/// Redlamp Reproduction's exposure anchor (CAM-28): each photo's own camera's, written when the
/// look arrives, never copied from another photo, and kept as a newer Redlamp wrote it.
struct ExposureAnchorTests {
    static let canon = ExposureAnchor(stops: 0.94, source: .target, camera: "Canon EOS R5")
    static let sony = ExposureAnchor.typical(for: "Sony ILCE-7RM5")

    static func reproduction(_ anchor: ExposureAnchor? = nil) -> EditRecipe {
        var recipe = EditRecipe()
        recipe.baseLook = BuiltInBaseLook.reproduction.reference
        recipe.exposureAnchor = anchor
        return recipe
    }

    @Test func `the look's arrival writes the photo's anchor and keeps the one it has`() {
        #expect(Self.reproduction().anchored(Self.canon).exposureAnchor == Self.canon)
        var recalibrated = Self.canon
        recalibrated.stops = 1.1
        #expect(Self.reproduction(Self.canon).anchored(recalibrated).exposureAnchor == Self.canon)
        #expect(Self.reproduction(Self.sony).anchored(Self.canon).exposureAnchor == Self.canon, "another camera's goes")
    }

    @Test func `other looks and photos that aren't raw have none`() {
        var color = Self.reproduction(Self.canon)
        color.baseLook = BuiltInBaseLook.color.reference
        #expect(color.anchored(Self.canon).exposureAnchor == nil)
        #expect(Self.reproduction(Self.canon).anchored(nil).exposureAnchor == nil)
    }

    @Test func `pasting the Base Look never copies the anchor`() {
        let pasted = EditRecipe().pasting(Self.reproduction(Self.canon), SettingsSelection(items: ["look.baseLook"]))
        #expect(pasted.baseLook.isReproduction)
        #expect(pasted.exposureAnchor == nil)
        #expect(pasted.anchored(Self.sony).exposureAnchor == Self.sony)
    }

    @Test func `it round-trips, keeping what a newer Redlamp wrote in it`() throws {
        let json = #"""
        {"baseLook":{"id":"redlamp/base/reproduction"},
         "exposureAnchor":{"stops":0.94,"source":"table","camera":"Canon EOS R5","iso":100}}
        """#
        let recipe = try JSONDecoder().decode(EditRecipe.self, from: Data(json.utf8))
        #expect(recipe.baseLook.isReproduction)
        #expect(recipe.exposureAnchor?.stops == 0.94 && recipe.exposureAnchor?.camera == "Canon EOS R5")
        let written = try JSONDecoder().decode(JSONValue.self, from: JSONEncoder().encode(recipe))
        guard case let .object(fields) = written, case let .object(anchor)? = fields["exposureAnchor"] else {
            Issue.record("no exposureAnchor in \(written)")
            return
        }
        #expect(anchor["source"] == .string("table"))
        #expect(anchor["iso"] == .number(100))
        #expect(try JSONDecoder().decode(EditRecipe.self, from: JSONEncoder().encode(recipe)) == recipe)
    }

    @Test func `an edit without one writes none and stays pristine`() throws {
        let written = try JSONDecoder().decode(JSONValue.self, from: JSONEncoder().encode(EditRecipe()))
        guard case let .object(fields) = written else { return }
        #expect(fields["exposureAnchor"] == nil)
        var anchored = EditRecipe()
        anchored.exposureAnchor = Self.canon
        #expect(EditRecipe().isPristine && !anchored.isPristine)
    }
}
