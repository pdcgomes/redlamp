import Foundation
import Testing
@testable import RedlampLibrary

/// What indexing finds wrong with photos' files (LIB-40), from its one read of each head and the end
/// reads some formats take.
struct HealthIndexingTests {
    @Test func `an unreadable file is kept with its reason and left out of lists`() async throws {
        let sandbox = try await HealthSandbox.make([
            "Shoot/A.jpg": HealthImages.data(.jpeg, seed: 1),
            "Shoot/B.jpg": HealthImages.data(.jpeg, seed: 2),
            "Shoot/C.jpg": HealthImages.data(.jpeg, seed: 3),
        ])
        defer { sandbox.remove() }
        let failing = FailingReadFileSystem(failing: [sandbox.url("Shoot/B.jpg")])
        let run = await sandbox.index(fileSystem: failing)
        let summary = try #require(run.summary)
        #expect(run.failures.isEmpty, "\(run.failures)")
        #expect(summary.photosInserted == 3 && summary.photosUnreadable == 1)

        let rows = try await sandbox.rows()
        let unreadable = try #require(rows["Shoot/B.jpg"])
        #expect(unreadable.state == [.unreadable] && unreadable.contentKey == nil)
        #expect(rows["Shoot/A.jpg"]?.state == [] && rows["Shoot/A.jpg"]?.contentKey != nil)
        let health = try await sandbox.health()
        #expect(health["Shoot/B.jpg"]?.damage == .unreadable("Input/output error"))
        #expect(health["Shoot/B.jpg"]?.damage?.description == "can't be read: Input/output error")
        #expect(health["Shoot/A.jpg"] == nil && health["Shoot/C.jpg"] == nil)
        let folders = try await sandbox.index.read { try $0.foldersToIndex() }
        #expect(folders.isEmpty, "the folder is indexed, the photo kept rather than failing it")

        let engine = QueryEngine(index: sandbox.index)
        try await engine.load()
        let shoot = URL(fileURLWithPath: LibraryIndexer.path(sandbox.url("Shoot")), isDirectory: true)
        for source in [PhotoSource.allPhotographs, .folder(shoot, includingSubfolders: false), .query(.all)] {
            let list = try await engine.list(source)
            #expect(list.count == 2 && !list.contains(unreadable.id), "\(source)")
        }
        let found = try await engine.list(.query(LibraryQuery(parsing: "unreadable:yes")))
        #expect(Array(found) == [unreadable.id])
        let searched = try await engine.results(LibraryQuery(parsing: "unreadable:no"))
        #expect(searched.last?.count == 2)
        #expect(try await engine.results(.all).last?.count == 2)
        let filtered = try await engine.list(.allPhotographs, matching: LibraryQuery(parsing: "unreadable:yes"))
        #expect(Array(filtered) == [unreadable.id])

        // Read again once its folder changes, and kept no longer once it reads.
        failing.heal(sandbox.url("Shoot/B.jpg"))
        try sandbox.write(["Shoot/D.jpg": HealthImages.data(.jpeg, seed: 4)])
        let again = await sandbox.index(fileSystem: failing)
        #expect(again.failures.isEmpty && again.summary?.photosUnreadable == 0)
        #expect(try await sandbox.rows()["Shoot/B.jpg"]?.state == [])
        #expect(try await sandbox.health().isEmpty)
    }

