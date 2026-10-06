import Foundation
import RedlampEngineAPI
import Synchronization
import Testing
@testable import RedlampDocument

/// Many photos' sidecars changed at once (`SidecarStore.change`), by the rules a single save keeps.
struct SidecarBatchTests {
    static let modified = Date(timeIntervalSince1970: 1_800_000_000)

    /// The keyword change a batch makes: "Batch" added, or nothing when the photo has it.
    static func tagged(_ sidecar: Sidecar?) -> SidecarChange {
        var sidecar = sidecar ?? Sidecar(recipe: EditRecipe())
        var metadata = sidecar.metadata ?? PhotoMetadata()
        guard metadata.keywords?.contains("Batch") != true else { return .keep }
        metadata.keywords = (metadata.keywords ?? []) + ["Batch"]
        sidecar.metadata = metadata
        sidecar.modified = modified
        return .saveOrRemove(sidecar)
    }

    /// What each photo of `Shoot` gets: tagged, emptied, labelled with `save`, or kept.
    static func change(_ number: Int, _ sidecar: Sidecar?) -> SidecarChange {
        switch Shoot.names[number] {
        case "E.ARW", "H.ARW":
            var emptied = sidecar ?? Sidecar(recipe: EditRecipe())
            emptied.metadata = nil
            emptied.modified = modified
            return .saveOrRemove(emptied)
        case "G.ARW":
            guard var labelled = sidecar else { return .keep }
            labelled.metadata = PhotoMetadata(rating: labelled.metadata?.rating ?? 0, label: .green)
            labelled.modified = modified
            return .save(labelled)
        default:
            return tagged(sidecar)
        }
    }

    /// Makes each change as the library's batches made them before, one sidecar at a time.
    static func singly(_ store: SidecarStore, _ images: [URL], _ make: (Int, Sidecar?) -> SidecarChange) throws {
        for (number, image) in images.enumerated() {
            switch make(number, store.load(for: image)) {
            case .keep: break
            case let .save(sidecar): try store.save(sidecar, for: image)
            case let .saveOrRemove(sidecar): try store.saveOrRemove(sidecar, for: image)
            }
        }
    }

    /// Runs a batch; its results by the photos' places.
    static func batch(
        _ store: SidecarStore, _ images: [URL], width: Int = SidecarStore.batchWidth,
        group: Int = SidecarStore.batchGroup,
        until stopped: @Sendable () -> Bool = { false }, _ make: @Sendable (Int, Sidecar?) -> SidecarChange,
    ) -> [Int: SidecarBatchResult] {
        let results = Mutex<[Int: SidecarBatchResult]>([:])
        store.change(
            images, width: width, group: group, edits: .renaming, until: stopped, make,
        ) { result in
            results.withLock { $0[result.index] = result }
        }
        return results.withLock { $0 }
    }

    static func failed(_ result: SidecarBatchResult?) -> (any Error)? {
        guard case let .failed(error) = result?.outcome else { return nil }
        return error
    }

    // MARK: - What it writes

    @Test func `a batch writes exactly what single saves write`() throws {
        let single = try Shoot()
        defer { single.remove() }
        let batched = try single.copy()
        defer { batched.remove() }

        try Self.singly(SidecarStore(), single.images, Self.change)
        let results = Self.batch(SidecarStore(), batched.images, width: 2, group: 3, Self.change)
        #expect(results.count == Shoot.names.count && results.values.allSatisfy { Self.failed($0) == nil })
        #expect(try batched.files() == single.files())
        #expect(SidecarStore().load(for: batched.url("A.ARW"))?.metadata?.keywords == ["Batch"])
        #expect(!FileManager.default.fileExists(atPath: SidecarStore().url(for: batched.url("E.ARW")).path))
        #expect(SidecarStore().load(for: batched.url("D.ARW"))?.recipe.maskBitmaps.first?.png == Shoot.png)
        if case .kept = try results[#require(Shoot.names.firstIndex(of: "F.ARW"))]?.outcome {} else {
            Issue.record("the photo that had the keyword is kept")
        }
    }

