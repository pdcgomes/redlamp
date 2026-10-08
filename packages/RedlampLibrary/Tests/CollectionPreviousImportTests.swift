import Foundation
import RedlampDocument
import Testing
@testable import RedlampLibrary

/// The Library panel's Previous Import (LIB-23): the newest import that's over, its photos at their
/// destination, from the imports' journal.
struct CollectionPreviousImportTests {
    private static func jpegs(_ count: Int, from first: Int = 1) -> [SimulatedCard.Shot] {
        (first ..< first + count).map { number in
            SimulatedCard.Shot(name: String(format: "IMG_%04d.JPG", number), captured: cameraTime(Double(number)))
        }
    }

    @Test func `the previous import is the newest import that's over, each photo it copied at its destination`(
    ) async throws {
        let sandbox = try await ImportSandbox.make()
        defer { sandbox.remove() }
        let journal = ImportJournal(paths: sandbox.paths)
        #expect(try journal.previousImport() == nil)

        let settings = try sandbox.settings(folders: "{date:yyyy-MM-dd}", backup: true)
        let first = try sandbox.session([sandbox.card("ONE", Self.jpegs(2))], previews: false)
        _ = try await first.importer().run(first.plan(settings))
        let second = try sandbox.session([sandbox.card("TWO", Self.jpegs(3, from: 10))], previews: false)
        let plan = try await second.plan(settings)
        let outcome = try await second.importer().run(plan)
        #expect(outcome.state == .finished)

        let previous = try #require(try journal.previousImport())
        #expect(previous.id == plan.id)
        let expected = plan.items.flatMap(\.photos).map { LibraryIndexer.path(plan.targets(of: $0)[0]) }
        #expect(previous.photos == expected && previous.photos.count == 3)
        #expect(previous.photos.allSatisfy { $0.hasPrefix(LibraryIndexer.path(sandbox.destination) + "/") })
        #expect(previous.folders == Array(Set(expected.map { ($0 as NSString).deletingLastPathComponent })).sorted())
    }

    @Test func `an import with no photo done isn't the previous import`() async throws {
        let sandbox = try await ImportSandbox.make()
        defer { sandbox.remove() }
        let settings = try sandbox.settings(folders: "", backup: false)
        let done = try sandbox.session([sandbox.card("ONE", Self.jpegs(1))], previews: false)
        let kept = try await done.plan(settings)
        _ = try await done.importer().run(kept)
        let failing = try sandbox.session([sandbox.card("TWO", Self.jpegs(1, from: 5))], previews: false)
        let plan = try await failing.plan(settings)
        let unwritable = CorruptingFileSystem { $0.lastPathComponent.hasPrefix(".IMG_0005.JPG") }
        let outcome = try await failing.importer(destinationFileSystem: unwritable).run(plan)
        #expect(outcome.verified == 0)

        #expect(try ImportJournal(paths: sandbox.paths).previousImport()?.id == kept.id)
    }
}
