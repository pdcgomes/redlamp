import Foundation
import RedlampLibrary
import Testing
@testable import RedlampUI

/// The filter bar's Metadata columns for the lens's fields (LIB-06, LIB-18): their names beside the focal length's
/// and the aperture's, their rows' titles, and the choices they read back from the query's text; and the smart
/// collection editor's names for the two fields.
struct LensFilterTests {
    @Test func `the 35 mm focal length and widest aperture columns are named, beside the focal length and aperture`() {
        #expect(FacetColumn.focal35.title == "35 mm Focal Length")
        #expect(FacetColumn.widestAperture.title == "Widest Aperture")
        let menu = FacetColumn.allCases.map(\.title)
        #expect(menu.firstIndex(of: "35 mm Focal Length") == menu.firstIndex(of: "Focal Length").map { $0 + 1 })
        #expect(menu.firstIndex(of: "Widest Aperture") == menu.firstIndex(of: "Aperture").map { $0 + 1 })
        #expect(SmartRules.title(of: LibraryQuery.Field.focal35) == "35 mm Focal Length")
        #expect(SmartRules.title(of: LibraryQuery.Field.widestAperture) == "Widest Aperture")
        #expect(SmartRules.fields.contains(.filter(.focal35)) && SmartRules.fields.contains(.filter(.widestAperture)))
    }

    @Test func `a column's rows show millimetres and f-numbers, and the text's choice marks its row`() throws {
        let focal = FacetColumnCounts(index: 0, column: .focal35, total: 3, values: [
            FacetValue(name: "24", count: 1, filter: .filter(.init(.focal35, .equal, [.number(24)]))),
            FacetValue(name: "85", count: 1, filter: .filter(.init(.focal35, .equal, [.number(85)]))),
            FacetValue(name: nil, count: 1, filter: nil),
        ])
        let rows = FilterColumnRow.rows(focal, folder: nil)
        #expect(rows.map(\.title) == ["24 mm", "85 mm", "Unknown"])
        let chosen = try FilterColumnRow.choice(in: QueryRules(parsing: "focal35:85 rating>=3"), column: .focal35)
        #expect(rows.map { $0.isChosen(by: chosen, in: .focal35) } == [false, true, false])

        let widest = FacetColumnCounts(index: 1, column: .widestAperture, total: 2, values: [
            FacetValue(name: "1.4", count: 1, filter: .filter(.init(.widestAperture, .equal, [.number(1.4)]))),
            FacetValue(name: "2.8", count: 1, filter: .filter(.init(.widestAperture, .equal, [.number(2.8)]))),
        ])
        #expect(FilterColumnRow.rows(widest, folder: nil).map(\.title) == ["f/1.4", "f/2.8"])
    }
}
