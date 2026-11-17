import Foundation
import Testing
@testable import RedlampUI

/// What the collection sheets say (LIB-45).
@MainActor
struct CollectionSheetTests {
    @Test func `the smart collection editor counts the photos its rules find in words that agree`() {
        #expect(SmartCollectionSheet.matching(0) == "No photos match these rules")
        #expect(SmartCollectionSheet.matching(1) == "1 photo matches these rules")
        #expect(
            SmartCollectionSheet.matching(1204) == "\(1204.formatted()) photos match these rules",
            "1,204 or 1.204, as the Mac's region writes it",
        )
    }
}
