import Foundation
import Synchronization
import Testing
@testable import RedlampLibrary

struct IndexConcurrencyTests {
    private final class Flag: Sendable {
        private let state = Mutex(false)

        var value: Bool {
            state.withLock { $0 }
        }

        func set() {
            state.withLock { $0 = true }
        }
    }

    private func eventually(_ condition: () -> Bool) async throws {
        for _ in 0 ..< 400 where !condition() {
            try await Task.sleep(for: .milliseconds(5))
        }
    }

    @Test func `reads run while a write is in progress, and see only what's committed`() async throws {
        let sandbox = try await IndexSandbox.make(readers: 2)
        defer { sandbox.remove() }
        let folder = try #require(try await sandbox.addFolders(["Day"])["Day"])
        try await sandbox.upsert([PhotoRecord(folder: folder, name: "IMG_0001.HEIC")])

        let inside = Flag()
        let gate = IndexGate()
        let index = sandbox.index
        let writing = Task {
            try await index.write { writer in
                try writer.upsertPhotos((2 ... 500).map { PhotoRecord(folder: folder, name: "IMG_\($0).HEIC") })
                inside.set()
                gate.wait()
            }
        }
        try await eventually { inside.value }
        #expect(inside.value)
        // A read held up by the write would never return before the gate opens; open it anyway
        // after a while, so a failure is a failed expectation rather than a hung test.
        let opened = Flag()
        DispatchQueue.global().asyncAfter(deadline: .now() + 5) {
            opened.set()
            gate.open()
        }

        let during = try await index.read { try ($0.photoCount(), $0.photo(folder: folder, name: "IMG_2.HEIC")) }
        #expect(!opened.value, "the read finished while the write held its transaction open")
        #expect(during.0 == 1 && during.1 == nil)

        if !opened.value {
            gate.open()
        }
        try await writing.value
        #expect(try await index.read { try $0.photoCount() } == 500)
    }

    @Test func `writes from many tasks at once all land, one transaction at a time`() async throws {
        struct Interleaved: Error {}
        let sandbox = try await IndexSandbox.make()
        defer { sandbox.remove() }
        let folder = try #require(try await sandbox.addFolders(["Burst"])["Burst"])
        let index = sandbox.index
        try await withThrowingTaskGroup(of: Void.self) { group in
            for task in 0 ..< 20 {
                group.addTask {
                    try await index.write { writer in
                        let before = try writer.photoCount()
                        try writer
                            .upsertPhotos((0 ..< 50).map { PhotoRecord(folder: folder, name: "T\(task)_\($0).JPG") })
                        guard try writer.photoCount() == before + 50 else { throw Interleaved() }
                    }
                }
                group.addTask {
                    _ = try await index.read { try $0.photoCount() }
                }
            }
            try await group.waitForAll()
        }
        #expect(try await index.read { try $0.photoCount() } == 1000)
    }

    /// A race here shows only under Thread Sanitizer (`-enableThreadSanitizer YES`).
    @Test func `what a read builds reaches its caller whole, read under a lock or in a task group after it`(
    ) async throws {
        let sandbox = try await IndexSandbox.make(readers: 4)
        defer { sandbox.remove() }
        let folder = try #require(try await sandbox.addFolders(["Burst"])["Burst"])
        try await sandbox.upsert((0 ..< 40).map { PhotoRecord(folder: folder, name: "IMG_\($0).JPG") })
        let index = sandbox.index
        let seen = Count()
        try await withThrowingTaskGroup(of: Void.self) { group in
            for _ in 0 ..< 32 {
                group.addTask {
                    for round in 0 ..< 100 {
                        let rows = try await index.read { try $0.photos(inFolder: folder).filter { !$0.name.isEmpty } }
                        seen.add(rows)
                        let names = await withTaskGroup(of: Int.self) { names in
                            for row in rows.prefix(round % 4 + 1) {
                                names.addTask { row.name.utf8.count }
                            }
                            return await names.reduce(0, +)
                        }
                        #expect(names > 0)
                    }
                }
            }
            try await group.waitForAll()
        }
        #expect(seen.value == 32 * 100 * 40)
    }

    /// Photos counted under a lock, one at a time.
    private final class Count: Sendable {
        private let state = Mutex(0)

        var value: Int {
            state.withLock { $0 }
        }

        func add(_ rows: [PhotoRecord]) {
            state.withLock { count in
                for row in rows where !row.name.isEmpty {
                    count += 1
                }
            }
        }
    }

    @Test func `a read cancelled before it starts is dropped`() async throws {
        let sandbox = try await IndexSandbox.make(readers: 1)
        defer { sandbox.remove() }
        let index = sandbox.index
        let gate = IndexGate()
        let started = Flag()
        let blocking = Task {
            try await index.read { _ in
                started.set()
                gate.wait()
            }
        }
        try await eventually { started.value }
        let ran = Flag()
        let queued = Task {
            try await index.read { _ in ran.set() }
        }
        try await Task.sleep(for: .milliseconds(50))
        queued.cancel()
        gate.open()
        try await blocking.value
        await #expect(throws: CancellationError.self) { try await queued.value }
        #expect(!ran.value)
    }

    @Test func `a closed index refuses reads and writes`() async throws {
        let sandbox = try await IndexSandbox.make()
        defer { sandbox.remove() }
        await sandbox.index.close()
        await #expect(throws: LibraryIndexError.closed) { try await sandbox.index.read { try $0.photoCount() } }
        await #expect(throws: LibraryIndexError.closed) { try await sandbox.index.write { try $0.photoCount() } }
    }
}
