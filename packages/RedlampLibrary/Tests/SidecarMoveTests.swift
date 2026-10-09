import Dispatch
import Foundation
import RedlampDocument
import Synchronization
import Testing
@testable import RedlampLibrary

/// Moving a root's sidecars (LIB-11): one journal for the whole move, so a launch after a quit finishes it, forwards
/// or putting back; Cancel, or cancelling the task, stopping it between two parts and putting back every sidecar in the
/// place they were going, the journal turned round first; and whether Redlamp can write in a place, and why not.
struct SidecarMoveTests {
    static let names = (1 ... 12).map { String(format: "IMG_%04d.JPG", $0) }

    /// Twelve photos with sidecars beside them, indexed; the library's sidecars and the root's ID.
    static func library() async throws -> (sandbox: KeywordSandbox, sidecars: LibrarySidecars, root: Int64) {
        let sandbox = try await KeywordSandbox.make()
        for (number, name) in names.enumerated() {
            try sandbox.photo(name, rating: number % 5 + 1)
        }
        try await sandbox.indexAll()
        let path = LibraryIndexer.path(sandbox.root)
        let root = try #require(try await sandbox.index.read { try $0.root(path: path) }?.id)
        return (sandbox, LibrarySidecars(index: sandbox.index, paths: sandbox.paths), root)
    }

    /// The photos whose sidecar is beside them, and those whose sidecar is on this Mac.
    static func places(_ sandbox: KeywordSandbox, _ sidecars: LibrarySidecars) async throws
        -> (beside: Set<String>, onThisMac: Set<String>) {
        let locator = try await sidecars.locator()
        var places: (beside: Set<String>, onThisMac: Set<String>) = ([], [])
        for name in names {
            if FileManager.default.fileExists(atPath: SidecarLocator.besidePhoto(sandbox.url(name)).path) {
                places.beside.insert(name)
            }
            if let mac = locator.onThisMac(sandbox.url(name)), FileManager.default.fileExists(atPath: mac.path) {
                places.onThisMac.insert(name)
            }
        }
        return places
    }

    static func journal(_ sidecars: LibrarySidecars) -> SidecarMoveJournal? {
        (try? Data(contentsOf: sidecars.moveJournal)).flatMap { try? JSONDecoder().decode(
            SidecarMoveJournal.self,
            from: $0,
        ) }
    }

    static func placement(_ sidecars: LibrarySidecars, _ root: Int64) async throws -> RootRecord.Sidecars? {
        try await sidecars.index.read { try $0.root(id: root)?.sidecars }
    }

