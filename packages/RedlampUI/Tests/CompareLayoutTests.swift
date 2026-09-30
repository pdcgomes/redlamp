import RedlampUI
import Testing

struct CompareLayoutTests {
    @Test func `cycling visits every layout and wraps both ways`() {
        #expect(CompareLayout.toggle.cycled(by: 1) == .sideBySide)
        #expect(CompareLayout.sideBySide.cycled(by: 1) == .split)
        #expect(CompareLayout.split.cycled(by: 1) == .toggle)
        #expect(CompareLayout.toggle.cycled(by: -1) == .split)
        #expect(CompareLayout.sideBySide.cycled(by: -4) == .toggle)
    }

    @Test func `layouts round-trip through their saved names`() {
        for layout in CompareLayout.allCases {
            #expect(CompareLayout(rawValue: layout.rawValue) == layout)
        }
    }
}