    @Test func `a batch reads and writes each sidecar where the locator says, as single saves do`() throws {
        let single = try Shoot()
        defer { single.remove() }
        let batched = try single.copy()
        defer { batched.remove() }
        let locator = { (shoot: Shoot) in
            SidecarLocator(folder: shoot.folder.appending(path: "Mac"), roots: [SidecarLocator.Root(
                path: shoot.photos.path, volume: "VOLUME", pathInVolume: "Shoot", onThisMac: true,
            )])
        }

        try Self.singly(SidecarStore(locator: locator(single)), single.images, Self.change)
        let results = Self.batch(SidecarStore(locator: locator(batched)), batched.images, Self.change)
        #expect(results.values.allSatisfy { Self.failed($0) == nil })
        #expect(try batched.files() == single.files())
        let moved = SidecarStore(locator: locator(batched))
        #expect(moved.url(for: batched.url("D.ARW")).path.contains("/Mac/VOLUME/Shoot/"))
        #expect(moved.load(for: batched.url("D.ARW"))?.recipe.maskBitmaps.first?.png == Shoot.png)
    }

    @Test func `sidecars the change leaves as they are aren't written`() throws {
        let shoot = try Shoot()
        defer { shoot.remove() }
        let store = SidecarStore()
        let images = ["B.ARW", "D.ARW", "F.ARW"].map(shoot.url)
        let before = try images.map { try Shoot.fileNumber(store.editURL(for: $0)) }

        let results = Self.batch(store, images) { number, sidecar in
            guard number == 1, var same = sidecar else { return number == 0 ? .keep : Self.tagged(sidecar) }
            same.modified = Date()
            return .saveOrRemove(same)
        }
        #expect(try images.map { try Shoot.fileNumber(store.editURL(for: $0)) } == before)
        if case .kept = results[0]?.outcome, case .saved = results[1]?.outcome, case .kept = results[2]?.outcome {
        } else {
            Issue.record("\(results)")
        }
    }

    // MARK: - Other writers

    @Test func `another writer's change during a batch is kept`() throws {
        let shoot = try Shoot()
        defer { shoot.remove() }
        let images = ["A.ARW", "B.ARW", "C.ARW", "D.ARW", "F.ARW", "G.ARW"].map(shoot.url)
        let blocked = DispatchSemaphore(value: 0)
        let results = Self.batch(SidecarStore(), images, width: 1, group: 2) { number, sidecar in
            if number == 0 {
                // A save of a photo the batch hasn't reached yet.
                try? Library.writeMetadata(for: images[5]) { $0.label = .red }
                // And one the batch holds: it waits for the batch to write it, then saves over that.
                Thread {
                    try? Library.writeMetadata(for: images[1]) { $0.flag = .pick }
                    blocked.signal()
                }.start()
                Thread.sleep(forTimeInterval: 0.2)
            }
            return Self.tagged(sidecar)
        }
        blocked.wait()
        #expect(results.values.allSatisfy { Self.failed($0) == nil })
        let store = SidecarStore()
        let later = try #require(store.load(for: images[5])?.metadata)
        #expect(later.label == .red && later.keywords == ["Batch"], "theirs, then the batch's on top")
        let held = try #require(store.load(for: images[1])?.metadata)
        #expect(held.flag == .pick && held.keywords == ["Batch"] && held.rating == 3, "the batch's, then theirs on top")
    }

    // MARK: - Protection

