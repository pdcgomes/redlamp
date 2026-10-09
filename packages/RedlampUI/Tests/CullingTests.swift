import AppKit
import CoreGraphics
import Foundation
import ImageIO
import RedlampDocument
import RedlampEngineAPI
import RedlampLibrary
import Synchronization
import Testing
import UniformTypeIdentifiers
@_spi(Harness) @testable import RedlampUI

/// Culling (LIB-15): each rating, flag, label and mark on the whole selection in Library as one batch,
/// shown at once, with Undo and Redo; ⇧ and Auto Advance moving on; Develop acting on its photo alone;
/// a click on a selected cell's stars reaching the selection; and a batch that fails showing what the
/// sidecars hold.
@MainActor
struct CullingTests {
    // MARK: - Batches on a selection

    @Test func `each culling action on a selection is one batch, shown at once, with Undo and Redo`() async throws {
        let folder = IndexedFolder()
        defer { folder.cleanUp() }
        try await folder.open()
        let model = try #require(folder.model)
        #expect(model.perform(.selectAllPhotos))
        let all = 0 ..< folder.photos.count
        let checks: [(ShortcutAction, (PhotoMetadata) -> Bool)] = [
            (.rating3, { $0.rating == 3 }),
            (.flagPick, { $0.flag == .pick }),
            (.labelRed, { $0.label == .red }),
            (.labelPurple, { $0.label == .purple }),
            (.toggleMark, { $0.mark }),
        ]
        for (action, holds) in checks {
            let before = all.map(folder.shown)
            let batches = try await folder.batches()
            #expect(model.perform(action))
            #expect(all.allSatisfy { holds(folder.shown($0)) }, "\(action.title) shows at once on every photo")
            await folder.written()
            #expect(try await folder.batches() == batches + 1, "\(action.title) is one batch")
            #expect(all.allSatisfy { folder.sidecar($0).map(holds) == true }, "\(action.title) is in every sidecar")
            #expect(folder.sidecar(1)?.rating ?? 0 >= 2, "the edited photo keeps what else it held")

            #expect(model.canPerform(.undo) && model.perform(.undo), "⌘Z in Library")
            #expect(all.map(folder.shown) == before, "Undo of \(action.title) shows at once")
            await folder.written()
            #expect(all.allSatisfy { folder.sidecar($0).map(holds) != true }, "Undo of \(action.title) is on disk")

            #expect(model.canPerform(.redo) && model.perform(.redo), "⇧⌘Z in Library")
            #expect(all.allSatisfy { holds(folder.shown($0)) })
            await folder.written()
            #expect(
                all.allSatisfy { folder.sidecar($0).map(holds) == true },
                "Redo of \(action.title) is on disk: \(all.map { folder.sidecar($0).map(String.init(describing:)) })",
            )
        }
        // Undo takes back each of them, newest first: the photos as they were.
        while model.canUndoCulling {
            model.undoCulling()
        }
        await folder.written()
        #expect(!folder.hasSidecar(5), "a sidecar a batch made is gone")
        #expect(folder.sidecar(0)?.isEmpty ?? true, "the photo Develop has open holds nothing either")
        #expect(folder.sidecar(1) == PhotoMetadata(rating: 2))
        #expect(all.map(folder.shown).map(\.rating) == [0, 2, 0, 0, 0, 0])
    }

    @Test func `undoing puts thousands of photos back as they were, and reports the one whose sidecar it can't read`(
    ) async throws {
        let folder = IndexedFolder()
        defer { folder.cleanUp() }
        // Every third photo has a sidecar holding an edit and its own rating, flag or mark; the rest none.
        try await folder.open(count: 2000) { number in
            number % 3 != 0 ? nil : PhotoMetadata(
                rating: number % 6,
                flag: number % 9 == 0 ? .pick : nil,
                mark: number % 4 == 0,
            )
        }
        let model = try #require(folder.model)
        // Another photo active, so Develop has none open, as in `--library-perf`.
        model.click(folder.photos[2])
        #expect(model.perform(.selectAllPhotos) && model.info == nil && model.selectedPhotos.count == 2000)
        let before = try await folder.state()

        #expect(model.perform(.rating3))
        await folder.written()
        #expect((0 ..< 2000).allSatisfy { folder.shown($0).rating == 3 })
        // The indexer reads the sidecars the batch wrote, between it and its Undo, as change tracking does.
        try await folder.indexAgain()
        // A sidecar the batch made, for a photo that had none, can't be read while Undo runs.
        let unreadable = 1000
        #expect(before[unreadable].contains("sidecar none"))
        let edit = SidecarStore().editURL(for: folder.photos[unreadable])
        try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: edit.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: edit.path) }

        #expect(model.perform(.undo))
        await folder.written()
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: edit.path)
        let after = try await folder.state()
        let changed = after.indices.filter { after[$0] != before[$0] }
        #expect(changed == [unreadable], "\(changed.prefix(5).map { "\(before[$0]) → \(after[$0])" })")
        #expect(folder.sidecar(unreadable)?.rating == 3, "the sidecar Undo couldn't read is as it was")
        #expect(folder.shown(unreadable).rating == 3, "the grid shows what it holds")
        #expect(after[unreadable].contains("row 3 "), "and so does its row: \(after[unreadable])")
        let alias = model.activity.alias(for: folder.photos[unreadable])
        #expect(
            model.activity.events.contains { $0.kind == .error && $0.text.contains(alias) },
            "it's reported: \(model.activity.events.filter { $0.kind == .error }.map(\.text))",
        )
    }

    @Test func `the photo Develop has open is culled with the rest, and Develop's saves keep the change`() async throws {
        let folder = IndexedFolder()
        defer { folder.cleanUp() }
        try await folder.open(count: 3)
        let model = try #require(folder.model)
        #expect(model.info?.url == folder.photos[0] && model.module == .library)
        #expect(model.perform(.selectAllPhotos) && model.perform(.rating4) && model.photoMetadata.rating == 4)
        await folder.written()
        #expect((0 ..< 3).map { folder.sidecar($0)?.rating } == [4, 4, 4])

        model.showModule(.develop)
        model.setValue(.exposure, 0.5)
        model.saveNow()
        await folder.written()
        let edited = try #require(SidecarStore().load(for: folder.photos[0]))
        #expect(edited.metadata?.rating == 4 && edited.recipe[.exposure] == 0.5, "Develop's save keeps the rating")

        model.showModule(.library)
        #expect(model.perform(.undo))
        await folder.written()
        model.showModule(.develop)
        model.setValue(.exposure, 0.7)
        model.saveNow()
        await folder.written()
        let undone = try #require(SidecarStore().load(for: folder.photos[0]))
        #expect((undone.metadata?.rating ?? 0) == 0 && undone.recipe[.exposure] == 0.7, "nor brings it back")
        #expect(model.photoMetadata.rating == 0 && folder.shown(0).rating == 0)
    }

    @Test func `a custom label and No Label reach the selection, a custom label never as a colour`() async throws {
        let folder = IndexedFolder()
        defer { folder.cleanUp() }
        try await folder.open()
        let model = try #require(folder.model)
        model.click(folder.photos[3], extending: true)
        #expect(model.selectedPhotos == Array(folder.photos[0 ... 3]))
        model.setCustomLabel("Client Picks")
        #expect((0 ... 3)
            .allSatisfy { folder.shown($0).customLabel == "Client Picks" && folder.shown($0).label == nil })
        #expect(model.customLabels == ["Client Picks"], "the menus and the palette offer it")
        await folder.written()
        #expect((0 ... 3).allSatisfy { folder.sidecar($0)?.customLabel == "Client Picks" })
        #expect((0 ... 3).allSatisfy { folder.sidecar($0)?.label == nil })
        let paths = folder.photos.map(LibraryService.path)
        let rows = try await folder.service.core?.index.read { reader in
            try paths.map { try reader.photo(path: $0)?.customLabel }
        }
        #expect(rows == ["Client Picks", "Client Picks", "Client Picks", "Client Picks", nil, nil])
        try await folder.eventually { model.customLabelCounts == [CustomLabelCount(name: "Client Picks", photos: 4)] }
        #expect(model.customLabelCounts == [CustomLabelCount(name: "Client Picks", photos: 4)], "the library's count")

        #expect(model.perform(.clearLabel))
        #expect((0 ... 3).allSatisfy { folder.shown($0).customLabel == nil && folder.shown($0).label == nil })
        await folder.written()
        #expect((0 ... 3).allSatisfy { folder.sidecar($0)?.customLabel == nil })
        try await folder.eventually { model.customLabelCounts.isEmpty }
        #expect(model.customLabelCounts.isEmpty && model.customLabels == ["Client Picks"], "still offered")
    }

    @Test func `the rating keys' ] and [ step each photo's own rating, as one Undo`() async throws {
        let folder = IndexedFolder()
        defer { folder.cleanUp() }
        try await folder.open(count: 3)
        let model = try #require(folder.model)
        model.click(folder.photos[2])
        #expect(model.perform(.rating5))
        model.click(folder.photos[0])
        model.click(folder.photos[2], extending: true)
        await folder.written()
        let batches = try await folder.batches()
        #expect(model.perform(.increaseRating))
        #expect((0 ..< 3).map { folder.shown($0).rating } == [1, 3, 5])
        await folder.written()
        #expect((0 ..< 3).map { folder.sidecar($0)?.rating } == [1, 3, 5])
        #expect(try await folder.batches() == batches + 1, "one batch, each photo given its own rating")
        #expect(model.perform(.undo))
        #expect((0 ..< 3).map { folder.shown($0).rating } == [0, 2, 5])
        await folder.written()
        #expect((0 ..< 3).map { folder.sidecar($0)?.rating ?? 0 } == [0, 2, 5])
        #expect(model.perform(.decreaseRating))
        #expect((0 ..< 3).map { folder.shown($0).rating } == [0, 1, 4])
    }

    @Test func `redoing takes back the Undo, so a photo changed since keeps its change`() async throws {
        let folder = IndexedFolder()
        defer { folder.cleanUp() }
        try await folder.open(count: 4)
        let model = try #require(folder.model)
        model.click(folder.photos[3])
        #expect(model.perform(.selectAllPhotos) && model.perform(.labelGreen))
        await folder.written()
        #expect(model.perform(.undo))
        await folder.written()
        // Labelled since by another app, and read again as change tracking reads it, once the grid has let go of
        // what Undo showed.
        try await Task.sleep(for: CullingOverlay.kept + .milliseconds(200))
        try Library.writeMetadata(for: folder.photos[1]) { $0.label = .blue }
        try await folder.indexAgain()
        try await folder.eventually { folder.shown(1).label == .blue }
        let batches = try await folder.batches()

        #expect(model.perform(.redo))
        #expect((0 ..< 4).map { folder.shown($0).label } == [.green, .blue, .green, .green], "shown at once")
        await folder.written()
        #expect((0 ..< 4).map { folder.sidecar($0)?.label } == [.green, .blue, .green, .green])
        let entries = try await #require(folder.service.metadata).entries()
        #expect(entries.count == batches + 1 && entries.last?.undoes == entries.dropLast().last?.id, "\(entries)")
        #expect(model.perform(.undo))
        await folder.written()
        #expect((0 ..< 4).map { folder.sidecar($0)?.label } == [nil, .blue, nil, nil])
    }

    @Test func `a batch that fails leaves the grid showing what the sidecars hold`() async throws {
        let folder = IndexedFolder()
        defer { folder.cleanUp() }
        try await folder.open()
        let model = try #require(folder.model)
        // The journal can't be written: a file stands where its folder goes.
        let journal = folder.paths.root.appending(path: "Metadata Changes")
        try FileManager.default.createDirectory(at: folder.paths.root, withIntermediateDirectories: true)
        try Data("in the way".utf8).write(to: journal)
        // Another photo active, so Develop has none open to save.
        model.click(folder.photos[1])
        #expect(model.perform(.selectAllPhotos) && model.info == nil)
        #expect(model.perform(.rating5))
        #expect((0 ..< 6).allSatisfy { folder.shown($0).rating == 5 }, "shown at once")
        await folder.written()
        #expect((0 ..< 6).map { folder.shown($0).rating } == [0, 2, 0, 0, 0, 0], "what the sidecars hold")
        #expect(folder.sidecar(1) == PhotoMetadata(rating: 2) && !folder.hasSidecar(2), "nothing was written")
        #expect(model.photoMetadata.rating == 2, "the active photo too")
        #expect(model.activity.events.contains { $0.kind == .error }, "the failure is in the activity log")
    }

    @Test func `changes asked for in a row reach the lists newest last, and the sidecars hold the last`(
    ) async throws {
        let folder = IndexedFolder()
        defer { folder.cleanUp() }
        try await folder.open()
        let model = try #require(folder.model)
        #expect(model.perform(.selectAllPhotos))
        var seen: [[Int]] = []
        let observation = model.library.observe { _ in seen.append((0 ..< 6).map { folder.shown($0).rating }) }
        defer { observation.invalidate() }
        #expect(model.perform(.rating3))
        #expect(model.perform(.rating4))
        #expect(model.perform(.rating1))
        await folder.written()
        try await Task.sleep(for: .milliseconds(400))
        let afterLast = seen.drop { $0 != [1, 1, 1, 1, 1, 1] }
        #expect(afterLast.allSatisfy { $0 == [1, 1, 1, 1, 1, 1] }, "no list showed an older rating after: \(seen)")
        #expect((0 ..< 6).allSatisfy { folder.sidecar($0)?.rating == 1 })
    }
}

