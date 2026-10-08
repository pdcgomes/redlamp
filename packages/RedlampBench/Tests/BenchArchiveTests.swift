import Foundation
import RedlampBench
import Testing

struct BenchArchiveTests {
    @Test func `A folder zipped by the system unpacks into Done with its results`() throws {
        let scratch = Scratch()
        let store = BenchStore(root: scratch.file("store"))
        var folder = try makeTask(in: scratch)
        try folder.addResult(
            copying: TestImages.write(TestImages.photo(seed: 1), to: scratch.file("out.png")),
            originalName: "photo-1.png", pairer: BenchPairer(folder: folder),
        )
        let archive = scratch.file("task.\(BenchArchive.fileExtension)")
        try BenchArchive.make(folder.url, to: archive)

        let entries = try BenchArchive.entries(archive)
        #expect(entries.contains { $0.path.hasSuffix(BenchManifest.fileName) })
        try BenchArchive.check(entries)

        let arrival = try store.receive(archive)
        #expect(arrival.folder.url.deletingLastPathComponent() == store.url(.done))
        #expect(arrival.folder.results.results.count == 1)
        #expect(arrival.summary == "1 result, all paired")
        #expect(arrival.folder.validate().isEmpty)
        let inbox = try FileManager.default.contentsOfDirectory(atPath: store.url(.inbox).path)
        #expect(inbox.filter { !$0.hasPrefix(".") }.isEmpty)
    }

    @Test func `Entries outside the folder, links and oversized archives are refused`() {
        func entry(_ path: String, size: UInt64 = 10, link: Bool = false) -> BenchArchive.Entry {
            BenchArchive.Entry(path: path, compressedSize: size, size: size, isDirectory: false, isSymbolicLink: link)
        }
        #expect(throws: BenchArchive.ArchiveError.unsafe ("../evil")) { try BenchArchive.check([entry("../evil")]) }
        #expect(throws: BenchArchive.ArchiveError.unsafe ("/etc/x")) { try BenchArchive.check([entry("/etc/x")]) }
        #expect(throws: BenchArchive.ArchiveError.unsafe ("task/link (a link)")) {
            try BenchArchive.check([entry("task/link", link: true)])
        }
        #expect(throws: BenchArchive.ArchiveError.tooLarge(UInt64(BenchLimits.bytes) + 1)) {
            try BenchArchive.check([entry("task/big", size: UInt64(BenchLimits.bytes) + 1)])
        }
    }

    @Test func `A file that isn't a zip, and a tampered task, are refused`() throws {
        let scratch = Scratch()
        let store = BenchStore(root: scratch.file("store"))
        let junk = scratch.file("junk.redtask")
        try Data(repeating: 7, count: 300).write(to: junk)
        #expect(throws: BenchArchive.ArchiveError.notAZip) { try store.receive(junk) }

        let folder = try makeTask(in: scratch)
        try Data("tampered".utf8).write(to: folder.url.appending(path: folder.manifest.assets[0].file))
        let archive = scratch.file("tampered.redtask")
        try BenchArchive.make(folder.url, to: archive)
        #expect(throws: BenchError.self) { try store.receive(archive) }
        #expect(store.folders(.done).isEmpty)
    }
}