    /// Edits this build can't save over: a newer one's, one it can't decode, one it would save back
    /// changed, and a truncated one.
    static let protected = [
        (#"{"format":"app.redlamp.edit","recipe":{"version":99,"processVersion":1}}"#, "newer"),
        (
            #"{"format":"app.redlamp.edit","recipe":{"version":3,"processVersion":1,"treatment":"infrared"}}"#,
            "unreadable",
        ),
        (
            #"{"format":"app.redlamp.edit","recipe":{"version":3,"processVersion":1,"values":{"basic.exposure":9}}}"#,
            "lossy",
        ),
        (#"{"format":"app.redlamp.edit","recipe":{"version":3,"processVersion":1,"#, "unreadable"),
    ]

    @Test func `sidecars this build can't read or write back without loss are left alone, and the rest are saved`(
    ) throws {
        let shoot = try Shoot()
        defer { shoot.remove() }
        let store = SidecarStore()
        var images: [URL] = []
        for (number, (json, _)) in Self.protected.enumerated() {
            let image = shoot.photos.appending(path: "P\(number).ARW")
            let sidecar = store.url(for: image)
            if number.isMultiple(of: 2) {
                try FileManager.default.createDirectory(at: sidecar, withIntermediateDirectories: false)
            }
            try Data(json.utf8).write(to: store.editURL(for: image))
            images.append(image)
        }
        let locked = shoot.url("B.ARW")
        try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: store.editURL(for: locked).path)
        defer { try? FileManager.default.setAttributes(
            [.posixPermissions: 0o644],
            ofItemAtPath: store.editURL(for: locked).path,
        ) }
        let missing = shoot.folder.appending(path: "Gone/X.ARW")
        images += [shoot.url("A.ARW"), locked, missing, shoot.url("D.ARW")]
        let before = try images.prefix(Self.protected.count).map { try Data(contentsOf: store.editURL(for: $0)) }

        let results = Self.batch(store, images, width: 2, group: 2) { number, sidecar in
            // Every other protected one emptied, which would remove it.
            number < Self.protected.count && number.isMultiple(of: 2)
                ? .saveOrRemove(Sidecar(recipe: EditRecipe())) : Self.tagged(sidecar)
        }
        #expect(results.count == images.count)
        for (number, (_, kind)) in Self.protected.enumerated() {
            let expected: SidecarStoreError = switch kind {
            case "newer": .writtenByNewerVersion(store.url(for: images[number]))
            case "lossy": .lossy(store.url(for: images[number]))
            default: .unreadable(store.url(for: images[number]))
            }
            #expect(Self.failed(results[number]) as? SidecarStoreError == expected, "\(kind)")
            #expect(try Data(contentsOf: store.editURL(for: images[number])) == before[number])
        }
        #expect(Self.failed(results[5]) as? SidecarStoreError == .unreadable(store.url(for: locked)))
        #expect(Self.failed(results[6]) != nil, "its folder is gone")
        for number in [4, 7] {
            #expect(Self.failed(results[number]) == nil)
            #expect(store.load(for: images[number])?.metadata?.keywords == ["Batch"])
        }
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: store.editURL(for: locked).path)
        #expect(store.load(for: locked)?.metadata?.keywords == nil, "the edit that couldn't be opened is as it was")
    }

    // MARK: - Conflicting copies

    @Test func `conflicting copies are merged first, as a single save merges them`() throws {
        let single = try Shoot()
        defer { single.remove() }
        let batched = try single.copy()
        defer { batched.remove() }
        let (singleStore, singleCopies) = try Self.conflicting(single)
        let (batchStore, batchCopies) = try Self.conflicting(batched)

        try Self.singly(singleStore, single.images, Self.change)
        let results = Self.batch(batchStore, batched.images, width: 2, group: 3, Self.change)
        #expect(results.values.allSatisfy { Self.failed($0) == nil })
        for copies in [singleCopies, batchCopies] {
            #expect(copies.allSatisfy { $0.resolved.load(ordering: .relaxed) && $0.removed.load(ordering: .relaxed) })
        }
        let merged = try #require(batchStore.load(for: batched.url("B.ARW")))
        #expect(merged.recipe[.exposure] == 1.5 && merged.metadata?.label == .red && merged.metadata?.rating == 3)
        #expect(merged.metadata?.keywords == ["Batch"] && merged.snapshots.map(\.recipe[.exposure]) == [0.5])
        #expect(try Self.withoutSnapshotIDs(batched.files()) == Self.withoutSnapshotIDs(single.files()))
    }

    /// A store that finds a conflicting copy of B's sidecar, made on another Mac with a newer edit and a
    /// label, and its copies.
    static func conflicting(_ shoot: Shoot) throws -> (SidecarStore, [CopiedConflict]) {
        let copy = shoot.folder.appending(path: "Versions/B.ARW.redlamp")
        try FileManager.default.createDirectory(at: copy.deletingLastPathComponent(), withIntermediateDirectories: true)
        var recipe = EditRecipe()
        recipe[.exposure] = 1.5
        let theirs = Sidecar(
            recipe: recipe,
            metadata: PhotoMetadata(label: .red),
            modified: Date(timeIntervalSince1970: 1_700_000_500),
        )
        try SidecarStore().save(theirs, for: copy.deletingPathExtension())
        let conflicts = [CopiedConflict(url: copy)]
        let sidecar = SidecarStore().url(for: shoot.url("B.ARW")).path
        let store = SidecarStore(locator: .besidePhotos, conflicts: SidecarConflicts { url -> [any SidecarConflict] in
            guard url.path == sidecar else { return [] }
            return conflicts.filter { !$0.resolved.load(ordering: .relaxed) }
        })
        return (store, conflicts)
    }