@MainActor
extension CullingTests {
    @Test func `a photo is found in the index whichever of Unicode's forms its name and folder are in`(
    ) async throws {
        let folder = IndexedFolder()
        defer { folder.cleanUp() }
        // Made through POSIX with composed bytes, as other tools make them: the index keeps them so, and
        // Foundation's file URLs decompose them.
        try FileManager.default.createDirectory(at: folder.root, withIntermediateDirectories: true)
        let directory = folder.root.path + "/" + "Été à Montréal".precomposedStringWithCanonicalMapping
        #expect(mkdir(directory, 0o755) == 0)
        let jpeg = folder.base.appending(path: "photo.jpg")
        try IndexedFolder.writeJPEG(jpeg, shade: 3)
        let data = try Data(contentsOf: jpeg)
        let file = open(
            directory + "/" + "Café-7706.JPG".precomposedStringWithCanonicalMapping,
            O_CREAT | O_WRONLY,
            0o644,
        )
        #expect(file >= 0 && data.withUnsafeBytes { write(file, $0.baseAddress, data.count) } == data.count)
        close(file)
        try await folder.open(count: 2)
        let deadline = ContinuousClock.now + .seconds(30)
        while await !folder.service.canShow(folder.root, includingSubfolders: true), ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        let index = try #require(folder.service.core?.index)
        let photo = folder.root.appending(path: "Été à Montréal/Café-7706.JPG")
        let ids = await LibraryService.indexIDs(of: [photo], in: index)
        #expect(ids[photo] != nil, "found from the URL the app makes of it")
        let details = PhotoDetailsCache(library: folder.library)
        var read: [URL] = []
        details.request([LibraryItem(url: photo)]) { read = $0 }
        try await folder.eventually { !read.isEmpty }
        #expect(
            read == [photo] && details.details(for: photo)?.width != nil,
            "an expanded cell's details read from its row",
        )
        let subfolder = folder.root.appending(path: "Été à Montréal", directoryHint: .isDirectory)
        #expect(
            await folder.service.canShow(subfolder, includingSubfolders: false),
            "its folder is shown from the library",
        )

        // A save of its own reaches its row.
        try Library.writeMetadata(for: photo) { $0.rating = 4 }
        folder.service.sidecarSaved(photo, store: SidecarStore())
        var rating = 0
        let saved = ContinuousClock.now + .seconds(30)
        while rating != 4, ContinuousClock.now < saved {
            try await Task.sleep(for: .milliseconds(10))
            rating = try await index
                .read { [id = ids[photo]] reader in try id.flatMap { try reader.photo(id: $0) }?.rating ?? 0 }
        }
        #expect(rating == 4, "its row has what its sidecar holds")
    }

    @Test func `undoing through a photo's own save puts back what its sidecar held, not what the grid showed`(
    ) async throws {
        let fixture = ModuleFixture()
        defer { fixture.cleanUp() }
        try await fixture.open(count: 3)
        let model = fixture.model
        model.showModule(.library)
        // As another app's label shows on a photo whose sidecar holds none.
        model.library.update(fixture.photos[1]) { $0.metadata.label = .green }
        model.click(fixture.photos[1])
        #expect(model.perform(.labelRed) && model.items[1].metadata.label == .red)
        try await fixture.eventually { SidecarStore().load(for: fixture.photos[1])?.metadata?.label == .red }
        #expect(model.perform(.undo) && model.items[1].metadata.label == .green, "the grid shows what it showed")
        await model.saves.flush()
        try await fixture.eventually { SidecarStore().load(for: fixture.photos[1])?.metadata?.label == nil }
        #expect(SidecarStore().load(for: fixture.photos[1])?.metadata?.label == nil, "the sidecar holds no label")
    }

    @Test func `lists hear of a batch's photos once no change asked for after it is still to come`() {
        let queue = CullingQueue()
        let photos = (0 ..< 3).map { URL(fileURLWithPath: "/Photos/IMG_\($0).JPG") }
        let first = queue.request(photos)
        let second = queue.request([photos[0]])
        #expect(queue.indexed([1, 2, 3], by: first).isEmpty, "the second change is to come")
        #expect(queue.changedLater(than: first) == [photos[0]])
        #expect(queue.finished(first).isEmpty)
        #expect(Set(queue.indexed([1], by: second)) == [1, 2, 3], "held back until then")
        #expect(queue.finished(second).isEmpty)
        let third = queue.request(photos)
        #expect(Set(queue.finished(third)).isEmpty, "a change the library had no part in sends nothing held")
    }

    @Test func `a toggle sets its value on every photo, or takes it off them all when every one has it`() {
        let picked = CullingValues(PhotoMetadata(flag: .pick, label: .red, mark: true))
        let plain = CullingValues(PhotoMetadata(rating: 2, customLabel: "Urgent"))
        #expect(CullingChange.toggleFlag(.pick).resolved([picked, plain]).map(\.flag) == [.pick, .pick])
        #expect(CullingChange.toggleFlag(.pick).resolved([picked, picked]).map(\.flag) == [nil, nil])
        #expect(CullingChange.toggleLabel(.red).resolved([picked, plain]).map(\.label) == [.red, .red])
        #expect(
            CullingChange.toggleLabel(.red).resolved([plain]).map(\.customLabel) == [nil],
            "a colour ends a custom one",
        )
        #expect(CullingChange.toggleCustomLabel("Urgent").resolved([plain]).map(\.customLabel) == [nil])
        #expect(CullingChange.toggleCustomLabel("Urgent").resolved([picked]).map(\.label) == [nil])
        #expect(CullingChange.toggleMark.resolved([picked, plain]).map(\.mark) == [true, true])
        #expect(CullingChange.ratingStep(1).resolved([picked, plain]).map(\.rating) == [1, 3])
        #expect(CullingChange.ratingStep(-1).resolved([picked]).map(\.rating) == [0])
        #expect(plain.fields(.label) == [.namedLabel("Urgent")] && picked.fields(.label) == [.label(.red)])
    }

    // MARK: - Moving on

    @Test func `culling with ⇧, or with Auto Advance on, makes the photo after the photos culled active`() async throws {
        let fixture = ModuleFixture()
        defer { fixture.cleanUp() }
        try await fixture.open(count: 10)
        let model = fixture.model
        model.showModule(.library)
        model.click(fixture.photos[1])
        model.click(fixture.photos[2], extending: true)
        #expect(model.perform(.rating2, shifted: true))
        #expect(model.selection == fixture.photos[3] && model.selectedPhotos == [fixture.photos[3]])
        #expect(model.items[1].metadata.rating == 2 && model.items[2].metadata.rating == 2)
        #expect(model.items[3].metadata.rating == 0, "the photo moved to isn't rated")

        #expect(!model.autoAdvance && model.perform(.autoAdvance) && model.autoAdvance)
        for (action, next) in [(ShortcutAction.flagPick, 4), (.toggleMark, 5), (.labelGreen, 6), (.rating1, 7)] {
            #expect(model.perform(action))
            #expect(model.selection == fixture.photos[next], "\(action.title) moves on with Auto Advance")
        }
        #expect(model.items[3].metadata.flag == .pick && model.items[4].metadata.mark, "each on the photo it left")
        #expect(model.items[5].metadata.label == .green && model.items[6].metadata.rating == 1)
        #expect(model.items[7].metadata == PhotoMetadata())

        model.showModule(.develop)
        #expect(model.perform(.rating4))
        #expect(model.selection == fixture.photos[8], "Develop moves on too")
        #expect(model.perform(.autoAdvance) && !model.autoAdvance)
        #expect(model.perform(.rating4) && model.selection == fixture.photos[8])
    }

    @Test func `the rows a key reaches are the selection's, and the menus' checks follow the selection`() async throws {
        let fixture = ModuleFixture()
        defer { fixture.cleanUp() }
        try await fixture.open(count: 6)
        let model = fixture.model
        model.showModule(.library)
        model.click(fixture.photos[1])
        #expect(model.selectedRows == [1], "the active photo alone")
        model.click(fixture.photos[4], toggling: true)
        model.click(fixture.photos[2], toggling: true)
        #expect(model.selectedRows == [1, 2, 4], "in the list's order")
        let culling: [ShortcutAction] = [.rating3, .flagPick, .labelRed, .toggleMark]
        let told = Mutex(false)
        withObservationTracking {
            _ = model.selectedRows
            _ = culling.map(model.canPerform)
        } onChange: {
            told.withLock { $0 = true }
        }
        model.click(fixture.photos[5], toggling: true)
        #expect(told.withLock { $0 }, "a change of the selection reaches what read it")
        #expect(model.selectedRows == [1, 2, 4, 5] && culling.allSatisfy(model.canPerform))
        model.selectAllPhotos()
        #expect(model.selectedRows == Array(0 ..< 6))
    }

    @Test func `in Develop a key reaches the active photo alone, and isn't Library's to undo`() async throws {
        let fixture = ModuleFixture()
        defer { fixture.cleanUp() }
        try await fixture.open(count: 5)
        let model = fixture.model
        #expect(model.module == .develop && model.perform(.selectAllPhotos) && model.selectedPhotos.count == 5)
        for action in [ShortcutAction.rating4, .flagReject, .labelBlue, .toggleMark] {
            #expect(model.perform(action))
        }
        #expect(model.photoMetadata == PhotoMetadata(rating: 4, flag: .reject, label: .blue, mark: true))
        #expect(model.items[0].metadata.rating == 4 && model.items[0].metadata.mark)
        #expect(model.items.dropFirst().allSatisfy { $0.metadata == PhotoMetadata() }, "the rest of the selection")
        #expect(!model.canUndoCulling)
        model.saveNow()
        await model.saves.flush()
        try await fixture.eventually { SidecarStore().load(for: fixture.photos[0])?.metadata?.mark == true }
        #expect(SidecarStore().load(for: fixture.photos[0])?.metadata?.mark == true, "Develop saves it with its edit")
    }

    // MARK: - The mouse

    @Test func `a click on a selected cell's stars reaches the whole selection, and another cell's only its photo`(
    ) async throws {
        let fixture = ModuleFixture()
        defer { fixture.cleanUp() }
        try await fixture.open(count: 8)
        let modules = fixture.showModules()
        let model = fixture.model
        model.showModule(.library)
        model.setCellStyle(.expanded)
        try await fixture.settle()
        let grid = modules.grid
        grid.layoutSubtreeIfNeeded()
        model.click(fixture.photos[0])
        model.click(fixture.photos[2], extending: true)

        func click(_ row: Int, at part: (GridCellGeometry) -> CGPoint) throws {
            let frame = grid.gridLayout.frame(forItem: row)
            let local = part(grid.gridLayout.geometry)
            let point = grid.content.convert(CGPoint(x: frame.minX + local.x, y: frame.minY + local.y), to: nil)
            for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
                let event = try #require(NSEvent.mouseEvent(
                    with: type, location: point, modifierFlags: [], timestamp: 0,
                    windowNumber: grid.window?.windowNumber ?? 0, context: nil, eventNumber: 0, clickCount: 1,
                    pressure: type == .leftMouseUp ? 0 : 1,
                ))
                type == .leftMouseDown ? grid.content.mouseDown(with: event) : grid.content.mouseUp(with: event)
            }
        }
        func star(_ stars: Int) -> (GridCellGeometry) -> CGPoint {
            { CGPoint(x: $0.rating.x + 4 + 7 * CGFloat(stars - 1) + 3.5, y: $0.cellSize.height - 10) }
        }
        try click(1, at: star(4))
        #expect((0 ... 2).allSatisfy { model.items[$0].metadata.rating == 4 }, "the selection")
        #expect(model.items[3].metadata.rating == 0)
        try click(5, at: star(2))
        #expect(model.items[5].metadata.rating == 2 && model.items[0].metadata.rating == 4, "only the photo")
        #expect(model.selectedPhotos == Array(fixture.photos[0 ... 2]), "a click on a badge keeps the selection")
        try click(2, at: star(4))
        #expect((0 ... 2).allSatisfy { model.items[$0].metadata.rating == 0 }, "its own rating again clears it")
        try click(0, at: { $0.flag })
        #expect((0 ... 2).allSatisfy { model.items[$0].metadata.flag == .pick })
        try click(0, at: { $0.mark })
        #expect((0 ... 2).allSatisfy { model.items[$0].metadata.mark })
        try await fixture.settle()
        #expect(grid.cells[1]?.badgesShown == 3, "an expanded cell shows its stars, its flag and its mark")
        #expect(model.canUndoCulling && model.undoCulling())
        #expect((0 ... 2).allSatisfy { !model.items[$0].metadata.mark })
    }

    @Test func `the photo's context menu culls it, or the selection it's in`() async throws {
        let fixture = ModuleFixture()
        defer { fixture.cleanUp() }
        try await fixture.open(count: 6)
        let model = fixture.model
        model.showModule(.library)
        model.click(fixture.photos[0])
        model.click(fixture.photos[1], extending: true)
        func choose(_ title: String, in submenu: String?, on photo: URL) throws {
            var menu = LibraryGridMenu.menu(for: photo, model: model)
            if let submenu {
                menu = try #require(menu.items.first { $0.title == submenu }?.submenu)
            }
            let index = try #require(menu.items.firstIndex { $0.title.hasPrefix(title) })
            menu.performActionForItem(at: index)
        }
        try choose("Purple Label", in: "Set Color Label", on: fixture.photos[1])
        #expect(model.items[0].metadata.label == .purple && model.items[1].metadata.label == .purple)
        try choose("5 Stars", in: "Set Rating", on: fixture.photos[4])
        #expect(model.items[4].metadata.rating == 5 && model.items[0].metadata.rating == 0, "a photo outside it")
        try choose("Mark / Unmark", in: nil, on: fixture.photos[0])
        #expect(model.items[0].metadata.mark && model.items[1].metadata.mark && !model.items[4].metadata.mark)
        let strip = try #require(FilmstripMenu.menu(for: fixture.photos[3], model: model, culling: true))
        #expect(strip.items.contains { $0.title == "Set Flag" }, "the filmstrip's menu in Library")
        model.showModule(.develop)
        #expect(
            LibraryGridMenu.culling(for: fixture.photos[3], model: model).isEmpty,
            "Develop's keys act on its photo",
        )
    }

    @Test func `the palette lists each culling action and the custom labels the photos have`() async throws {
        let fixture = ModuleFixture()
        defer { fixture.cleanUp() }
        try await fixture.open(count: 3)
        let model = fixture.model
        model.showModule(.library)
        model.setCustomLabel("Second Look")
        model.openCommandPalette()
        let palette = try #require(model.commandPalette)
        palette.setText("second look")
        let row = try #require(palette.rows.first)
        #expect(row.kind == .customLabel("Second Look") && palette.isEnabled(row))
        for action in [ShortcutAction.labelPurple, .clearLabel, .toggleMark, .autoAdvance] {
            palette.setText(action.title)
            #expect(palette.rows.contains { $0.kind == .action(action) }, "\(action.title) is in the palette")
            #expect(palette.rows.first { $0.kind == .action(action) }.map(palette.isEnabled) == true)
        }
        model.closeCommandPalette()
        model.perform(.clearLabel)
        #expect(model.items[0].metadata.customLabel == nil)
        model.openCommandPalette()
        let again = try #require(model.commandPalette)
        again.setText("second look")
        try again.activate(#require(again.rows.first))
        #expect(model.items[0].metadata.customLabel == "Second Look", "the palette's row sets it")
    }
}