    @Test func `an empty file and a JPEG without its end marker are found`() async throws {
        let short = HealthImages.data(.jpeg, seed: 5)
        let long = HealthImages.longJPEG
        #expect(long.count > PhotoMetadataReader.headLength, "the long JPEG's end takes a read of its own")
        let sandbox = try await HealthSandbox.make([
            "Shoot/Empty.jpg": Data(),
            "Shoot/Short.jpg": short,
            "Shoot/Short cut.jpg": short.prefix(short.count - 200),
            "Shoot/Long.jpg": long,
            "Shoot/Long cut.jpg": long.prefix(long.count * 2 / 3),
            "Shoot/Zeros.jpg": Data(count: 300_000),
            "Shoot/Picture.png": HealthImages.data(.png, seed: 6),
            "Shoot/Picture cut.png": HealthImages.data(.png, seed: 6).dropLast(30),
        ])
        defer { sandbox.remove() }
        let run = await sandbox.index()
        #expect(run.failures.isEmpty, "\(run.failures)")
        #expect(run.summary?.endsRead == 2, "the long JPEGs' ends, read after the photos")
        #expect(run.summary?.photosUnreadable == 0, "only a read that fails leaves a photo out of lists")

        let health = try await sandbox.health()
        #expect(health["Shoot/Empty.jpg"]?.damage == .empty)
        #expect(health["Shoot/Short cut.jpg"]?.damage == .endsEarly(missing: nil))
        #expect(health["Shoot/Long cut.jpg"]?.damage == .endsEarly(missing: nil))
        #expect(health["Shoot/Long cut.jpg"]?.endUnread == false)
        #expect(health["Shoot/Zeros.jpg"]?.damage == .unrecognised)
        #expect(health["Shoot/Picture cut.png"]?.damage == .endsEarly(missing: nil))
        for whole in ["Shoot/Short.jpg", "Shoot/Long.jpg", "Shoot/Picture.png"] {
            #expect(health[whole] == nil, "\(whole)")
        }
        let rows = try await sandbox.rows()
        for listed in ["Shoot/Empty.jpg", "Shoot/Zeros.jpg", "Shoot/Long cut.jpg"] {
            #expect(rows[listed]?.state == [], "\(listed)")
        }
        #expect(rows["Shoot/Empty.jpg"]?.contentKey == nil, "an empty file isn't read")
    }

    @Test func `files that end early say by how much where their format does`() throws {
        // A raw whose head describes its raw data: a NEF's often lies in a sub-IFD past it.
        let raw = try #require(FixtureTests.sources.first { $0.url.pathExtension.lowercased() == "arw" })
        let size = try LocalFileSystem().attributes(of: raw.url).size
        let head = try LocalFileSystem().read(raw.url, range: 0 ..< PhotoMetadataReader.headLength)
        #expect(FileEnd.judge(.tiff, size: Int(size), bytes: FileBytes([(0, head)])) == .whole)
        let cut = Int(size) / 2
        guard case let .early(missing?) = FileEnd.judge(.tiff, size: cut, bytes: FileBytes([(0, head)])) else {
            Issue.record("a TIFF-based raw cut in half ends early")
            return
        }
        #expect(missing >= Int64(size) - Int64(cut) - 1_000_000 && missing <= Int64(size) - Int64(cut))

        let heic = HealthImages.data(.heic, seed: 8)
        #expect(PhotoFormat(head: heic) == .heif)
        #expect(FileEnd.judge(.heif, size: heic.count, bytes: FileBytes([(0, heic)])) == .whole)
        let short = heic.prefix(heic.count - 100)
        #expect(FileEnd.judge(.heif, size: short.count, bytes: FileBytes([(0, Data(short))])) == .early(missing: 100))
    }

    @Test func `formats are told from their first bytes, and extensions from their families`() {
        #expect(PhotoFormat(head: HealthImages.data(.jpeg)) == .jpeg)
        #expect(PhotoFormat(head: HealthImages.data(.png)) == .png)
        #expect(PhotoFormat(head: HealthImages.data(.tiff)) == .tiff)
        #expect(PhotoFormat(head: Data(count: 64)) == .unknown)
        #expect(PhotoFormat.jpeg.fits(name: "IMG_1.JPG") && !PhotoFormat.heif.fits(name: "IMG_1.JPG"))
        #expect(PhotoFormat.tiff.fits(name: "DSC_1.NEF") && PhotoFormat.tiff.fits(name: "IMG_1.CR2"))
        #expect(!PhotoFormat.jpeg.fits(name: "IMG_1.CR3") && PhotoFormat.cr3.fits(name: "IMG_1.cr3"))
        #expect(PhotoFormat.unknown.fits(name: "IMG_1.JPG"), "only a known format counts against a name")
        #expect(PhotoFormat.jpeg.fits(name: "P1000.RAW"), "an extension too loosely used to say")
    }
}
