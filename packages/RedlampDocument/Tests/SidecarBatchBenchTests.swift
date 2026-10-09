import Foundation
import RedlampEngineAPI
import Synchronization
import Testing
@testable import RedlampDocument

/// What saving many small sidecars costs on this Mac (LIB-21, LIB-26, LIB-15): a save one at a time,
/// broken into its parts beside bare writes of the same size; how many saves in flight help;
/// coordinating many sidecars at once; the batch (`SidecarStore.change`), each of its ideas on its
/// own, beside the disk's own cost for what it does; and sidecars removed. Run with
/// `REDLAMP_SIDECAR_BENCH=1` (which xcodebuild hands to the tests from
/// `TEST_RUNNER_REDLAMP_SIDECAR_BENCH=1`), or a list of `parts`, `flight`, `batch`, `placement`,
/// `floor`, `removal` and `coordination`, on `REDLAMP_SIDECAR_BENCH_PHOTOS` photos (10,000 by
/// default) in folders of 500 in the temporary folder, every other one with a sidecar holding an edit
/// and a rating, as the keywords scenario has them.
@Suite(.serialized)
struct SidecarBatchBenchTests {
    static let environment = ProcessInfo.processInfo.environment
    static let photos = environment["REDLAMP_SIDECAR_BENCH_PHOTOS"].flatMap { Int($0) } ?? 10000

    static func enabled(_ part: String) -> Bool {
        let parts = environment["REDLAMP_SIDECAR_BENCH"]?.split(separator: ",").map(String.init) ?? []
        return parts == ["1"] || parts.contains(part)
    }

    @Test(.enabled(if: enabled("parts")))
    func `a save one at a time, in its parts, beside bare writes of the same size`() throws {
        let count = Self.photos
        let store = SidecarStore()
        BenchFixture.report("\(count) photos, load average \(BenchFixture.loadAverage())")

        var fixture = try BenchFixture(count)
        try BenchFixture.measure("A save as the batches make it: load, change, saveOrRemove", count) {
            for image in fixture.images {
                try BenchFixture.save(image, store: store)
            }
        }
        let written = try Data(contentsOf: store.editURL(for: fixture.images[1]))
        fixture.remove()

        fixture = try BenchFixture(count)
        let sidecars = fixture.images.map(store.url(for:))
        BenchFixture.measure("Write coordination alone", count) {
            for sidecar in sidecars {
                BenchFixture.coordinate(writing: sidecar)
            }
        }
        BenchFixture.measure("Read coordination alone", count) {
            for sidecar in sidecars {
                BenchFixture.coordinate(reading: sidecar)
            }
        }
        BenchFixture.measure("NSFileVersion's conflict versions looked up", count) {
            for sidecar in sidecars {
                _ = NSFileVersion.unresolvedConflictVersionsOfItem(at: sidecar)
            }
        }
        BenchFixture.measure("Where the sidecar is read (SidecarLocator.readURL)", count) {
            for image in fixture.images {
                _ = store.locator.readURL(for: image)
            }
        }
        var data = [Data?](repeating: nil, count: count)
        BenchFixture.measure("The edit read, or found missing (half are)", count) {
            for (number, sidecar) in sidecars.enumerated() {
                data[number] = try? SidecarStore.editData(inSidecar: sidecar)
            }
        }
        let existing = data.compactMap(\.self)
        try BenchFixture.measure("Decoded and checked for loss, in memory", existing.count) {
            for edit in existing {
                _ = try JSONDecoder.sidecar.decode(Sidecar.self, from: edit)
                _ = SidecarStore.protection(edit)
            }
        }
        let sidecar = try JSONDecoder.sidecar.decode(Sidecar.self, from: written)
        try BenchFixture.measure("Encoded, in memory", count) {
            for _ in 0 ..< count {
                _ = try JSONEncoder.sidecar.encode(sidecar)
            }
        }
        try BenchFixture.measure("edit.json written atomically into its package", existing.count) {
            for sidecar in sidecars where SidecarStore.isPackage(sidecar) {
                try written.write(to: sidecar.appending(path: SidecarStore.editFile), options: .atomic)
            }
        }
        try BenchFixture.measure("A new package built beside its photo and moved in", count - existing.count) {
            for sidecar in sidecars where !SidecarStore.isPackage(sidecar) {
                try BenchFixture.newPackage(written, at: sidecar)
            }
        }
        fixture.remove()
        try BenchFixture.bareWrites(written, count: count)
    }

