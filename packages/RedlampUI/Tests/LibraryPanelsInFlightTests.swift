import Foundation
import RedlampLibrary
import Testing
@_spi(Harness) @testable import RedlampUI

/// Library's panels while their changes are made, one batch after another.
@MainActor
struct LibraryPanelsInFlightTests {
    /// The keyword set's keys pressed one after another: as each batch is made, the panels go on showing the
    /// keywords asked for after it, so a key pressed again takes its keyword off rather than putting it on again.
    @Test func `keywords asked for while an earlier batch is made stay shown when it's done`() async throws {
        let folder = LibraryPanelsTests.Folder()
        defer { folder.close() }
        try await folder.open()
        let panels = folder.panels
        try await folder.select([1, 2, 3])
        panels.chooseKeywordSet("Wedding Photography")
        try await folder.written()
        let keys: [ShortcutAction] = [.keywordSet1, .keywordSet2, .keywordSet3, .keywordSet4, .keywordSet5]
        let keywords = try keys.map { try #require(panels.activeSet?.keyword(forShortcut: $0.keywordSetNumber ?? 0)) }

        var asked: [KeywordPath] = []
        var shownOff: Set<String> = []
        func look() {
            for keyword in asked where panels.selection.hasEverywhere(keyword) != true {
                shownOff.insert(keyword.text)
            }
        }
        for (key, keyword) in zip(keys, keywords) {
            #expect(folder.model.perform(key))
            asked.append(keyword)
            look()
            try await Task.sleep(for: .milliseconds(3))
            look()
        }
        let made = Flag()
        Task {
            await panels.written()
            made.isSet = true
        }
        for _ in 0 ..< 10000 where !made.isSet {
            look()
            try await Task.sleep(for: .milliseconds(1))
        }
        try await folder.written()
        look()
        let expected = keywords.map(\.text).sorted()
        #expect(shownOff.isEmpty, "shown off while being put on: \(shownOff.sorted())")
        for number in [1, 2, 3] {
            #expect(folder.keywords(number) == expected, "photo \(number)")
        }
    }

    private final class Flag {
        var isSet = false
    }
}