    @Test func `Cancel stops the move between two parts, turns it round in its journal and puts back what moved`(
    ) async throws {
        let (sandbox, sidecars, root) = try await Self.library()
        defer { sandbox.remove() }
        let plan = try await sidecars.planMove(ofRoot: root, to: .onThisMac)
        let control = SidecarMoveControl()
        let journals = Mutex<[SidecarMoveJournal?]>([])
        let placements = Atomic(0)
        let outcome = try await sidecars.move(plan, part: 4, control: control, placed: {
            placements.add(1, ordering: .relaxed)
        }, progress: { progress in
            if progress.done == 0 {
                journals.withLock { $0.append(Self.journal(sidecars)) }
            }
            if !progress.isRollingBack, progress.done > 0 {
                control.cancel()
            }
        })
        #expect(outcome.moved == 4, "the first part, then nothing")
        #expect(outcome.putBack == SidecarPutBack(moved: 4))
        let (setOut, turned) = try journals.withLock { try (#require($0.first ?? nil), #require($0.last ?? nil)) }
        #expect(!setOut.puttingBack && setOut.plan.items.count == 12, "the whole move journaled as it set out")
        #expect(turned.puttingBack && turned.plan.destination == .besidePhotos && turned.plan.items.count == 4)
        #expect(placements.load(ordering: .relaxed) == 2, "set out, then back")
        #expect(try await Self.placement(sidecars, root) == .besidePhotos)
        #expect(try await Self.places(sandbox, sidecars) == (Set(Self.names), []))
        #expect(try await sidecars.unfinishedMove() == nil)
    }

    @Test func `cancelling the task moving the sidecars stops the move as Cancel does`() async throws {
        let (sandbox, sidecars, root) = try await Self.library()
        defer { sandbox.remove() }
        let plan = try await sidecars.planMove(ofRoot: root, to: .onThisMac)
        let (first, resumed) = (DispatchSemaphore(value: 0), DispatchSemaphore(value: 0))
        let task = Task {
            try await sidecars.move(plan, part: 4, progress: { progress in
                if !progress.isRollingBack, progress.done == 1 {
                    first.signal()
                    resumed.wait()
                }
            })
        }
        await withCheckedContinuation { continuation in
            DispatchQueue.global().async {
                first.wait()
                continuation.resume()
            }
        }
        task.cancel()
        resumed.signal()
        let outcome = try await task.value
        #expect(outcome.moved == 4 && outcome.putBack?.moved == 4)
        #expect(try await Self.placement(sidecars, root) == .besidePhotos)
        #expect(try await Self.places(sandbox, sidecars) == (Set(Self.names), []))
    }

    @Test func `a launch finishes the move its journal holds, the part a quit cut short and the rest`() async throws {
        let (sandbox, sidecars, root) = try await Self.library()
        defer { sandbox.remove() }
        // As a quit leaves it: the whole move journaled, the placement this Mac's, five sidecars moved.
        let plan = try await sidecars.planMove(ofRoot: root, to: .onThisMac)
        try FileManager.default.createDirectory(at: sidecars.paths.root, withIntermediateDirectories: true)
        try JSONEncoder().encode(SidecarMoveJournal(plan: plan)).write(to: sidecars.moveJournal)
        try await sidecars.setPlacement(.onThisMac, forRoot: root)
        for item in plan.items.prefix(5) {
            #expect(try SidecarMover.move(item.source, to: item.target) == .moved)
        }
        #expect(try await sidecars.unfinishedMove() == SidecarMoveJournal(plan: plan))

        let outcome = try #require(try await sidecars.resumeMove())
        #expect(outcome.moved == 12 && outcome.failed.isEmpty && outcome.putBack == nil)
        #expect(try await Self.places(sandbox, sidecars) == ([], Set(Self.names)))
        #expect(try await Self.placement(sidecars, root) == .onThisMac)
        #expect(try await sidecars.resumeMove() == nil)
    }

    @Test func `a launch finishes putting back a move Cancel had turned round`() async throws {
        let (sandbox, sidecars, root) = try await Self.library()
        defer { sandbox.remove() }
        let plan = try await sidecars.planMove(ofRoot: root, to: .onThisMac)
        try await sidecars.setPlacement(.onThisMac, forRoot: root)
        for item in plan.items.prefix(5) {
            _ = try SidecarMover.move(item.source, to: item.target)
        }
        // Turned round, two of the five put back when the quit came.
        var back = try await sidecars.planMove(ofRoot: root, to: .besidePhotos)
        #expect(back.items.count == 5)
        back.conflicts = []
        try JSONEncoder().encode(SidecarMoveJournal(plan: back, puttingBack: true)).write(to: sidecars.moveJournal)
        try await sidecars.setPlacement(.besidePhotos, forRoot: root)
        for item in back.items.prefix(2) {
            _ = try SidecarMover.move(item.source, to: item.target)
        }

        let outcome = try #require(try await sidecars.resumeMove())
        #expect(outcome.moved == 0 && outcome.putBack == SidecarPutBack(moved: 5))
        #expect(try await Self.places(sandbox, sidecars) == (Set(Self.names), []))
        #expect(try await Self.placement(sidecars, root) == .besidePhotos)
        #expect(try await sidecars.unfinishedMove() == nil)
    }

    @Test func `a place is said to be one Redlamp can write in, or why it can't`() throws {
        let folder = try TemporaryFolder()
        #expect(LibrarySidecars.writeAccess(in: folder.url) == .writable)
        #expect(LibrarySidecars.writeAccess(in: folder.url.appending(path: "Gone")) == .missing)
        let locked = folder.url.appending(path: "Locked", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: locked, withIntermediateDirectories: true)
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: locked.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: locked.path) }
        #expect(LibrarySidecars.writeAccess(in: locked, probing: false) == .notPermitted)
        #expect(LibrarySidecars.canWrite(in: locked) == false && LibrarySidecars.canWrite(in: folder.url) == true)
    }
}