    @Test(.enabled(if: enabled("flight")))
    func `saves several at a time, and how many in flight help`() throws {
        let count = Self.photos
        let store = SidecarStore()
        BenchFixture.report("\(count) photos, load average \(BenchFixture.loadAverage())")
        for width in [2, 4, 8, 16, 32] {
            let fixture = try BenchFixture(count)
            BenchFixture.measure("\(width) saves in flight: load, change, saveOrRemove", count) {
                BenchFixture.inFlight(width, count) { number in
                    try? BenchFixture.save(fixture.images[number], store: store)
                }
            }
            let sidecars = fixture.images.map(store.url(for:))
            BenchFixture.measure("\(width) write coordinations in flight, nothing in them", count) {
                BenchFixture.inFlight(width, count) { number in
                    BenchFixture.coordinate(writing: sidecars[number])
                }
            }
            let written = try Data(contentsOf: store.editURL(for: fixture.images[1]))
            BenchFixture.measure("\(width) atomic writes of edit.json in flight", count) {
                BenchFixture.inFlight(width, count) { number in
                    try? written.write(to: sidecars[number].appending(path: SidecarStore.editFile), options: .atomic)
                }
            }
            fixture.remove()
        }
    }

    @Test(.enabled(if: enabled("batch")))
    func `a batch, and what each of its ideas buys`() throws {
        let count = Self.photos
        let store = SidecarStore()
        BenchFixture.report("\(count) photos, load average \(BenchFixture.loadAverage())")
        struct Variant {
            let label: String, width: Int, group: Int, edits: EditWriter

            init(_ label: String, _ width: Int, _ group: Int, _ edits: EditWriter) {
                (self.label, self.width, self.group, self.edits) = (label, width, group, edits)
            }
        }
        let variants: [Variant] = [
            Variant("A batch one at a time: one coordination each, the edit read once", 1, 1, .foundation),
            Variant("Coordinated 64 at a time", 1, 64, .foundation),
            Variant("Coordinated 64 at a time, 8 groups in flight", 8, 64, .foundation),
            Variant("The same, each edit renamed into place in its package", 8, 64, EditWriter(
                replace: SidecarStore.writeByRenaming, create: SidecarStore.writeByRenaming,
            )),
            Variant("The same, a new package's edit written as it is: the batch as it ships", 8, 64, .renaming),
            Variant("The same, renamed in from beside the package", 8, 64, BenchFixture.beside),
            Variant("The same, 4 groups in flight", 4, 64, .renaming),
            Variant("The same, 16 groups in flight", 16, 64, .renaming),
            Variant("The same, 8 groups of 16 in flight", 8, 16, .renaming),
            Variant("The same, 8 groups of 256 in flight", 8, 256, .renaming),
        ]
        for variant in variants {
            let (label, width, group, edits) = (variant.label, variant.width, variant.group, variant.edits)
            let fixture = try BenchFixture(count)
            let failures = BenchFixture.Counter()
            BenchFixture.measure(label, count) {
                store.change(fixture.images, width: width, group: group, edits: edits, until: { false }) { _, sidecar in
                    BenchFixture.keywordAdded(to: sidecar)
                } done: { result in
                    if case .failed = result.outcome {
                        _ = failures.next()
                    }
                }
            }
            #expect(failures.next() == 0 && BenchFixture.wrong(fixture.images, store: store) == 0, "\(label)")
            if label.hasSuffix("ships") {
                BenchFixture.measure("The batch again, every sidecar holding the keyword already", count) {
                    store.change(fixture.images) { _, sidecar in
                        BenchFixture.keywordAdded(to: sidecar)
                    } done: { _ in }
                }
                fixture.remove()
                try BenchFixture.floor(count)
            } else {
                fixture.remove()
            }
        }
    }

    @Test(.enabled(if: enabled("placement")))
    func `the edit renamed in from beside its package or from inside it, taken in turns`() throws {
        let count = Self.photos
        let store = SidecarStore()
        BenchFixture.report("\(count) photos, load average \(BenchFixture.loadAverage())")
        for (label, edits) in [
            ("beside", BenchFixture.beside), ("inside", .renaming), ("beside", BenchFixture.beside), (
                "inside",
                .renaming,
            ),
        ] {
            let fixture = try BenchFixture(count)
            BenchFixture.measure("The batch, each edit renamed in from \(label) its package", count) {
                store.change(fixture.images, width: 8, group: 64, edits: edits, until: { false }) { _, sidecar in
                    BenchFixture.keywordAdded(to: sidecar)
                } done: { _ in }
            }
            #expect(BenchFixture.wrong(fixture.images, store: store) == 0)
            fixture.remove()
        }
    }