@MainActor
extension CullingTests {
    /// Six small JPEGs in a folder the library has indexed, shown from it in Library: the second with a
    /// sidecar holding an edit and two stars.
    @MainActor
    final class IndexedFolder {
        let base = FileManager.default.temporaryDirectory
            .appending(path: "culling-\(UUID().uuidString)", directoryHint: .isDirectory).standardizedFileURL
        let library = FolderLibrary()
        private(set) var service: LibraryService!
        private(set) var model: EditorModel!
        private(set) var photos: [URL] = []

        var root: URL {
            base.appending(path: "Photos", directoryHint: .isDirectory)
        }

        var paths: LibraryPaths {
            LibraryPaths(root: base.appending(path: "Library", directoryHint: .isDirectory))
        }

        /// With `sidecars`, the photos after the second it gives metadata get a sidecar holding it and an edit.
        func open(count: Int = 6, sidecars: (Int) -> PhotoMetadata? = { _ in nil }) async throws {
            for number in 0 ..< count {
                let url = root.appending(path: String(format: "IMG_%04d.JPG", number), directoryHint: .notDirectory)
                try Self.writeJPEG(url, shade: number)
                photos.append(url)
            }
            var edited = EditRecipe()
            edited[.exposure] = 0.5
            try SidecarStore().save(Sidecar(recipe: edited, metadata: PhotoMetadata(rating: 2)), for: photos[1])
            for number in 2 ..< max(count, 2) {
                if let metadata = sidecars(number) {
                    try SidecarStore().save(Sidecar(recipe: edited, metadata: metadata), for: photos[number])
                }
            }
            library.add([root])
            service = LibraryService(paths: paths, sidecars: library.sidecars) { url, size in
                StoreThumbnailMaker.imageIO(url, nil, size)
            }
            library.attach(service)
            let deadline = ContinuousClock.now + .seconds(max(30, Double(count) / 25))
            while await !service.canShow(root, includingSubfolders: false), ContinuousClock.now < deadline {
                try await Task.sleep(for: .milliseconds(10))
            }
            model = EditorModel(engine: StubEngine(), library: library)
            model.open([root])
            try await eventually {
                self.library.isShownFromLibrary && self.model.items.count >= count && self.model.info != nil
            }
            try #require(library.isShownFromLibrary && model.info?.url == photos[0], "the first photo open in Develop")
            model.showModule(.library)
        }

