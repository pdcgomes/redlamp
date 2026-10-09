import Foundation
import Testing
@testable import RedlampLibrary

/// Keep Anyway (LIB-40): findings taken away in `Definitions/Health.json`, by what the photos show,
/// until they're taken back from the Kept Anyway list.
struct HealthKeepAnywayTests {
    @Test func `choosing Keep Anyway survives an index rebuild, and a third copy reopens a duplicate group`(
    ) async throws {
        let copy = HealthImages.data(.jpeg, seed: 4)
        let sandbox = try await HealthSandbox.make([
            "A/IMG_1.jpg": copy, "B/IMG_1.jpg": copy, "Cards/Empty.jpg": Data(),
            "Cards/IMG_2.jpg": HealthImages.data(.png, seed: 5),
        ])
        defer { sandbox.remove() }
        await sandbox.index()
        var health = sandbox.library()
        try await health.confirmDuplicates()
        let duplicates = try await health.findings(.duplicates)
        #expect(Set(duplicates.findings.compactMap(\.proposal)) == [.keep, .trash])
        try await health.keepAnyway([duplicates.proposed[0]], in: duplicates)
        let damaged = try await health.findings(.damaged)
        let extensions = try await health.findings(.extensions)
        #expect(damaged.findings.count == 1 && extensions.findings.count == 1)
        try await health.keepAnyway(damaged.photos, in: damaged)
        try await health.keepAnyway(extensions.photos, in: extensions)
        for check in [HealthCheck.duplicates, .damaged, .extensions] {
            let found = try await health.findings(check)
            #expect(found.isEmpty && found.keptAnyway > 0, "\(check)")
        }
        #expect(try await health.offered().isEmpty, "nothing is left to decide")
        let kept = try await health.keptAnyway()
        #expect(kept.count == 3 && kept.allSatisfy { !$0.photos.isEmpty })
        let source = try await health.engine.list(.keptAnyway)
        #expect(Set(source) == Set(kept.flatMap(\.photos)), "the Kept Anyway list, a source of its own")

        // A newer build's key stays in the file.
        let url = HealthDefinitions.url(in: sandbox.paths)
        var json = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        json["fromANewerBuild"] = ["kept": true]
        try JSONSerialization.data(withJSONObject: json).write(to: url)

        try await sandbox.rebuild()
        health = sandbox.library()
        try await health.confirmDuplicates()
        for check in [HealthCheck.duplicates, .damaged, .extensions] {
            #expect(try await health.findings(check).isEmpty, "\(check), after the rebuild")
        }

        try sandbox.write(["C/IMG_1.jpg": copy])
        await sandbox.index()
        try await health.confirmDuplicates()
        #expect(try await health.findings(.duplicates).findings.count == 3, "a third copy opens the group again")

        let entry = try #require(try await health.keptAnyway().first { $0.kept.check == .damaged })
        try await health.takeBack([entry.kept])
        #expect(try await health.findings(.damaged).findings.count == 1, "taken back from Kept Anyway")
        let written = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        #expect(written["fromANewerBuild"] != nil)
    }

    @Test func `choosing Keep Anyway returns only the entries it added, which Undo takes back and Redo keeps again`(
    ) async throws {
        let copy = HealthImages.data(.jpeg, seed: 7)
        let sandbox = try await HealthSandbox.make([
            "A/IMG_1.jpg": copy, "B/IMG_1.jpg": copy, "C/IMG_1.jpg": copy, "Cards/Empty.jpg": Data(),
        ])
        defer { sandbox.remove() }
        await sandbox.index()
        let health = sandbox.library()
        try await health.confirmDuplicates()
        let duplicates = try await health.findings(.duplicates)
        #expect(duplicates.proposed.count == 2)

        // Two copies of one group are one entry, kept by the first; the second adds nothing.
        let first = try await health.keepAnyway([duplicates.proposed[0]], in: duplicates)
        #expect(first.count == 1 && first.first?.check == .duplicates)
        let again = try await health.keepAnyway([duplicates.proposed[1]], in: duplicates)
        #expect(again.isEmpty, "the group was kept already")
        let damaged = try await health.findings(.damaged)
        let kept = try await health.keepAnyway(damaged.photos, in: damaged)
        #expect(kept.count == 1)

        // Undo takes back the damaged file's entry alone; the group stays kept.
        try await health.takeBack(kept)
        #expect(try await health.findings(.damaged).findings.count == 1)
        #expect(try await health.findings(.duplicates).isEmpty)

        // Redo keeps it again, as it was.
        let redone = try await health.keepAnyway(kept)
        #expect(redone == kept)
        #expect(try await health.findings(.damaged).isEmpty)
        #expect(try await health.keepAnyway(kept).isEmpty, "kept already: nothing added")
    }

    @Test func `a photo rewritten past its content key's bytes, its size the same, is listed again`() async throws {
        // A PNG with bytes after its end, longer than the 64 KiB its content key reads.
        let long = HealthImages.data(.png, seed: 9) + Data(repeating: 0, count: 100 * 1024)
        let sandbox = try await HealthSandbox.make(["Cards/IMG_3.png": long, "Cards/IMG_4.png": long + Data([1])])
        defer { sandbox.remove() }
        await sandbox.index()
        let health = sandbox.library()
        let damaged = try await health.findings(.damaged)
        #expect(damaged.findings.count == 2)
        let kept = try await health.keepAnyway(damaged.photos, in: damaged)
        #expect(kept.allSatisfy {
            if case .content(_, .some) = $0.key {
                true
            } else {
                false
            }
        })
        #expect(try await health.findings(.damaged).isEmpty)

        // IMG_4's entry as the first builds wrote it, by its content key alone.
        let url = HealthDefinitions.url(in: sandbox.paths)
        var json = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        let rows = try await sandbox.rows()
        let fourth = try #require(rows["Cards/IMG_4.png"]?.contentKey.flatMap(ContentKey.init(data:)))
        json["keptAnyway"] = try (#require(json["keptAnyway"] as? [[String: Any]])).map { entry in
            entry["contentKey"] as? String == fourth.hex ? entry.filter { $0.key != "modified" } : entry
        }
        try JSONSerialization.data(withJSONObject: json).write(to: url)

        // Both rewritten 80 KiB in, their sizes and content keys the same.
        var third = long
        third[80 * 1024] = 7
        var fourthData = long + Data([1])
        fourthData[80 * 1024] = 7
        try sandbox.write(
            ["Cards/IMG_3.png": third, "Cards/IMG_4.png": fourthData],
            modified: HealthSandbox.written.addingTimeInterval(60),
        )
        await sandbox.index()
        let rewritten = try await sandbox.rows()
        #expect(rewritten["Cards/IMG_3.png"]?.contentKey == rows["Cards/IMG_3.png"]?.contentKey)
        // Without lists to follow the index, a library of its own sees the photos as they are now.
        let now = sandbox.library()
        let listed = try await now.findings(.damaged)
        #expect(try await sandbox.paths(listed.photos) == ["Cards/IMG_3.png"], "listed again; the older entry keeps")
        let stillKept = try await now.keptAnyway()
        #expect(stillKept.flatMap(\.photos) == [rewritten["Cards/IMG_4.png"]?.id].compactMap(\.self))
    }
}