    @Test(.enabled(if: enabled("removal")))
    func `sidecars emptied and removed, one at a time and in a batch, beside the disk's own cost`() throws {
        let count = Self.photos
        let store = SidecarStore()
        BenchFixture.report("\(count) photos, load average \(BenchFixture.loadAverage())")
        let keyworded = try JSONEncoder.sidecar.encode(Sidecar(
            recipe: EditRecipe(), metadata: PhotoMetadata(keywords: [BenchFixture.keyword]),
            modified: Date(timeIntervalSince1970: 1_790_000_000),
        ))
        var fixture = try BenchFixture(count / 4, every: 1, holding: keyworded)
        BenchFixture.measure("One at a time: load, the keyword taken off, saveOrRemove removing it", count / 4) {
            for image in fixture.images {
                var sidecar = store.load(for: image) ?? Sidecar(recipe: EditRecipe())
                sidecar.metadata = nil
                try? store.saveOrRemove(sidecar, for: image)
            }
        }
        fixture.remove()
        fixture = try BenchFixture(count, every: 1, holding: keyworded)
        BenchFixture.measure("A batch: the keyword taken off, every sidecar removed", count) {
            store.change(fixture.images) { _, sidecar in
                guard var sidecar else { return .keep }
                sidecar.metadata = nil
                return .saveOrRemove(sidecar)
            } done: { _ in }
        }
        #expect(fixture.images.allSatisfy { !FileManager.default.fileExists(atPath: store.url(for: $0).path) })
        fixture.remove()
        fixture = try BenchFixture(count, every: 1, holding: keyworded)
        let sidecars = fixture.images.map { store.url(for: $0) }
        BenchFixture.measure(
            "Bare, 8 at a time: each renamed to a hidden name, then FileManager.removeItem",
            count / 2,
        ) {
            BenchFixture.inFlight(8, count / 2) { number in
                let hidden = SidecarStore.hiddenSibling(of: sidecars[number])
                try? FileManager.default.moveItem(at: sidecars[number], to: hidden)
                try? FileManager.default.removeItem(at: hidden)
            }
        }
        BenchFixture.measure("Bare, 8 at a time: each renamed to a hidden name, its edit unlinked, rmdir", count / 2) {
            BenchFixture.inFlight(8, count / 2) { number in
                let hidden = SidecarStore.hiddenSibling(of: sidecars[count / 2 + number]).path
                _ = rename(sidecars[count / 2 + number].path, hidden)
                _ = unlink(hidden + "/" + SidecarStore.editFile)
                _ = rmdir(hidden)
            }
        }
        fixture.remove()
    }

    @Test(.enabled(if: enabled("floor")))
    func `the disk's own cost for what each sidecar needs, 8 at a time`() throws {
        let count = Self.photos
        BenchFixture.report("\(count) files, load average \(BenchFixture.loadAverage())")
        let edit = try BenchFixture.edit()
        let folder = FileManager.default.temporaryDirectory
            .appending(path: "redlamp-sidecar-bench-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: folder) }
        let folders = (0 ..< (count + BenchFixture.folderSize - 1) / BenchFixture.folderSize).map {
            folder.appending(path: String(format: "Day %03d", $0 + 1)).path
        }
        let files = (0 ..< count).map { folders[$0 / BenchFixture.folderSize] + String(format: "/IMG_%05d.json", $0) }
        for path in folders {
            try FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true)
        }
        for file in files {
            try edit.write(to: URL(fileURLWithPath: file))
        }
        BenchFixture.measure(
            "Bare, 8 at a time: each file read, a new one written beside it and renamed over it",
            count,
        ) {
            BenchFixture.inFlight(8, count) { number in
                BenchFixture.rewrite(files[number], with: edit)
            }
        }
        BenchFixture.measure("The same, spread across the folders", count) {
            let perFolder = BenchFixture.folderSize
            BenchFixture.inFlight(8, count) { number in
                // Folder by folder for each thread: the n-th file of every folder before the next.
                let file = (number % folders.count) * perFolder + number / folders.count
                if file < count {
                    BenchFixture.rewrite(files[file], with: edit)
                }
            }
        }
        for file in files {
            unlink(file)
        }
        BenchFixture.measure(
            "Bare, 8 at a time: a folder made, a file written in it and the folder renamed in",
            count / 2,
        ) {
            BenchFixture.inFlight(8, count / 2) { number in
                let staging = (files[number] as NSString).deletingLastPathComponent + "/.staging-\(number)"
                guard mkdir(staging, 0o755) == 0 else { return }
                try? BenchFixture.write(edit, to: staging + "/edit.json", flags: O_CREAT | O_EXCL)
                _ = rename(staging, files[number] + ".redlamp")
            }
        }
    }

