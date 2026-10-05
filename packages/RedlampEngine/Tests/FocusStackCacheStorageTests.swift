import Foundation
import Testing
@testable import RedlampEngine

struct FocusStackCacheStorageTests {
    private let root = FileManager.default.temporaryDirectory.appending(path: "stack-cache-\(UUID().uuidString)")

    /// A merge of `bytes` in `root/<name>`, last used `age` seconds ago.
    @discardableResult
    private func entry(
        _ name: String, bytes: Int, age: TimeInterval = 0, document: URL? = nil, now: Date,
    ) throws -> URL {
        let folder = root.appending(path: name)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try Data(count: bytes).write(to: folder.appending(path: "fused.half"))
        if let document {
            try Data(document.standardizedFileURL.path.utf8).write(to: folder.appending(path: "document"))
        }
        try FileManager.default.setAttributes(
            [.modificationDate: now.addingTimeInterval(-age)],
            ofItemAtPath: folder.path,
        )
        return folder
    }

    private func names() throws -> Set<String> {
        try Set(FileManager.default.contentsOfDirectory(atPath: root.path))
    }

    @Test func `the least recently used merges go until the cache fits its budget`() throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let now = Date()
        try entry("oldest", bytes: 400, age: 300, now: now)
        try entry("older", bytes: 400, age: 200, now: now)
        try entry("recent", bytes: 400, age: 100, now: now)
        let kept = try entry("new", bytes: 400, now: now)
        FocusStackCache.trim(root, budget: 1000, keeping: kept, now: now)
        #expect(try names() == ["recent", "new"])
    }

    @Test func `the merge just saved stays even when it alone is over the budget`() throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let now = Date()
        try entry("old", bytes: 100, age: 100, now: now)
        let kept = try entry("new", bytes: 2000, now: now)
        FocusStackCache.trim(root, budget: 1000, keeping: kept, now: now)
        #expect(try names() == ["new"])
    }

    @Test func `a new retouch of a stack replaces its earlier retouches but not other stacks`() throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let now = Date()
        let document = URL(fileURLWithPath: "/Photos/Bracket.redstack")
        try entry("earlier-retouch", bytes: 10, age: 10, document: document, now: now)
        try entry("other-stack", bytes: 10, age: 10, document: URL(fileURLWithPath: "/Photos/Other.redstack"), now: now)
        try entry("unretouched", bytes: 10, age: 10, now: now)
        let kept = try entry("retouch", bytes: 10, document: document, now: now)
        FocusStackCache.trim(root, budget: 1 << 30, keeping: kept, document: document, now: now)
        #expect(try names() == ["other-stack", "unretouched", "retouch"])
    }

    @Test func `staging an interrupted save left goes once it is old`() throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let now = Date()
        try entry(".abandoned-A", bytes: 10, age: 2 * FocusStackCache.leftoverAge, now: now)
        try entry(".saving-B", bytes: 10, age: 5, now: now)
        let kept = try entry("new", bytes: 10, now: now)
        FocusStackCache.trim(root, budget: 1 << 30, keeping: kept, now: now)
        #expect(try names() == [".saving-B", "new"])
    }
}
