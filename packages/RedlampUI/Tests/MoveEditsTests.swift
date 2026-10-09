import AppKit
import CoreGraphics
import Foundation
import ImageIO
import RedlampDocument
import RedlampEngineAPI
import RedlampLibrary
import Testing
import UniformTypeIdentifiers
@_spi(Harness) @testable import RedlampUI

/// Move Edits and Metadata… (LIB-11, DEC-43): a root's sidecars moved to this Mac and back with every byte kept, the
/// root's placement and the app's locator following; Cancel putting back what moved; a launch finishing a move a quit
/// interrupted, from the library's journal and then from the disk; refusals in words; the sheet's numbers from the
/// index; the open photo's edit saved before it moves.
@MainActor
struct MoveEditsTests {
    /// A root of small JPEGs the library has indexed, in a library and defaults of its own, and an editor on it.
    @MainActor
    final class Folder {
        let base = FileManager.default.temporaryDirectory
            .appending(path: "move-edits-\(UUID().uuidString)", directoryHint: .isDirectory).standardizedFileURL
        let suite = "move-edits-tests-\(UUID().uuidString)"
        private(set) var library: FolderLibrary!
        private(set) var service: LibraryService!
        private(set) var model: EditorModel!

        var root: URL {
            base.appending(path: "Photos", directoryHint: .isDirectory)
        }

        var paths: LibraryPaths {
            LibraryPaths(root: base.appending(path: "Library", directoryHint: .isDirectory))
        }

        var defaults: UserDefaults {
            UserDefaults(suiteName: suite)!
        }

        func photo(_ name: String) -> URL {
            root.appending(path: name, directoryHint: .notDirectory)
        }