    @Test(.enabled(if: enabled("coordination")))
    func `coordinating many sidecars at once`() throws {
        let count = Self.photos
        let store = SidecarStore()
        BenchFixture.report("\(count) photos, load average \(BenchFixture.loadAverage())")
        let fixture = try BenchFixture(count)
        defer { fixture.remove() }
        let sidecars = fixture.images.map(store.url(for:))
        BenchFixture.measure("Read and write coordination of each, in one call", count) {
            for sidecar in sidecars {
                BenchFixture.coordinate(readingAndWriting: sidecar)
            }
        }
        for chunk in [1, 16, 64, 256, 1024] {
            BenchFixture.measure("\(chunk) at once: a read and a write intent each, nothing in them", count) {
                for start in stride(from: 0, to: count, by: chunk) {
                    BenchFixture.coordinate(Array(sidecars[start ..< min(start + chunk, count)]))
                }
            }
        }
        for chunk in [64, 256] {
            BenchFixture.measure("\(chunk) prepared at once, then each coordinated", count) {
                for start in stride(from: 0, to: count, by: chunk) {
                    BenchFixture.prepare(Array(sidecars[start ..< min(start + chunk, count)]))
                }
            }
        }
        for width in [4, 8, 16] {
            BenchFixture.measure("64 at once, \(width) such batches in flight", count) {
                let chunks = stride(from: 0, to: count, by: 64).map { Array(sidecars[$0 ..< min($0 + 64, count)]) }
                BenchFixture.inFlight(width, chunks.count) { number in
                    BenchFixture.coordinate(chunks[number])
                }
            }
        }
    }
}

/// Photos in folders of 500, every other one with a sidecar package holding an edit and a rating; the
/// photos' files themselves aren't needed.
struct BenchFixture {
    static let folderSize = 500
    let folder: URL
    let images: [URL]

    /// `count` photos, every `every`-th with a sidecar holding `edit` (an edit and a rating when nil).
    init(_ count: Int, every: Int = 2, holding edit: Data? = nil) throws {
        folder = FileManager.default.temporaryDirectory
            .appending(path: "redlamp-sidecar-bench-\(UUID().uuidString)", directoryHint: .isDirectory)
        let folder = folder
        images = (0 ..< count).map { number in
            folder.appending(path: String(format: "Day %03d/IMG_%05d.JPG", number / Self.folderSize + 1, number))
        }
        for start in stride(from: 0, to: count, by: Self.folderSize) {
            try FileManager.default.createDirectory(
                at: images[start].deletingLastPathComponent(), withIntermediateDirectories: true,
            )
        }
        let edit = try edit ?? Self.edit()
        for image in stride(from: 0, to: count, by: every).map({ images[$0] }) {
            let package = SidecarLocator.besidePhoto(image)
            try FileManager.default.createDirectory(at: package, withIntermediateDirectories: false)
            try edit.write(to: package.appending(path: SidecarStore.editFile))
        }
    }

    func remove() {
        try? FileManager.default.removeItem(at: folder)
    }

    /// A sidecar with an edit and a rating, as `SidecarStore` writes it.
    static func edit() throws -> Data {
        var recipe = EditRecipe()
        recipe[.exposure] = 0.35
        recipe[.contrast] = 12
        return try JSONEncoder.sidecar.encode(Sidecar(
            recipe: recipe, metadata: PhotoMetadata(rating: 3), modified: Date(timeIntervalSince1970: 1_790_000_000),
        ))
    }

    static let keyword = "Clients/Acme/Picked"

    /// Each edit written beside its package, named as an interrupted save's leftovers are, and renamed
    /// into it.
    static let beside = EditWriter(replace: { data, file in
        let temporary = SidecarStore.hiddenSibling(of: file.deletingLastPathComponent())
        try SidecarStore.create(data, at: temporary)
        guard rename(temporary.path, file.path) == 0 else { throw POSIXError(.EIO) }
    }, create: SidecarStore.create)