        /// Until every culling change asked for is made, Develop's save of its photo included.
        func written() async {
            while let tail = model.cullingTail {
                await tail.value
                if model.cullingTail == tail {
                    break
                }
            }
            await model.saves.flush()
        }

        func sidecar(_ number: Int) -> PhotoMetadata? {
            SidecarStore().load(for: photos[number])?.metadata
        }

        func hasSidecar(_ number: Int) -> Bool {
            FileManager.default.fileExists(atPath: SidecarStore().url(for: photos[number]).path)
        }

        func shown(_ number: Int) -> PhotoMetadata {
            model.library.item(for: photos[number])?.metadata ?? PhotoMetadata()
        }

        func batches() async throws -> Int {
            try await service.metadata?.entries().count ?? 0
        }

        /// Each photo's sidecar as `--library-perf` compares them (whether it has an edit, and its metadata),
        /// or none, and its row's culling fields, whether it has an edit and whether the index has a date for
        /// its sidecar.
        func state() async throws -> [String] {
            let photos = photos
            let sidecars = await Task.detached {
                photos.map { url in SidecarStore().summary(for: url).map { "\($0.hasEdits) \($0.metadata)" } ?? "none" }
            }.value
            let paths = photos.map(LibraryService.path)
            let rows = try await #require(service.core).index.read { reader in
                try paths.map { path in
                    try reader.photo(path: path).map { row in
                        "\(row.rating) \(String(describing: row.flag)) \(String(describing: row.label)) "
                            + "\(String(describing: row.customLabel)) \(row.marked) \(row.edited) \(row.sidecarModified != nil)"
                    } ?? "no row"
                }
            }
            return photos.indices.map { "\(photos[$0].lastPathComponent): sidecar \(sidecars[$0]); row \(rows[$0])" }
        }

