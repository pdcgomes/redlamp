import Foundation
import Testing
@testable import RedlampLibrary

/// Library Health's checks as sources (LIB-40): each check's findings a list `LibraryLive` keeps
/// current by diffs, as every other list is.
struct HealthSourceTests {
    @Test func `files still being written aren't listed as damaged`() async throws {
        let sandbox = try await HealthSandbox.make(["Copying/Half.jpg": HealthImages.data(.jpeg).dropLast(80)])
        defer { sandbox.remove() }
        try sandbox.write(["Copying/Now.jpg": HealthImages.data(.jpeg).dropLast(80)], modified: Date())
        await sandbox.index()
        let found = try await sandbox.library().findings(.damaged)
        #expect(try await sandbox.paths(found.photos) == ["Copying/Half.jpg"])
        #expect(found.findings.first?.reason.description == "ends before its data does")
    }

    @Test func `a check with nothing to decide isn't offered`() async throws {
        let sandbox = try await HealthSandbox.make([
            "Cards/Good.jpg": HealthImages.data(.jpeg, seed: 1), "Cards/Empty.jpg": Data(),
        ])
        defer { sandbox.remove() }
        await sandbox.index()
        let offered = try await sandbox.library().offered()
        #expect(offered.map(\.check) == [.damaged])
        #expect(offered.first?.findings.map(\.proposal) == [.trash])
    }

    @Test func `counts follow changes, by diffs`() async throws {
        let sandbox = try await HealthSandbox.make([
            "Cards/Empty.jpg": Data(), "Cards/Good.jpg": HealthImages.data(.jpeg, seed: 1),
        ])
        defer { sandbox.remove() }
        await sandbox.index()
        let engine = QueryEngine(index: sandbox.index)
        try await engine.load()
        let live = LibraryLive(engine: engine, configuration: .init(latency: .milliseconds(10)))
        let indexer = LibraryIndexer(index: sandbox.index, configuration: .testing())
        var damaged = live.open(.health(.damaged)).makeAsyncIterator()
        let first = try #require(await damaged.next())
        #expect(first.list.count == 1 && first.diff.reset)

        try sandbox.write(["Cards/Cut.jpg": HealthImages.data(.jpeg, seed: 2).dropLast(40)])
        for await event in indexer.update([FolderChange(sandbox.url("Cards"))]) {
            live.receive(event)
        }
        await live.settle()
        let grown = try #require(await damaged.next())
        #expect(grown.list.count == 2 && !grown.diff.reset && grown.diff.inserted.count == 1)

        try sandbox.write(["Cards/Empty.jpg": HealthImages.data(.jpeg, seed: 3)])
        for await event in indexer.update([FolderChange(sandbox.url("Cards"))]) {
            live.receive(event)
        }
        await live.settle()
        let shrunk = try #require(await damaged.next())
        #expect(shrunk.list.count == 1 && shrunk.diff.removed.count == 1)
    }
}
