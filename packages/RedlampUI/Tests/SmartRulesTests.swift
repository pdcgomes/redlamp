import Foundation
import RedlampLibrary
import Testing
@_spi(Harness) @testable import RedlampUI

/// The smart collection editor's rules (LIB-23): rows of a field, a comparison and a value, matching all, any or
/// none, with groups of their own, converting to and from the query's text as the library's rule form does.
@MainActor
struct SmartRulesTests {
    private func rule(_ field: LibraryQuery.Field, _ comparison: SmartRules.Comparison, _ value: String) -> SmartRules
        .Row {
        .rule(SmartRules.Rule(field: .filter(field), comparison: comparison, value: value))
    }

    @Test(arguments: [
        "flag:pick edited:no",
        "rating>=3 OR flag:pick",
        "-flag:reject",
        "(camera:X-T5 OR camera:\"Z 6\") date:2024-06..2024-08",
        "-(label:red OR label:blue)",
        "\"wedding cake\" -edited:yes",
        "-rating>=3",
        "iso<=800 f:1.4..2.8 focal:24..70",
        "is:low-light -has:gps",
        "collection:\"Clients/Acme\" kw:\"Places/Portugal\"",
        "label:red,blue rating!=0",
        "date:last:30d",
    ])
    func `rules read from a query's text give that text back`(_ text: String) throws {
        let canonical = try LibraryQuery(parsing: text).description
        let rules = try SmartRules(parsing: text)
        #expect(try rules.text() == canonical)
        #expect(try SmartRules(parsing: rules.text()) == rules, "and the rules read from that text are the same")
    }

    @Test func `rows made in the editor make the query's text, with the values as the language writes them`() throws {
        var rules = SmartRules(match: .any, rows: [rule(.rating, .greaterOrEqual, "3"), rule(.flag, .is, "pick")])
        #expect(try rules.text() == "rating>=3 OR flag:pick")
        rules.match = .all
        rules.rows.append(.rule(SmartRules.Rule(field: .text, comparison: .doesNotContain, value: "test shot")))
        #expect(try rules.text() == "rating>=3 flag:pick -\"test shot\"")
        rules.rows = [rule(.camera, .is, "X-T5 II"), rule(.label, .isNot, "red")]
        #expect(try rules.text() == "camera:\"X-T5 II\" -label:red", "a value with a space is quoted")
        rules.rows = [.group(SmartRules(match: .none, rows: [rule(.edited, .is, "yes"), rule(.marked, .is, "yes")]))]
        #expect(try rules.text() == "-(edited:yes OR marked:yes)")
    }

    @Test func `a row the language can't read says which and why`() throws {
        let rules = SmartRules(rows: [rule(.flag, .is, "pick"), .group(SmartRules(rows: [rule(.rating, .is, "lots")]))])
        #expect(throws: SmartRulesError.self) { try rules.text() }
        do {
            _ = try rules.text()
        } catch {
            #expect(error.path == [1, 0])
            #expect(error.message.hasPrefix("Rating: "))
        }
        let empty = SmartRules(rows: [rule(.camera, .is, " ")])
        do {
            _ = try empty.text()
        } catch {
            #expect(error.path == [0] && error.message == "Give Camera a value.")
        }
    }

    @Test func `rows are put after one, taken away, and given another field, keeping a comparison it offers`() throws {
        var rules = SmartRules(rows: [rule(.rating, .greaterOrEqual, "3")])
        rules.insert(.group(SmartRules(match: .any, rows: [rule(.flag, .is, "pick")])), after: [0])
        rules.insert(rule(.label, .is, "red"), after: [1, 0])
        #expect(try rules.text() == "rating>=3 (flag:pick OR label:red)")
        rules.setField(.filter(.iso), at: [0])
        #expect(rules[[0]] == rule(.iso, .greaterOrEqual, "3"), "ISO is ordered: ≥ stays")
        rules.setField(.filter(.camera), at: [0])
        #expect(rules[[0]] == rule(.camera, .is, "3"), "a camera isn't: the first it offers")
        rules[[1, 0]] = nil
        #expect(try rules.text() == "camera:3 label:red", "a group of one is that one")
        #expect(SmartRules.Comparison.offered(for: .text) == [.contains, .doesNotContain])
        #expect(SmartRules.fields.count == LibraryQuery.Field.allCases.count + 1)
    }

    @Test func `a smart collection saved from the editor finds its photos, and edited, renamed, finds others`(
    ) async throws {
        let sandbox = SourcesSandbox()
        defer { sandbox.remove() }
        try sandbox.photos(["Shoot/A.JPG", "Shoot/B.JPG", "Shoot/C.JPG"])
        let model = try await sandbox.open()
        let sources = model.librarySources
        try await sandbox.counts { $0.isCounted }
        model.showFolder(sandbox.folder("Shoot"))
        try await sandbox.eventually { model.items.count == 3 }
        try await sandbox.cull(.flagPick, [sandbox.photo("Shoot/A.JPG"), sandbox.photo("Shoot/B.JPG")])

        let rules = SmartRules(rows: [rule(.flag, .is, "pick"), rule(.edited, .is, "no")])
        #expect(try sources.saveSmart(rules.text(), named: "Picked, not yet edited", inside: nil))
        let picked = try #require(CollectionPath(names: ["Picked, not yet edited"]))
        await model.libraryPanels.written()
        try await sandbox.counts { $0.count(of: .collection(picked)) == 2 }
        #expect(sources.collections[picked]?.kind == .smart && sources.count(of: .collection(picked)) == 2)
        #expect(try SmartRules(parsing: sources.collections[picked]?.query ?? "") == rules, "its rules read back")

        #expect(sources.show(.collection(picked)))
        try await sandbox.eventually { !sources.isListing && model.items.count == 2 }
        let unflagged = SmartRules(rows: [rule(.flag, .is, "none")])
        #expect(try sources.saveSmart(unflagged.text(), named: "Unflagged", inside: nil, editing: picked))
        let renamed = try #require(CollectionPath(names: ["Unflagged"]))
        await model.libraryPanels.written()
        try await sandbox.counts { $0.count(of: .collection(renamed)) == 1 }
        #expect(sources.collections[picked] == nil && sources.count(of: .collection(renamed)) == 1)
        try await sandbox.eventually { sources.shown == .collection(renamed) && model.items.count == 1 }
        #expect(model.items.map(\.url) == [sandbox.photo("Shoot/C.JPG")], "shown again, under its new name")
    }
}