        /// JPEGs at `names` below the root, each its own colour, every one in `edited` with a sidecar of its own.
        func write(_ names: [String], edited: Set<String>) throws {
            for (number, name) in names.enumerated() {
                let url = photo(name)
                try FileManager.default.createDirectory(
                    at: url.deletingLastPathComponent(), withIntermediateDirectories: true,
                )
                let space = try #require(CGColorSpace(name: CGColorSpace.sRGB))
                let context = try #require(CGContext(
                    data: nil, width: 32, height: 24, bitsPerComponent: 8, bytesPerRow: 0, space: space,
                    bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue,
                ))
                context.setFillColor(
                    red: CGFloat(number % 7) / 7, green: CGFloat(number % 5) / 5, blue: CGFloat(number % 11) / 11,
                    alpha: 1,
                )
                context.fill(CGRect(x: 0, y: 0, width: 32, height: 24))
                let data = NSMutableData()
                let destination = try #require(CGImageDestinationCreateWithData(
                    data, UTType.jpeg.identifier as CFString, 1, nil,
                ))
                try CGImageDestinationAddImage(destination, #require(context.makeImage()), nil)
                #expect(CGImageDestinationFinalize(destination))
                try (data as Data).write(to: url)
                if edited.contains(name) {
                    var recipe = EditRecipe()
                    recipe[.exposure] = Double(number % 9) / 10
                    try SidecarStore().save(
                        Sidecar(recipe: recipe, metadata: PhotoMetadata(rating: number % 5 + 1)), for: url,
                    )
                }
            }
        }

        /// Opens the library on the root, as a launch does, and waits until it has indexed it.
        func open() async throws {
            library = FolderLibrary(defaults: defaults)
            if library.roots.isEmpty {
                library.add([root])
            }
            service = LibraryService(paths: paths, sidecars: library.sidecars, defaults: defaults) { url, size in
                StoreThumbnailMaker.imageIO(url, nil, size)
            }
            library.attach(service)
            model = EditorModel(engine: StubEngine(), library: library)
            for _ in 0 ..< 2000 where await !service.canShow(root, includingSubfolders: true) {
                try await Task.sleep(for: .milliseconds(10))
            }
            try #require(await service.canShow(root, includingSubfolders: true), "the library didn't index the root")
        }

        /// As the app quits.
        func close() {
            service?.close()
            service = nil
            model = nil
            library = nil
        }

        func cleanUp() {
            close()
            try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: root.path)
            try? FileManager.default.removeItem(at: base)
            UserDefaults().removePersistentDomain(forName: suite)
        }

        var core: LibraryCore {
            get throws { try #require(service.core) }
        }

        var workingFolder: WorkingFolder {
            get throws { try #require(library.roots.first) }
        }

        /// The root's row and where it keeps its sidecars, as the index has them.
        func record() async throws -> RootRecord {
            let path = LibraryService.path(root)
            return try #require(try await core.index.read { try $0.root(path: path) })
        }

        /// The sheet as the command makes it, from the index, and then with the disk looked through.
        func sheet() async throws -> MoveEditsModel {
            let core = try core
            let survey = try #require(await MoveEditsModel.survey(root, in: core.index))
            let sheet = try MoveEditsModel(
                root: workingFolder, rootID: survey.id, placement: survey.placement, indexed: survey.photos,
            )
            await sheet.check(core.sidecars)
            return sheet
        }

        /// Every file of `photo`'s sidecar at `sidecar`, by its path inside it, with its bytes; nil when it isn't
        /// there.
        static func files(_ sidecar: URL) -> [String: Data]? {
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: sidecar.path, isDirectory: &isDirectory) else { return nil }
            guard isDirectory.boolValue else { return (try? Data(contentsOf: sidecar)).map { ["": $0] } }
            var files: [String: Data] = [:]
            for path in FileManager.default.subpaths(atPath: sidecar.path) ?? [] {
                files[path] = try? Data(contentsOf: sidecar.appending(path: path))
            }
            return files
        }

        /// Each of `names`' sidecars beside it.
        func beside(_ names: [String]) -> [String: [String: Data]] {
            names.reduce(into: [:]) { found, name in
                found[name] = Self.files(SidecarLocator.besidePhoto(photo(name)))
            }
        }

        /// Each of `names`' sidecars on this Mac, as the app's locator places them.
        func onThisMac(_ names: [String]) -> [String: [String: Data]] {
            names.reduce(into: [:]) { found, name in
                found[name] = library.sidecars.locator.onThisMac(photo(name)).flatMap(Self.files)
            }
        }

        /// Hidden copies a move or a save left behind, below `folder`.
        static func leftovers(below folder: URL) -> [String] {
            (FileManager.default.subpaths(atPath: folder.path) ?? []).filter { path in
                path.split(separator: "/").contains { $0.hasPrefix(".") && $0.contains(".redlamp") }
            }
        }
    }

    private static func eventually(seconds: Double = 10, _ condition: () async throws -> Bool) async rethrows {
        for _ in 0 ..< Int(seconds * 100) where try await !condition() {
            try? await Task.sleep(for: .milliseconds(10))
        }
    }

    // MARK: - Moving

    @Test func `a root's edits and metadata move to this Mac and back with every byte kept, its placement following`(
    ) async throws {
        let folder = Folder()
        defer { folder.cleanUp() }
        let names = ["A.JPG", "B.JPG", "C.JPG", "Day 2/D.JPG", "Day 2/E.JPG"]
        let edited = ["A.JPG", "C.JPG", "Day 2/E.JPG"]
        try folder.write(names, edited: Set(edited))
        try await folder.open()
        let before = folder.beside(edited)
        #expect(before.count == 3 && before.values.allSatisfy { !$0.isEmpty })

        let sheet = try await folder.sheet()
        #expect(sheet.placement == .besidePhotos && sheet.destination == .onThisMac)
        #expect(sheet.count == "3 photos have edits or metadata beside the photos.")
        #expect(sheet.kept == "Beside the photos, in a .redlamp file next to each one")
        #expect(sheet.goingTo == "Redlamp on this Mac" && sheet.canMove && sheet.status.isEmpty)
        let model = try #require(folder.model)
        #expect(await model.moveEdits(sheet), "the move went through with nothing to say")
        #expect(try await folder.record().sidecars == .onThisMac)
        #expect(folder.beside(edited).isEmpty, "nothing left beside the photos")
        #expect(folder.onThisMac(edited) == before)
        #expect(SidecarMoveRecord.saved(in: folder.defaults) == nil)
        #expect(!FileManager.default.fileExists(atPath: folder.paths.root.appending(path: "Sidecar Move.json").path))
        let store = folder.library.sidecars.store(for: folder.photo("C.JPG"))
        #expect(store.load(for: folder.photo("C.JPG"))?.metadata?.rating == 3, "read where it went")
        #expect(model.activity.events.contains {
            $0.text == "Moved the edits and metadata of 3 photos in Photos to Redlamp on this Mac"
        })

        let back = try await folder.sheet()
        #expect(back.placement == .onThisMac && back.destination == .besidePhotos)
        #expect(back.count == "3 photos have edits or metadata in Redlamp on this Mac.")
        #expect(back.kept == "In Redlamp on this Mac, in its library" && back.goingTo == "Beside the photos")
        #expect(await model.moveEdits(back))
        #expect(try await folder.record().sidecars == .besidePhotos)
        #expect(folder.beside(edited) == before)
        #expect(folder.onThisMac(edited).isEmpty)
        #expect(Folder.leftovers(below: folder.root).isEmpty && Folder.leftovers(below: folder.paths.sidecars).isEmpty)
    }

    @Test func `Cancel stops the move between two parts and puts back what it moved, the placement as it was`(
    ) async throws {
        let folder = Folder()
        defer { folder.cleanUp() }
        let names = (1 ... 300).map { String(format: "IMG_%04d.JPG", $0) }
        try folder.write(names, edited: Set(names))
        try await folder.open()
        let before = folder.beside(names)
        let id = try await folder.record().id
        let control = SidecarMoveControl()
        let placements = PlacementLog()
        let result = try await SidecarMoveJob.run(
            root: id, to: .onThisMac, core: folder.core, control: control,
            placed: { await placements.note() },
            progress: { progress in
                if !progress.isRollingBack, progress.done > 0 {
                    control.cancel()
                }
            },
        )
        #expect(result.total == 300 && result.error == nil)
        #expect(result.outcome.moved == SidecarMoveJob.part, "the first part, then nothing")
        #expect(result.putBack?.moved == SidecarMoveJob.part && result.putBack?.failed.isEmpty == true)
        #expect(try await folder.record().sidecars == .besidePhotos)
        #expect(folder.beside(names) == before)
        #expect(await placements.count == 2, "the locator read again as it set out and as it came back")
        #expect(!FileManager.default.fileExists(atPath: folder.paths.root.appending(path: "Sidecar Move.json").path))
    }

    @Test func `Cancel turns the move round in the defaults before it puts back`() throws {
        let suite = "move-edits-cancel-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { UserDefaults().removePersistentDomain(forName: suite) }
        let record = SidecarMoveRecord(root: "/Volumes/Card", destination: .onThisMac)
        record.save(in: defaults)
        let sheet = MoveEditsModel(
            root: WorkingFolder(path: "/Volumes/Card"), rootID: 1, placement: .besidePhotos, indexed: 3,
            unfinished: record,
        )
        sheet.onCancel = {
            var turned = record
            turned.destination = .besidePhotos
            turned.puttingBack = true
            turned.save(in: defaults)
        }
        #expect(sheet.isMoving && !sheet.isPuttingBack)
        sheet.cancel()
        #expect(sheet.control.isCancelled)
        #expect(SidecarMoveRecord.saved(in: defaults) == SidecarMoveRecord(
            root: "/Volumes/Card", destination: .besidePhotos, puttingBack: true,
        ))
    }

    @Test func `a launch finishes a move a quit interrupted: the part in the journal, then the rest from the disk`(
    ) async throws {
        _ = NSApplication.shared
        let folder = Folder()
        defer { folder.cleanUp() }
        let names = (1 ... 300).map { String(format: "IMG_%04d.JPG", $0) }
        try folder.write(names, edited: Set(names))
        try await folder.open()
        let before = folder.beside(names)
        let core = try folder.core
        let id = try await folder.record().id

        // As a quit leaves it: the first part moved, the placement this Mac's, the next part in the journal and
        // the move in the defaults; the journal doesn't have the rest.
        let plan = try await core.sidecars.planMove(ofRoot: id, to: .onThisMac)
        var first = plan
        first.items = Array(plan.items.prefix(SidecarMoveJob.part))
        _ = try await core.sidecars.move(first)
        var next = plan
        next.items = Array(plan.items[SidecarMoveJob.part ..< SidecarMoveJob.part + 20])
        try JSONEncoder().encode(next).write(to: core.sidecars.moveJournal)
        SidecarMoveRecord(root: LibraryService.path(folder.root), destination: .onThisMac).save(in: folder.defaults)
        folder.close()

        try await folder.open()
        await Self.eventually(seconds: 30) { SidecarMoveRecord.saved(in: folder.defaults) == nil }
        #expect(SidecarMoveRecord.saved(in: folder.defaults) == nil, "the move finished")
        #expect(try await folder.record().sidecars == .onThisMac)
        #expect(folder.beside(names).isEmpty)
        #expect(folder.onThisMac(names) == before)
        #expect(try !FileManager.default.fileExists(atPath: folder.core.sidecars.moveJournal.path))
        #expect(folder.model.activity.events.contains {
            $0.text == "Finished moving the edits and metadata of 24 photos in Photos to Redlamp on this Mac, "
                + "which a quit interrupted"
        })
    }

    // MARK: - Refusing

    @Test func `moving into a folder Redlamp can't write in is refused with the reason, and nothing moves`(
    ) async throws {
        let folder = Folder()
        defer { folder.cleanUp() }
        try folder.write(["A.JPG", "B.JPG"], edited: ["A.JPG"])
        try await folder.open()
        let model = try #require(folder.model)
        #expect(try await model.moveEdits(folder.sheet()))
        let there = folder.onThisMac(["A.JPG"])
        #expect(there.count == 1)

        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: folder.root.path)
        let sheet = try await folder.sheet()
        #expect(sheet.destination == .besidePhotos && !sheet.canMove)
        #expect(sheet.status == "Redlamp doesn't have permission to write in “Photos”, so its edits and metadata "
            + "stay in Redlamp on this Mac.")
        #expect(sheet.statusIsProblem)
        #expect(await !model.moveEdits(sheet), "refused again as it would start")
        #expect(folder.onThisMac(["A.JPG"]) == there && folder.beside(["A.JPG"]).isEmpty)
        #expect(try await folder.record().sidecars == .onThisMac)
        #expect(
            SidecarMoveJob.whyNotWritable(folder.base.appending(path: "Gone"), probing: true)
                == "“Gone” isn't there: its disk may not be connected",
        )
    }

    @Test func `a photo with edits and metadata in both places stops the move before it starts, and is named`(
    ) async throws {
        let folder = Folder()
        defer { folder.cleanUp() }
        try folder.write(["A.JPG", "B.JPG"], edited: ["A.JPG", "B.JPG"])
        try await folder.open()
        let id = try await folder.record().id
        let sidecars = try folder.core.sidecars
        try await sidecars.setPlacement(.onThisMac, forRoot: id)
        let mac = try #require(try await sidecars.locator().onThisMac(folder.photo("B.JPG")))
        try await sidecars.setPlacement(.besidePhotos, forRoot: id)
        try FileManager.default.createDirectory(at: mac.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: SidecarLocator.besidePhoto(folder.photo("B.JPG")), to: mac)
        let sheet = try await folder.sheet()
        #expect(sheet.conflicts.map(\.photo) == ["B.JPG"] && !sheet.canMove)
        #expect(sheet.count == "2 photos have edits or metadata beside the photos.")
        #expect(sheet.status == "1 photo has edits and metadata in both places, so nothing can be moved: B.JPG. "
            + "Redlamp reads the copy saved last.")
    }

    // MARK: - The sheet

    @Test func `the sheet's numbers come from the index before the disk is looked through`() async throws {
        let folder = Folder()
        defer { folder.cleanUp() }
        try folder.write(["A.JPG", "B.JPG", "C.JPG", "D.JPG"], edited: ["B.JPG", "D.JPG"])
        try await folder.open()
        let index = try folder.core.index
        let survey = try #require(await MoveEditsModel.survey(folder.root, in: index))
        #expect(survey.placement == .besidePhotos && survey.photos == 2)
        let sheet = try MoveEditsModel(
            root: folder.workingFolder, rootID: survey.id, placement: survey.placement, indexed: survey.photos,
        )
        #expect(sheet.phase == .checking && !sheet.canMove)
        #expect(sheet.count == "2 photos have edits or metadata beside the photos.")
        #expect(sheet.heading == "Move Edits and Metadata of “Photos”")
        #expect(sheet.status == "Finding the edits and metadata in the folder…")
        #expect(await MoveEditsModel.survey(folder.base, in: index) == nil, "a folder that isn't a root")
        let unknown = MoveEditsModel(
            root: WorkingFolder(path: "/Elsewhere"),
            rootID: nil,
            placement: .besidePhotos,
            indexed: 0,
        )
        #expect(unknown.isOver && unknown.status.hasPrefix("The library hasn't read “Elsewhere” yet"))
    }

    @Test func `the open photo's edit is saved before the move, and its next save goes where it went`() async throws {
        let folder = Folder()
        defer { folder.cleanUp() }
        try folder.write(["A.JPG", "B.JPG"], edited: ["B.JPG"])
        try await folder.open()
        let model = try #require(folder.model)
        let photo = folder.photo("A.JPG")
        model.select(photo)
        for _ in 0 ..< 400 where model.info?.url != photo {
            try await Task.sleep(for: .milliseconds(5))
        }
        try #require(model.info?.url == photo)
        model.setValue(.exposure, 0.8)
        #expect(model.hasUnsavedChange)
        let sheet = try await folder.sheet()
        #expect(await model.moveEdits(sheet))
        let moved = try #require(folder.library.sidecars.locator.onThisMac(photo))
        #expect(SidecarStore(locator: folder.library.sidecars.locator).load(for: photo)?.recipe[.exposure] == 0.8)
        #expect(FileManager.default.fileExists(atPath: moved.path))
        #expect(!FileManager.default.fileExists(atPath: SidecarLocator.besidePhoto(photo).path))

        model.setValue(.exposure, 0.4)
        model.saveNow()
        await model.saves.flush()
        #expect(SidecarStore(locator: folder.library.sidecars.locator).load(for: photo)?.recipe[.exposure] == 0.4)
        #expect(!FileManager.default.fileExists(atPath: SidecarLocator.besidePhoto(photo).path), "nothing beside it")
    }

    @Test func `the sheet lays out its words, and Move is the default button once the disk is looked through`(
    ) async throws {
        _ = NSApplication.shared
        let folder = Folder()
        defer { folder.cleanUp() }
        try folder.write(["A.JPG"], edited: ["A.JPG"])
        try await folder.open()
        let sheet = try await folder.sheet()
        let controller = MoveEditsSheetController(model: sheet, editor: folder.model, requested: .now)
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: MoveEditsSheetController.width, height: 300), styleMask: [.titled],
            backing: .buffered, defer: false,
        )
        window.contentViewController = controller
        window.layoutIfNeeded()
        func views(in view: NSView) -> [NSView] {
            [view] + view.subviews.flatMap(views)
        }
        let all = views(in: controller.view)
        func text(_ identifier: String) -> String? {
            all.compactMap { $0 as? NSTextField }.first { $0.accessibilityIdentifier() == identifier }?.stringValue
        }
        #expect(text("moveEdits.count") == "1 photo has edits or metadata beside the photos.")
        #expect(text("moveEdits.kept") == "Beside the photos, in a .redlamp file next to each one")
        #expect(text("moveEdits.destination") == "Redlamp on this Mac")
        let buttons = all.compactMap { $0 as? NSButton }
        let move = buttons.first { $0.accessibilityIdentifier() == "moveEdits.move" }
        #expect(move?.isEnabled == true && move?.keyEquivalent == "\r")
        #expect(buttons.first { $0.accessibilityIdentifier() == "moveEdits.cancel" }?.keyEquivalent == "\u{1b}")
    }

    @Test func `a reason the library gives reads as the end of a sentence`() {
        let cocoa = "Error Domain=NSCocoaErrorDomain Code=513 \"“A.JPG.redlamp” couldn’t be moved because you "
            + "don’t have permission to access “Day 2”.\" UserInfo={NSFilePath=/Volumes/Card/Day 2/A.JPG.redlamp}"
        #expect(SidecarMoveJob.reason(cocoa)
            == "“A.JPG.redlamp” couldn’t be moved because you don’t have permission to access “Day 2”")
        #expect(SidecarMoveJob.reason("The disk is full.") == "the disk is full")
        #expect(SidecarMoveJob.reason("NAS refused it") == "NAS refused it")
    }
}

/// How many times the move's placement changed, from its threads.
private actor PlacementLog {
    private(set) var count = 0

    func note() {
        count += 1
    }
}