        /// Reads the folder again, as change tracking does when its files change, its photos' lists hearing of
        /// what it finds.
        func indexAgain() async throws {
            let core = try #require(service.core)
            for await event in core.indexer.update([FolderChange(root, recursive: true)]) {
                core.live.receive(.indexer(event))
            }
        }

        func eventually(_ condition: () -> Bool) async throws {
            let deadline = ContinuousClock.now + .seconds(30)
            while !condition(), ContinuousClock.now < deadline {
                try await Task.sleep(for: .milliseconds(5))
            }
        }

        func cleanUp() {
            LibrarySandbox.remove(base, closing: [service])
        }

        static func writeJPEG(_ url: URL, shade: Int) throws {
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(), withIntermediateDirectories: true,
            )
            let space = try #require(CGColorSpace(name: CGColorSpace.sRGB))
            let context = try #require(CGContext(
                data: nil, width: 64, height: 48, bitsPerComponent: 8, bytesPerRow: 0, space: space,
                bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue,
            ))
            context.setFillColor(
                red: CGFloat(shade % 7) / 7, green: CGFloat(shade % 5) / 5, blue: CGFloat(shade % 3) / 3, alpha: 1,
            )
            context.fill(CGRect(x: 0, y: 0, width: 64, height: 48))
            let data = NSMutableData()
            let destination = try #require(CGImageDestinationCreateWithData(
                data, UTType.jpeg.identifier as CFString, 1, nil,
            ))
            try CGImageDestinationAddImage(destination, #require(context.makeImage()), nil)
            #expect(CGImageDestinationFinalize(destination))
            try (data as Data).write(to: url)
        }
    }
}
