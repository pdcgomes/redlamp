import Foundation
import RedlampEngineAPI
import Testing
@_spi(Harness) @testable import RedlampUI

/// The new Masks panel's picker (UX-20): one picker for New Mask, Add, Subtract and Intersect.
struct MaskPickerTests {
    @Test func `the picker's groups hold every kind Create New Mask offers, once each`() {
        let grouped = MaskKindGroup.allCases.flatMap(\.kinds)
        #expect(grouped.count == Set(grouped).count)
        #expect(Set(grouped) == Set(MaskKind.creatable))
    }

    @Test func `the picker's title says where its mask goes`() {
        let target = UUID()
        #expect(MaskPickerMode.new.title(targetName: nil) == "New Mask")
        #expect(MaskPickerMode.component(.add, target: target).title(targetName: "Sky") == "Add to Sky")
        #expect(MaskPickerMode.component(.subtract, target: target).title(targetName: "Sky") == "Subtract from Sky")
        #expect(MaskPickerMode.component(.intersect, target: target).title(targetName: "Sky") == "Intersect with Sky")
        #expect(MaskPickerMode.component(.subtract, target: target).operation == .subtract)
        #expect(MaskPickerMode.component(.subtract, target: target).target == target)
        #expect(MaskPickerMode.new.target == nil && MaskPickerMode.new.operation == .add)
    }
}
