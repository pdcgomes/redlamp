import Foundation
import Testing
@testable import RedlampEngineAPI

struct SettingsSelectionTests {
    /// Every parameter of the global edit is on exactly one line of the checklist; per-mask
    /// adjustments are on none (they travel with their mask).
    @Test func `the checklist covers every parameter once`() {
        let listed = SettingsGroup.allItems.flatMap(\.parameters)
        #expect(Set(listed).count == listed.count, "a parameter on two lines")
        let global = ParameterID.allCases.filter { !$0.isMaskScoped }
        #expect(Set(listed) == Set(global), "missing: \(Set(global).subtracting(listed))")
        #expect(Set(SettingsGroup.allItems.flatMap(\.fields)) == Set(EditField.allCases))
        #expect(Set(SettingsGroup.allItems.map(\.id)).count == SettingsGroup.allItems.count)
    }

    @Test func `the first choice leaves out a photo's own framing and spots`() {
        let off = SettingsGroup.allItems.filter { !SettingsSelection.default.includes($0) }.map(\.id)
        #expect(Set(off) == ["lens.manual", "transform", "remove.spots", "crop.frame", "crop.orientation"])
        #expect(SettingsSelection.default.masks)
    }

    /// A ticked item takes the source's value, its default included; an unticked one keeps the
    /// target's.
    @Test func `pasting takes ticked items and resets them where the source left them alone`() {
        var source = EditRecipe()
        source[.exposure] = 1
        source.treatment = .blackAndWhite
        var target = EditRecipe()
        target[.contrast] = 30
        target[.clarity] = 20
        target[.transformVertical] = 10
        let selection = SettingsSelection(items: ["basic.exposure", "basic.contrast", "look.treatment"])
        let pasted = target.pasting(source, selection)
        #expect(pasted[.exposure] == 1)
        #expect(pasted[.contrast] == 0, "the source's untouched contrast resets the target's")
        #expect(pasted.treatment == .blackAndWhite)
        #expect(pasted[.clarity] == 20, "unticked: the target's")
        #expect(pasted[.transformVertical] == 10)
    }

    @Test func `fields travel with their item`() {
        var source = EditRecipe()
        source.pointCurve = [CurvePoint(x: 0, y: 0.1), CurvePoint(x: 1, y: 0.9)]
        source.crop = CropRect(left: 0.1, top: 0.1, right: 0.6, bottom: 0.6)
        source[.cropAngle] = 3
        source.processVersion = 3
        let target = EditRecipe()
        let defaults = target.pasting(source, .default)
        #expect(defaults.pointCurve == source.pointCurve)
        #expect(defaults.crop.isFull && defaults[.cropAngle] == 0, "crop is off the first time")
        #expect(defaults.processVersion == 3)
        let everything = target.pasting(source, .everything)
        #expect(everything.crop == source.crop && everything[.cropAngle] == 3)
    }

    /// The target keeps its own masks; a mask pasted again replaces itself, so syncing twice
    /// changes nothing.
    @Test func `masks merge by identity`() {
        let sky = MaskLayer(name: "Sky", components: [])
        let subject = MaskLayer(name: "Subject", components: [])
        var source = EditRecipe()
        source.masks = [sky, subject]
        var target = EditRecipe()
        let own = MaskLayer(name: "Own", components: [])
        target.masks = [own]
        let once = target.pasting(source, .default)
        #expect(once.masks.map(\.name) == ["Own", "Sky", "Subject"])
        source.masks[0].amount = 50
        let twice = once.pasting(source, .default)
        #expect(twice.masks.map(\.name) == ["Own", "Sky", "Subject"])
        #expect(twice.masks[1].amount == 50)
        var leftOut = SettingsSelection.default
        leftOut.excludedMasks = [subject.id]
        #expect(target.pasting(source, leftOut).masks.map(\.name) == ["Own", "Sky"])
        #expect(target.pasting(source, .nothing).masks.map(\.name) == ["Own"])
        #expect(EditRecipe.pastedMasks(from: source, leftOut) == [sky.id])
    }

    @Test func `masks stop at the layer limit`() {
        var source = EditRecipe()
        source.masks = (0 ..< 4).map { MaskLayer(name: "S\($0)", components: []) }
        var target = EditRecipe()
        target.masks = (0 ..< MaskLayer.maximumLayers - 2).map { MaskLayer(name: "T\($0)", components: []) }
        #expect(target.pasting(source, .default).masks.count == MaskLayer.maximumLayers)
    }

    /// Auto Sync carries what one step changed: here exposure and a new mask, nothing else.
    @Test func `the changes of a step are a selection`() {
        var old = EditRecipe()
        old[.contrast] = 20
        let kept = MaskLayer(name: "Kept", components: [])
        old.masks = [kept]
        var new = old
        new[.exposure] = 1
        let added = MaskLayer(name: "Added", components: [])
        new.masks.append(added)
        let changes = SettingsSelection.changes(from: old, to: new)
        #expect(changes.items == ["basic.exposure"])
        #expect(changes.includes(mask: added.id) && !changes.includes(mask: kept.id))
        #expect(SettingsSelection.changes(from: new, to: new).isEmpty)
        var curve = new
        curve.pointCurve = [CurvePoint(x: 0, y: 0.2), CurvePoint(x: 1, y: 1)]
        #expect(SettingsSelection.changes(from: new, to: curve).items == ["toneCurve.point"])
        let both = changes.union(SettingsSelection.changes(from: new, to: curve))
        #expect(both.items == ["basic.exposure", "toneCurve.point"] && both.includes(mask: added.id))
    }

    @Test func `the remembered choice forgets which masks were left out`() throws {
        var selection = SettingsSelection.default
        selection.excludedMasks = [UUID()]
        let data = try JSONEncoder().encode(selection.remembered)
        let decoded = try JSONDecoder().decode(SettingsSelection.self, from: data)
        #expect(decoded.items == selection.items && decoded.excludedMasks.isEmpty)
    }
}