    /// The change the keywords batch makes, saved as it saved it.
    static func save(_ image: URL, store: SidecarStore) throws {
        var sidecar = store.load(for: image) ?? Sidecar(recipe: EditRecipe())
        var metadata = sidecar.metadata ?? PhotoMetadata()
        metadata.keywords = (metadata.keywords ?? []) + [keyword]
        sidecar.metadata = metadata
        sidecar.modified = Date()
        try store.saveOrRemove(sidecar, for: image)
    }

    /// The same change as a batch makes it.
    static func keywordAdded(to sidecar: Sidecar?) -> SidecarChange {
        var sidecar = sidecar ?? Sidecar(recipe: EditRecipe())
        var metadata = sidecar.metadata ?? PhotoMetadata()
        guard metadata.keywords?.contains(keyword) != true else { return .keep }
        metadata.keywords = (metadata.keywords ?? []) + [keyword]
        sidecar.metadata = metadata
        sidecar.modified = Date()
        return .saveOrRemove(sidecar)
    }

    /// How many of the photos' sidecars don't hold the keyword, or lost their edit or rating.
    static func wrong(_ images: [URL], store: SidecarStore) -> Int {
        images.enumerated().count { number, image in
            let sidecar = store.load(for: image)
            let kept = number % 2 == 1 || sidecar?.recipe[.exposure] == 0.35 && sidecar?.metadata?.rating == 3
            return sidecar?.metadata?.keywords != [keyword] || !kept
        }
    }

    // MARK: - Coordination

    static func coordinate(writing url: URL) {
        var error: NSError?
        NSFileCoordinator(filePresenter: nil).coordinate(writingItemAt: url, options: [], error: &error) { _ in }
    }

    static func coordinate(reading url: URL) {
        var error: NSError?
        NSFileCoordinator(filePresenter: nil).coordinate(readingItemAt: url, options: [], error: &error) { _ in }
    }

    static func coordinate(readingAndWriting url: URL) {
        var error: NSError?
        NSFileCoordinator(filePresenter: nil).coordinate(
            readingItemAt: url, options: [], writingItemAt: url, options: [], error: &error,
        ) { _, _ in }
    }

    /// One coordination for every sidecar of `urls`, a read and a write intent each.
    static func coordinate(_ urls: [URL]) {
        let intents = urls.flatMap { url in
            [NSFileAccessIntent.readingIntent(with: url, options: []), .writingIntent(with: url, options: [])]
        }
        let done = DispatchSemaphore(value: 0)
        NSFileCoordinator(filePresenter: nil).coordinate(with: intents, queue: OperationQueue()) { _ in
            done.signal()
        }
        done.wait()
    }

    static func prepare(_ urls: [URL]) {
        let coordinator = NSFileCoordinator(filePresenter: nil)
        var error: NSError?
        coordinator.prepare(
            forReadingItemsAt: urls, options: [], writingItemsAt: urls, options: [], error: &error,
        ) { completion in
            for url in urls {
                var error: NSError?
                coordinator.coordinate(writingItemAt: url, options: [], error: &error) { _ in }
            }
            completion()
        }
    }

    // MARK: - Files