    /// Snapshots made from conflicting copies get new IDs.
    static func withoutSnapshotIDs(_ files: [String: Data]) throws -> [String: Data] {
        try files.mapValues { data in
            guard let text = String(data: data, encoding: .utf8), text.contains("\"snapshots\"") else { return data }
            let pattern = try Regex(#""id" : "[0-9A-F-]{36}""#)
            return Data(text.replacing(pattern, with: #""id" : """#).utf8)
        }
    }

    // MARK: - Stopping and undoing

    @Test func `a batch stopped partway has written only what it reported, each sidecar whole`() throws {
        let shoot = try Shoot(extra: 200)
        defer { shoot.remove() }
        let store = SidecarStore()
        let reported = Mutex(0)
        let stop = 60
        let results = Self
            .batch(store, shoot.images, width: 4, group: 16, until: { reported.withLock { $0 >= stop } }) {
                _, sidecar in
                reported.withLock { $0 += 1 }
                return Self.tagged(sidecar)
            }
        #expect((stop ..< stop + 4).contains(results.count), "those under way finish")
        for (number, image) in shoot.images.enumerated() where Shoot.names.count <= number {
            let keywords = store.load(for: image)?.metadata?.keywords
            #expect(keywords == (results[number] == nil ? nil : ["Batch"]), "\(image.lastPathComponent)")
        }
        let leftovers = try FileManager.default.subpathsOfDirectory(atPath: shoot.photos.path).filter {
            ($0 as NSString).lastPathComponent.hasPrefix(".")
        }
        #expect(leftovers.isEmpty, "\(leftovers)")
    }

    @Test func `a batch is undone by another that puts back what each sidecar held`() throws {
        let shoot = try Shoot(extra: 150)
        defer { shoot.remove() }
        let store = SidecarStore()
        let before = shoot.images.map { store.load(for: $0) }
        let added = Self.batch(store, shoot.images) { _, sidecar in Self.tagged(sidecar) }
        #expect(added.values.allSatisfy { Self.failed($0) == nil })

        let undone = Self.batch(store, shoot.images) { number, sidecar in
            guard case .saveOrRemove = added[number]?.change, var sidecar else { return .keep }
            sidecar.metadata?.keywords = added[number]?.sidecar?.metadata?.keywords
            sidecar.metadata = sidecar.metadata.flatMap { $0.isEmpty ? nil : $0 }
            sidecar.modified = added[number]?.sidecar?.modified ?? Self.modified
            return .saveOrRemove(sidecar)
        }
        #expect(undone.count == shoot.images.count && undone.values.allSatisfy { Self.failed($0) == nil })
        for (number, image) in shoot.images.enumerated() {
            let now = store.load(for: image)
            let same = before[number].map { now?.hasSameContent(as: $0) == true } ?? (now == nil)
            #expect(same, "\(image.lastPathComponent)")
        }
    }
}

/// A conflicting copy of a sidecar as iCloud Drive keeps one, at `url`.
final class CopiedConflict: SidecarConflict, Sendable {
    let url: URL
    let resolved = Atomic(false)
    let removed = Atomic(false)

    init(url: URL) {
        self.url = url
    }

    func resolve() {
        resolved.store(true, ordering: .relaxed)
    }

    func remove() throws {
        try FileManager.default.removeItem(at: url)
        removed.store(true, ordering: .relaxed)
    }
}

/// A shoot's photos with sidecars of every kind a batch meets: none, a package with an edit, a rating
/// and fields a newer Redlamp added, a single-file sidecar from before packages, one with a mask, a
/// snapshot and a history session, one with only a rating, one with the keyword already, one to be
/// labelled and one with nothing but history; and `extra` more, every other one with a sidecar.
struct Shoot {
    static let names = ["A.ARW", "B.ARW", "C.ARW", "D.ARW", "E.ARW", "F.ARW", "G.ARW", "H.ARW"]
    static let png = Data("a mask's png".utf8)
    let folder: URL
    let images: [URL]

    var photos: URL {
        folder.appending(path: "Shoot", directoryHint: .isDirectory)
    }

    func url(_ name: String) -> URL {
        photos.appending(path: name)
    }

    init(extra: Int = 0) throws {
        folder = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString, directoryHint: .isDirectory)
        let photos = folder.appending(path: "Shoot", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: photos, withIntermediateDirectories: true)
        images = (Self.names + (0 ..< extra).map { String(format: "IMG_%04d.JPG", $0) })
            .map { photos.appending(path: $0) }
        try Self.write(images, extra: extra)
    }

    private init(folder: URL, images: [URL]) {
        self.folder = folder
        self.images = images
    }

    private static func write(_ images: [URL], extra: Int) throws {
        let store = SidecarStore()
        let at = Date(timeIntervalSince1970: 1_700_000_000)
        var edit = EditRecipe()
        edit[.exposure] = 0.5
        var b = Sidecar(recipe: edit, metadata: PhotoMetadata(rating: 3), modified: at)
        b.unknownFields = ["fromTheFuture": .string("kept")]
        b.metadata?.unknownFields = ["caption": .string("Dawn")]
        try store.save(b, for: images[1])
        let legacy = #"{"format":"app.redlamp.edit","recipe":{"version":2,"processVersion":1,"values":{"basic.exposure":0.25}}}"#
        try Data(legacy.utf8).write(to: store.url(for: images[2]))
        var masked = edit
        masked.masks = [MaskLayer(name: "Subject", components: [MaskComponent(shape: .ai(AIMask(
            kind: .subject, provider: "test", revision: 1, analysisHash: "0", center: ImagePoint(x: 0.5, y: 0.5),
            bitmap: MaskBitmap(png: png, width: 4, height: 2), createdAt: at,
        )))])]
        let session = HistorySession(started: at, steps: [
            HistoryStep(action: .open, title: "Opened", recipe: EditRecipe()),
            HistoryStep(action: .adjustment(.exposure), title: "Exposure", recipe: masked),
        ])
        try store.save(Sidecar(
            recipe: masked, snapshots: [Snapshot(name: "Before", created: at, recipe: edit)], modified: at,
            session: session,
        ), for: images[3])
        try store.save(Sidecar(recipe: EditRecipe(), metadata: PhotoMetadata(rating: 2), modified: at), for: images[4])
        try store.save(
            Sidecar(recipe: edit, metadata: PhotoMetadata(keywords: ["Batch"]), modified: at), for: images[5],
        )
        try store.save(Sidecar(recipe: edit, metadata: PhotoMetadata(rating: 1), modified: at), for: images[6])
        try store.save(
            Sidecar(recipe: EditRecipe(), metadata: PhotoMetadata(rating: 1), modified: at, session: session),
            for: images[7],
        )
        for number in stride(from: 0, to: extra, by: 2) {
            try store.save(
                Sidecar(recipe: edit, metadata: PhotoMetadata(rating: 4), modified: at),
                for: images[names.count + number],
            )
        }
    }

    /// The same shoot in a folder of its own.
    func copy() throws -> Shoot {
        let copy = FileManager.default.temporaryDirectory.appending(
            path: UUID().uuidString,
            directoryHint: .isDirectory,
        )
        try FileManager.default.copyItem(at: folder, to: copy)
        return Shoot(
            folder: copy,
            images: images.map { copy.appending(path: "Shoot").appending(path: $0.lastPathComponent) },
        )
    }

    func remove() {
        try? FileManager.default.removeItem(at: folder)
    }

    /// Every file and folder below the shoot's folder, by its path there: a file's bytes, or nothing
    /// for a folder.
    func files() throws -> [String: Data] {
        var files: [String: Data] = [:]
        for path in try FileManager.default.subpathsOfDirectory(atPath: folder.path) {
            let url = folder.appending(path: path)
            var isDirectory: ObjCBool = false
            _ = FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory)
            files[path] = isDirectory.boolValue ? Data() : try Data(contentsOf: url)
        }
        return files
    }

    /// The file's inode: an atomic write replaces the file, so a rewrite changes it.
    static func fileNumber(_ url: URL) throws -> Int? {
        try FileManager.default.attributesOfItem(atPath: url.path)[.systemFileNumber] as? Int
    }
}