    /// What a save does to make a sidecar that isn't there: a hidden package beside the photo with
    /// the edit in it, moved into place.
    static func newPackage(_ edit: Data, at sidecar: URL) throws {
        let staging = SidecarStore.hiddenSibling(of: sidecar)
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: false)
        try edit.write(to: staging.appending(path: SidecarStore.editFile), options: .atomic)
        try FileManager.default.moveItem(at: staging, to: sidecar)
    }

    /// The disk's own costs for files of the edit's size, with nothing of Redlamp's around them.
    static func bareWrites(_ edit: Data, count: Int) throws {
        let folder = FileManager.default.temporaryDirectory
            .appending(path: "redlamp-sidecar-bench-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: folder) }
        let files = (0 ..< count).map { number in
            folder.appending(path: String(format: "Day %03d/IMG_%05d.json", number / folderSize + 1, number)).path
        }
        for start in stride(from: 0, to: count, by: folderSize) {
            try FileManager.default.createDirectory(
                atPath: (files[start] as NSString).deletingLastPathComponent, withIntermediateDirectories: true,
            )
        }
        try measure("Bare: a new file of the edit's size written (open, write, close)", count) {
            for file in files {
                try write(edit, to: file, flags: O_CREAT | O_EXCL)
            }
        }
        try measure("Bare: the same files written over in place", count) {
            for file in files {
                try write(edit, to: file, flags: O_TRUNC)
            }
        }
        try measure("Bare: each written to a new file, then renamed over it", count) {
            for file in files {
                try write(edit, to: file + ".new", flags: O_CREAT | O_EXCL)
                guard rename(file + ".new", file) == 0 else { throw POSIXError(.EIO) }
            }
        }
        try measure("Bare: Data.write(options: .atomic) over it", count) {
            for file in files {
                try edit.write(to: URL(fileURLWithPath: file), options: .atomic)
            }
        }
        measure("Bare: a stat of each", count) {
            var info = stat()
            for file in files {
                _ = stat(file, &info)
            }
        }
        for width in [4, 8, 16] {
            measure("Bare: \(width) at a time, each written to a new file and renamed over it", count) {
                inFlight(width, count) { number in
                    try? write(edit, to: files[number] + ".new", flags: O_CREAT | O_EXCL)
                    _ = rename(files[number] + ".new", files[number])
                }
            }
        }
    }

    /// The disk's own cost for what the batch does on the same photos, 8 at a time: for those with a
    /// sidecar, the edit read, a new one written beside it and renamed over it; for the rest, a folder
    /// made, the edit written in it and the folder renamed into place.
    static func floor(_ count: Int) throws {
        let fixture = try BenchFixture(count)
        defer { fixture.remove() }
        let edit = try edit()
        let sidecars = fixture.images.map(SidecarLocator.besidePhoto)
        measure("Bare, on the same photos, 8 at a time: what the batch does to the disk", count) {
            inFlight(8, count) { number in
                let sidecar = sidecars[number].path
                if number.isMultiple(of: 2) {
                    rewrite(sidecar + "/edit.json", with: edit)
                } else {
                    let staging = (sidecar as NSString).deletingLastPathComponent + "/.staging-\(number)"
                    guard mkdir(staging, 0o755) == 0 else { return }
                    try? write(edit, to: staging + "/edit.json", flags: O_CREAT | O_EXCL)
                    _ = rename(staging, sidecar)
                }
            }
        }
    }

    /// What a batch does to the disk for a sidecar that's there: the edit read, the new one written
    /// beside it and renamed over it.
    static func rewrite(_ file: String, with edit: Data) {
        _ = FileManager.default.contents(atPath: file)
        try? write(edit, to: file + ".new", flags: O_CREAT | O_EXCL)
        _ = rename(file + ".new", file)
    }

    static func write(_ data: Data, to path: String, flags: Int32) throws {
        let descriptor = open(path, O_WRONLY | O_CLOEXEC | flags, 0o644)
        guard descriptor >= 0 else { throw POSIXError(.EIO) }
        defer { close(descriptor) }
        let written = data.withUnsafeBytes { Darwin.write(descriptor, $0.baseAddress, $0.count) }
        guard written == data.count else { throw POSIXError(.EIO) }
    }

    // MARK: - Timing

    /// Runs `body` for each of `count` items, on `width` threads of its own.
    static func inFlight(_ width: Int, _ count: Int, _ body: @escaping @Sendable (Int) -> Void) {
        let counter = Counter()
        let done = DispatchGroup()
        for _ in 0 ..< width {
            done.enter()
            Thread {
                var number = counter.next()
                while number < count {
                    body(number)
                    number = counter.next()
                }
                done.leave()
            }.start()
        }
        done.wait()
    }

    final class Counter: Sendable {
        private let value = Atomic(0)

        func next() -> Int {
            value.add(1, ordering: .relaxed).oldValue
        }
    }

    static func measure(_ label: String, _ count: Int, _ body: () throws -> Void) rethrows {
        let clock = ContinuousClock()
        let started = clock.now
        try body()
        let seconds = (clock.now - started).seconds
        let perItem = seconds * 1000 / Double(max(count, 1))
        let padded = label.padding(toLength: max(label.count, 78), withPad: " ", startingAt: 0)
        report(
            "\(padded) \(String(format: "%7.3f", perItem)) ms each, \(String(format: "%7.2f", seconds)) s for \(count)",
        )
    }

    static func report(_ line: String) {
        print("SIDECAR-BENCH \(line)")
    }

    static func loadAverage() -> String {
        var loads = [Double](repeating: 0, count: 3)
        getloadavg(&loads, 3)
        return loads.map { String(format: "%.0f", $0) }.joined(separator: " ")
    }
}

extension Duration {
    var seconds: Double {
        Double(components.seconds) + Double(components.attoseconds) / 1e18
    }
}
