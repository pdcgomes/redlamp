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

/// The engine edits are rendered in, for these tests: every photo is 3000 by 2000 pixels, and its render
/// is grey as light as its edit's exposure (`shade`). It records what it opens and renders, and a render
/// can wait at its gate.
final class RenderEngine: EditingEngine, @unchecked Sendable {
    let base = StubEngine()
    let gate = Gate()
    let opened = Mutex<[URL]>([])
    let openedAt = Mutex<[ContinuousClock.Instant]>([])
    let rendered = Mutex<[StillRequest]>([])
    /// Renders that found themselves cancelled once through the gate.
    let cancelled = Mutex(0)

    static let size = PixelSize(width: 3000, height: 2000)

    static func shade(_ exposure: Double) -> Double {
        0.5 + exposure * 0.2
    }

    func open(_ url: URL) async throws -> ImageInfo {
        opened.withLock { $0.append(url) }
        openedAt.withLock { $0.append(.now) }
        return ImageInfo(url: url, pixelSize: Self.size, isRaw: true, sensorDescription: "stub")
    }

    func renderStill(_ request: StillRequest) async throws -> CGImage {
        rendered.withLock { $0.append(request) }
        await gate.pass()
        if Task.isCancelled {
            cancelled.withLock { $0 += 1 }
            throw CancellationError()
        }
        let size = request.maxLongEdge.map { Self.size.fitted(within: PixelSize(width: $0, height: $0)) } ?? Self.size
        guard let space = CGColorSpace(name: CGColorSpace.displayP3), let context = CGContext(
            data: nil, width: size.width, height: size.height, bitsPerComponent: 8, bytesPerRow: 0, space: space,
            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue,
        ) else { throw CancellationError() }
        let shade = Self.shade(request.recipe[.exposure])
        context.setFillColor(red: shade, green: shade, blue: shade, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: size.width, height: size.height))
        guard let image = context.makeImage() else { throw CancellationError() }
        return image
    }

    func openIfReady(_ url: URL) -> ImageInfo? {
        base.openIfReady(url)
    }

    func prefetch(_ urls: [URL]) {
        base.prefetch(urls)
    }

    func render(_ request: RenderRequest) {
        base.render(request)
    }

    func frames() -> AsyncStream<RenderedFrame> {
        base.frames()
    }

    func autoWhiteBalance() async -> WhiteBalanceValue? {
        nil
    }

    func whiteBalance(sampledAt _: CGPoint) async -> WhiteBalanceValue? {
        nil
    }

    func autoTone(for _: EditRecipe) async -> [ParameterID: Double] {
        [:]
    }

    func maskColor(sampledAt point: CGPoint, recipe: EditRecipe) async -> SIMD3<Double>? {
        await base.maskColor(sampledAt: point, recipe: recipe)
    }

    func computeMasks(_ request: MaskRequest) async throws -> [AIMask] {
        try await base.computeMasks(request)
    }

    func previewObjectMask(_ request: MaskRequest) async throws -> MaskBitmap? {
        try await base.previewObjectMask(request)
    }

    func refineMaskEdges(_ mask: AIMask) async throws -> MaskBitmap {
        try await base.refineMaskEdges(mask)
    }

    func refineMaskEdges(_ bitmap: MaskBitmap, along strokes: [BrushStroke]) async throws -> MaskBitmap {
        try await base.refineMaskEdges(bitmap, along: strokes)
    }

    func availableMaskKinds() -> Set<MaskKind> {
        base.availableMaskKinds()
    }

    func modelNeeded(for kind: MaskKind) async -> ModelInfo? {
        await base.modelNeeded(for: kind)
    }

    func models() async -> [ModelInfo] {
        await base.models()
    }

    func downloadModel(_ id: String, progress: @escaping @Sendable (Double) -> Void) async throws {
        try await base.downloadModel(id, progress: progress)
    }

    func removeModel(_ id: String) async throws {
        try await base.removeModel(id)
    }

    func thumbnail(for url: URL, maxPixelSize: Int) async -> CGImage? {
        await base.thumbnail(for: url, maxPixelSize: maxPixelSize)
    }

    func registerBaseLook(_ look: BaseLookDefinition) {
        base.registerBaseLook(look)
    }

    func canRender(_ reference: BaseLookReference) -> Bool {
        base.canRender(reference)
    }

    func focusStack(
        at url: URL, maxLongEdge: Int, progress: @escaping @Sendable (Double) -> Void,
    ) async throws -> FocusStackPreview {
        try await base.focusStack(at: url, maxLongEdge: maxLongEdge, progress: progress)
    }
}

/// A library over a folder of small JPEGs, each its own colour, shown in an editor whose edits are
/// rendered by a `RenderEngine`.
@MainActor
final class EditRenderFixture {
    let base = FileManager.default.temporaryDirectory
        .appending(path: "edit-renders-\(UUID().uuidString)", directoryHint: .isDirectory).standardizedFileURL
    let engine = RenderEngine()
    let editor = StubEngine()
    private(set) var library = FolderLibrary()
    private(set) var model: EditorModel!
    private(set) var service: LibraryService!
    private var windows: [NSWindow] = []

    var root: URL {
        base.appending(path: "Photos", directoryHint: .isDirectory)
    }

    var renders: EditRenders {
        model.editRenders
    }

    var store: PhotoStore {
        service.thumbnails!.store
    }

    func photo(_ path: String) -> URL {
        root.appending(path: path, directoryHint: .notDirectory)
    }

    func item(_ path: String) -> RedlampUI.LibraryItem? {
        library.item(for: photo(path))
    }

    func key(_ path: String) -> ContentKey? {
        item(path).flatMap { library.storeThumbnail(for: $0)?.1 }
    }

    /// The colour photo `number` is, as its shade of grey would read.
    static func colour(_ number: Int) -> (red: Double, green: Double, blue: Double) {
        (Double(number % 7) / 7, Double(number % 5) / 5 * 0.4, 1)
    }

    /// Small JPEGs at `paths` below the root.
    func photos(_ paths: [String]) throws {
        for (number, path) in paths.enumerated() {
            let url = photo(path)
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(), withIntermediateDirectories: true,
            )
            let space = try #require(CGColorSpace(name: CGColorSpace.sRGB))
            let context = try #require(CGContext(
                data: nil, width: 96, height: 64, bitsPerComponent: 8, bytesPerRow: 0, space: space,
                bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue,
            ))
            let colour = Self.colour(number)
            context.setFillColor(red: colour.red, green: colour.green, blue: colour.blue, alpha: 1)
            context.fill(CGRect(x: 0, y: 0, width: 96, height: 64))
            let data = NSMutableData()
            let destination = try #require(CGImageDestinationCreateWithData(
                data, UTType.jpeg.identifier as CFString, 1, nil,
            ))
            try CGImageDestinationAddImage(destination, #require(context.makeImage()), nil)
            #expect(CGImageDestinationFinalize(destination))
            try (data as Data).write(to: url)
        }
    }

    static func recipe(exposure: Double) -> EditRecipe {
        var recipe = EditRecipe()
        recipe[.exposure] = exposure
        return recipe
    }

    static func digest(exposure: Double) throws -> EditDigest {
        try #require(EditDigest(rendering: recipe(exposure: exposure)))
    }

    /// Saves an edit of `exposure`, and `rating`, to the photo's sidecar; with `telling`, tells the
    /// library, as the editor's saves do.
    func edit(_ path: String, exposure: Double, rating: Int = 0, telling: Bool = false) throws {
        try SidecarStore().save(
            Sidecar(recipe: Self.recipe(exposure: exposure), metadata: PhotoMetadata(rating: rating)), for: photo(path),
        )
        if telling {
            library.sidecarSaved(photo(path))
        }
    }

    /// Where the library keeps its index and store.
    var paths: LibraryPaths {
        LibraryPaths(root: base.appending(path: "Library"))
    }

    /// The library indexes the root and shows it in an editor, in `module`, renders paused while
    /// `running` is false; `showing` makes views of the editor before the root opens. Unless `waiting`, the root
    /// opens at once, as a launch restores its folder, listed from the disk until the library can show it.
    func open(
        module: AppModule = .library, running: Bool = true, waiting: Bool = true,
        showing: (EditorModel) -> Void = { _ in },
    ) async throws {
        library.add([root])
        service = LibraryService(paths: paths, sidecars: library.sidecars) { url, size in
            StoreThumbnailMaker.imageIO(url, nil, size)
        }
        library.attach(service)
        for _ in 0 ..< (waiting ? 2000 : 0) {
            if await service.canShow(root, includingSubfolders: true) {
                break
            }
            try await Task.sleep(for: .milliseconds(10))
        }
        model = EditorModel(engine: editor, library: library)
        let engine = engine
        model.editRenders.makeEngine = { engine }
        model.editRenders.isRunning = running
        if module == .library {
            model.showModule(.library)
        }
        showing(model)
        model.open([root])
        try await eventually(seconds: 20) { self.library.isShownFromLibrary && !self.library.isListing }
        try #require(library.isShownFromLibrary, "the folder is shown from the library")
    }

    /// Closes the library as quitting does, then, after `whileClosed`, opens the root again in a new editor, as a
    /// launch does, its edits rendered by the same engine, renders paused while `running` is false; `showing` makes
    /// views of the editor before the root opens.
    func relaunch(
        running: Bool = true, waiting: Bool = true, whileClosed: () throws -> Void = {},
        showing: (EditorModel) -> Void = { _ in },
    ) async throws {
        model.editRenders.isRunning = false
        model.editRenders.letEngineGo()
        for window in windows {
            window.contentView = nil
        }
        service.close()
        try whileClosed()
        library = FolderLibrary()
        model = nil
        try await open(running: running, waiting: waiting, showing: showing)
    }

    /// The edit of the photo at `path` whose render the index records as stored, standing for its sidecar as it is.
    func recordedEdit(_ path: String) async throws -> EditDigest? {
        let index = try #require(service.core?.index)
        let url = photo(path)
        guard let id = await LibraryService.indexIDs(of: [url], in: index)[url] else { return nil }
        return try await index.read { try $0.standingPhotoEdits(ofPhotos: [id], renderer: EditRenders.renderer)[id] }
    }

    /// Waits until the index records `edit` as the photo at `path`'s render.
    func waitForRecord(_ path: String, _ edit: EditDigest) async throws {
        for _ in 0 ..< 2000 where try await recordedEdit(path) != edit {
            try await Task.sleep(for: .milliseconds(5))
        }
        try #require(try await recordedEdit(path) == edit, "the render of \(path)'s edit is recorded")
    }

    /// `view` in a window of its own, laid out.
    func show(_ view: NSView) {
        let window = NSWindow(contentRect: view.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = view
        view.layoutSubtreeIfNeeded()
        windows.append(window)
    }

    func eventually(seconds: Double = 10, _ condition: () -> Bool) async throws {
        for _ in 0 ..< Int(seconds * 200) where !condition() {
            try await Task.sleep(for: .milliseconds(5))
        }
    }

    func cleanUp() {
        for window in windows {
            window.contentView = nil
        }
        LibrarySandbox.remove(base, closing: [service])
    }

    /// The colour in the middle of `image`, in sRGB.
    static func colour(of image: CGImage?) -> (red: Double, green: Double, blue: Double)? {
        guard let image, let space = CGColorSpace(name: CGColorSpace.sRGB), let context = CGContext(
            data: nil, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4, space: space,
            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue,
        ) else { return nil }
        let middle = CGRect(x: image.width / 2, y: image.height / 2, width: 1, height: 1)
        guard let pixel = image.cropping(to: middle) else { return nil }
        context.draw(pixel, in: CGRect(x: 0, y: 0, width: 1, height: 1))
        guard let bytes = context.data?.assumingMemoryBound(to: UInt8.self) else { return nil }
        return (Double(bytes[0]) / 255, Double(bytes[1]) / 255, Double(bytes[2]) / 255)
    }

    /// Whether `image` is the grey a render of `exposure` is.
    static func isRender(_ image: CGImage?, exposure: Double) -> Bool {
        guard let colour = colour(of: image) else { return false }
        let shade = RenderEngine.shade(exposure)
        return [colour.red, colour.green, colour.blue].allSatisfy { abs($0 - shade) < 0.06 }
    }

    static func decoded(_ data: Data?) -> CGImage? {
        data.flatMap { StoreImageEncoder.decode($0) }
    }
}

/// Thumbnails and previews that show the edit (LIB-17): an edited photo's tiers rendered by the engine and
/// stored by its edit's digest, rendered again when the edit changes, the embedded preview first and marked
/// until then, on screen first, and never in Develop's way.
@MainActor
struct EditRendersTests {
    @Test func `an edited photo's grid and preview tiers are rendered with its edit at their sizes and stored by its digest`(
    ) async throws {
        let fixture = EditRenderFixture()
        defer { fixture.cleanUp() }
        try fixture.photos(["IMG_1.JPG", "IMG_2.JPG", "IMG_3.JPG"])
        try fixture.edit("IMG_2.JPG", exposure: 1)
        try await fixture.open()
        let digest = try EditRenderFixture.digest(exposure: 1)
        let item = try #require(fixture.item("IMG_2.JPG"))
        try await fixture.eventually { fixture.renders.shownEdit(for: item) == digest }
        #expect(fixture.renders.shownEdit(for: item) == digest)

        let key = try #require(fixture.key("IMG_2.JPG"))
        let grid = EditRenderFixture.decoded(fixture.store.data(
            for: key, tier: .grid, edit: digest, size: item.size, modified: item.modified,
        ))
        let preview = EditRenderFixture.decoded(fixture.store.data(
            for: key, tier: .preview, edit: digest, size: item.size, modified: item.modified,
        ))
        #expect(grid?.width == 384 && grid?.height == 256, "the grid tier's size")
        #expect(preview?.width == 2048 && preview?.height == 1365, "the preview tier's size")
        #expect(EditRenderFixture.isRender(grid, exposure: 1) && EditRenderFixture.isRender(preview, exposure: 1))
        #expect(fixture.store.edits(of: key) == [digest])
        let request = try #require(fixture.engine.rendered.withLock { $0.last })
        #expect(request.recipe[.exposure] == 1 && request.maxLongEdge == 2048 && request.purpose == .preview)
        #expect(request.colorSpace == .displayP3 && request.source == fixture.photo("IMG_2.JPG"))
        #expect(fixture.engine.opened.withLock { $0 } == [fixture.photo("IMG_2.JPG")], "only the edited photo")
        for unedited in ["IMG_1.JPG", "IMG_3.JPG"] {
            #expect(try fixture.store.edits(of: #require(fixture.key(unedited))).isEmpty)
        }
        #expect(fixture.renders.statistics.rendered == 1 && fixture.renders.statistics.failed == 0)

        let thumbnail = await fixture.model.thumbnailLoader.image(for: item)
        #expect(EditRenderFixture.isRender(thumbnail, exposure: 1), "the filmstrip's thumbnail is the render")
        let other = try await fixture.model.thumbnailLoader.image(for: #require(fixture.item("IMG_1.JPG")))
        #expect(other != nil && !EditRenderFixture.isRender(other, exposure: 1))
    }

    @Test func `a changed edit is rendered again, and once it's read the old edit's render is never shown`(
    ) async throws {
        let fixture = EditRenderFixture()
        defer { fixture.cleanUp() }
        try fixture.photos(["IMG_1.JPG", "IMG_2.JPG"])
        try fixture.edit("IMG_1.JPG", exposure: 1)
        try await fixture.open()
        let (brighter, darker) = try (EditRenderFixture.digest(exposure: 1), EditRenderFixture.digest(exposure: -1))
        let key = try #require(fixture.key("IMG_1.JPG"))
        try await fixture.eventually { fixture.item("IMG_1.JPG").flatMap(fixture.renders.shownEdit(for:)) != nil }
        let before = try #require(fixture.item("IMG_1.JPG"))
        #expect(fixture.renders.shownEdit(for: before) == brighter)

        fixture.engine.gate.hold()
        try fixture.edit("IMG_1.JPG", exposure: -1, telling: true)
        try await fixture.eventually { fixture.engine.gate.arrived == 1 }
        #expect(fixture.engine.gate.arrived == 1, "the new edit is rendered")
        let changed = try #require(fixture.item("IMG_1.JPG"))
        #expect(changed.sidecarModified != before.sidecarModified)
        #expect(fixture.renders.shownEdit(for: changed) == nil, "its embedded preview shows meanwhile")
        let meanwhile = await fixture.model.thumbnailLoader.image(for: changed)
        #expect(meanwhile != nil && !EditRenderFixture.isRender(meanwhile, exposure: 1), "not the old edit's render")
        let preview = await withCheckedContinuation { continuation in
            fixture.model.previews.request(changed) { continuation.resume(returning: $0) }
        }
        #expect(preview != nil && !EditRenderFixture.isRender(preview, exposure: 1))
        try await fixture.eventually { !fixture.store.edits(of: key).contains(brighter) }
        #expect(!fixture.store.edits(of: key).contains(brighter), "the old edit's tiers leave the store")

        fixture.engine.gate.release()
        try await fixture.eventually { fixture.renders.shownEdit(for: changed) == darker }
        #expect(fixture.renders.shownEdit(for: changed) == darker)
        #expect(fixture.store.edits(of: key) == [darker])
        let after = await fixture.model.thumbnailLoader.image(for: changed)
        #expect(EditRenderFixture.isRender(after, exposure: -1))

        try fixture.edit("IMG_1.JPG", exposure: -1, rating: 3, telling: true)
        try await fixture.eventually { fixture.item("IMG_1.JPG")?.metadata.rating == 3 }
        let rated = try #require(fixture.item("IMG_1.JPG"))
        #expect(rated.metadata.rating == 3 && rated.sidecarModified != changed.sidecarModified)
        try await fixture
            .eventually { fixture.renders.known[rated.url].map { EditRenders.isCurrent($0, for: rated) } == true }
        #expect(fixture.renders.shownEdit(for: rated) == darker, "a rating saved with the same edit renders nothing")
        #expect(fixture.engine.rendered.withLock { $0.count } == 2)
    }

    @Test func `the embedded preview shows first, marked in the grid and the loupe, then the edit's render without the mark`(
    ) async throws {
        let fixture = EditRenderFixture()
        defer { fixture.cleanUp() }
        try fixture.photos(["IMG_1.JPG", "IMG_2.JPG"])
        try fixture.edit("IMG_1.JPG", exposure: 1)
        fixture.engine.gate.hold()
        try await fixture.open()
        let model = try #require(fixture.model)
        let grid = LibraryGridView(model: model)
        fixture.show(grid)
        try await fixture.eventually { grid.cells[0]?.image != nil && grid.cells[1]?.image != nil }
        let edited = try #require(grid.cells[0])
        let plain = try #require(grid.cells[1])
        #expect(edited.image != nil && edited.showsUneditedPreview, "the embedded preview, marked")
        #expect(!EditRenderFixture.isRender(edited.image, exposure: 1))
        #expect(plain.image != nil && !plain.showsUneditedPreview, "an unedited photo has no mark")

        model.showLibrary(.loupe)
        let loupe = LibraryLoupeView(model: model)
        fixture.show(loupe)
        try await fixture.eventually { loupe.showsPreview }
        #expect(loupe.image != nil && loupe.showsUneditedPreview, "the loupe marks the embedded preview too")
        #expect(loupe.accessibilityValue() as? String == "Unedited preview")

        let item = try #require(fixture.item("IMG_1.JPG"))
        try await fixture.eventually { model.thumbnailLoader.cached(item) != nil }
        try await fixture.eventually { fixture.engine.gate.arrived == 1 }
        fixture.engine.gate.release()
        let digest = try EditRenderFixture.digest(exposure: 1)
        try await fixture.eventually { fixture.renders.shownEdit(for: item) == digest }
        let meanwhile = model.thumbnailLoader.cachedThumbnail(item)
        #expect(
            meanwhile != nil && meanwhile?.edit == nil && !model.thumbnailLoader.hasThumbnail(item),
            "until the render's thumbnail is decoded, the embedded preview's is shown rather than none",
        )
        try await fixture.eventually { edited.shownEdit == digest && loupe.shownEdit == digest }
        #expect(edited.shownEdit == digest && !edited.showsUneditedPreview, "the render, unmarked")
        #expect(EditRenderFixture.isRender(edited.image, exposure: 1))
        #expect(loupe.shownEdit == digest && !loupe.showsUneditedPreview)
        #expect(EditRenderFixture.isRender(loupe.image, exposure: 1))
        #expect(plain.shownEdit == nil && !plain.showsUneditedPreview)
    }

    @Test func `photos on screen render first, then their neighbours nearest first, then the rest, and a render whose photo leaves the source is cancelled`(
    ) async throws {
        let fixture = EditRenderFixture()
        defer { fixture.cleanUp() }
        let names = (0 ..< 24).map { String(format: "IMG_%02d.JPG", $0) }
        try fixture.photos(names + ["Other/IMG_99.JPG"])
        for name in names {
            try fixture.edit(name, exposure: 1)
        }
        try await fixture.open(running: false)
        let renders = fixture.renders
        renders.show(10 ..< 13, in: .grid)
        try await fixture.eventually { renders.known.count == names.count }
        #expect(renders.known.count == names.count, "every photo's edit is read before any renders")
        #expect(fixture.engine.opened.withLock { $0.isEmpty })

        renders.isRunning = true
        try await fixture.eventually { renders.statistics.rendered == names.count }
        let order = fixture.engine.opened.withLock { $0 }.map(\.lastPathComponent)
        // The active photo (the first) and the grid's rows, then a row further from each at a time.
        let expected = [0, 10, 11, 12, 1, 9, 13, 2, 8, 14, 3, 7, 15, 4, 5, 6] + Array(16 ..< 24)
        #expect(order == expected.map { names[$0] })

        fixture.engine.gate.hold()
        let key = try #require(fixture.key(names[5]))
        try fixture.edit(names[5], exposure: -1, telling: true)
        try await fixture.eventually { fixture.engine.gate.arrived == 1 }
        #expect(renders.current?.url == fixture.photo(names[5]))
        fixture.model.showFolder(fixture.root.appending(path: "Other", directoryHint: .isDirectory))
        try await fixture.eventually { fixture.library.items.map(\.name) == ["IMG_99.JPG"] }
        fixture.engine.gate.release()
        try await fixture.eventually { renders.current == nil }
        #expect(renders.current == nil && fixture.engine.cancelled.withLock { $0 } == 1, "the render is cancelled")
        #expect(renders.statistics.rendered == names.count, "nothing more is stored")
        #expect(try !fixture.store.edits(of: key).contains(EditRenderFixture.digest(exposure: -1)))
        #expect(renders.known[fixture.photo(names[5])] == nil, "what's left the source is forgotten")
    }

    @Test func `an open dialog or an export running holds the renders until it's done`() async throws {
        let fixture = EditRenderFixture()
        defer { fixture.cleanUp() }
        try fixture.photos(["IMG_1.JPG", "IMG_2.JPG"])
        try fixture.edit("IMG_2.JPG", exposure: 1)
        try await fixture.open(running: false)
        let model = try #require(fixture.model)
        try await fixture.eventually { fixture.renders.known.count == 1 }
        model.isModalDialogOpen = true
        fixture.renders.isRunning = true
        try await Task.sleep(for: .milliseconds(600))
        #expect(fixture.engine.opened.withLock { $0.isEmpty }, "nothing opens while a dialog is open")
        model.isModalDialogOpen = false
        model.exportStatus = "Exporting IMG_1.JPG…"
        try await Task.sleep(for: .milliseconds(600))
        #expect(fixture.engine.opened.withLock { $0.isEmpty }, "nor while an export runs")
        model.exportStatus = nil
        try await fixture.eventually { fixture.renders.statistics.rendered == 1 }
        #expect(fixture.renders.statistics.rendered == 1 && fixture.renders.statistics.waits == 1)
    }

    @Test func `the renders Develop asks for never wait behind the queue's, which waits for Develop to be quiet between its steps`(
    ) async throws {
        let fixture = EditRenderFixture()
        defer { fixture.cleanUp() }
        try fixture.photos(["IMG_1.JPG", "IMG_2.JPG", "IMG_3.JPG"])
        try fixture.edit("IMG_2.JPG", exposure: 1)
        try fixture.edit("IMG_3.JPG", exposure: -1)
        try await fixture.open(module: .develop)
        let model = try #require(fixture.model)
        try await fixture.eventually { model.info?.url == fixture.photo("IMG_1.JPG") }
        try #require(model.info?.url == fixture.photo("IMG_1.JPG"))
        let renders = fixture.renders

        // Develop renders a frame every 50 ms for 1.5 s: the queue opens nothing meanwhile.
        fixture.engine.gate.hold()
        var asked = ContinuousClock.now
        for _ in 0 ..< 30 {
            model.requestRender()
            asked = .now
            try await Task.sleep(for: .milliseconds(50))
        }
        #expect(fixture.engine.opened.withLock { $0.isEmpty }, "nothing opened while Develop renders")
        try await fixture.eventually { fixture.engine.gate.arrived == 1 }
        #expect(fixture.engine.opened.withLock { $0.count } == 1, "a photo opened once Develop was quiet")
        let opened = try #require(fixture.engine.openedAt.withLock { $0.first })
        #expect(opened - asked >= EditRenders.developQuiet, "a second after Develop's last frame")

        // Develop's frames go straight to its own engine while the queue's render runs.
        let requested = renders.statistics.overlaps
        model.setValue(.exposure, 0.4)
        #expect(fixture.editor.lastRender?.recipe[.exposure] == 0.4, "Develop's frame isn't held up")
        #expect(renders.statistics.overlaps > requested, "and the overlap is counted")

        // The next photo waits for Develop to be quiet again.
        fixture.engine.gate.release()
        try await fixture.eventually { renders.statistics.rendered == 1 }
        for _ in 0 ..< 16 {
            model.requestRender()
            asked = .now
            try await Task.sleep(for: .milliseconds(50))
        }
        #expect(fixture.engine.opened.withLock { $0.count } == 1, "the next photo waits while Develop renders")
        try await fixture.eventually { renders.statistics.rendered == 2 }
        #expect(renders.statistics.rendered == 2)
        let next = try #require(fixture.engine.openedAt.withLock { $0.last })
        #expect(next - asked >= EditRenders.developQuiet)
        #expect(!fixture.engine.opened.withLock { $0 }.contains(fixture.photo("IMG_1.JPG")))
    }
}

@MainActor
extension EditRendersTests {
    @Test func `closing the window lets the renders' engine and the thumbnails off screen go, and renders wait for it`(
    ) async throws {
        let fixture = EditRenderFixture()
        defer { fixture.cleanUp() }
        try fixture.photos(["IMG_1.JPG", "IMG_2.JPG", "IMG_3.JPG"])
        try fixture.edit("IMG_2.JPG", exposure: 1)
        try fixture.edit("IMG_3.JPG", exposure: 0.5)
        try await fixture.open()
        let model = try #require(fixture.model)
        let renders = fixture.renders
        try await fixture.eventually { renders.statistics.rendered == 2 }
        #expect(renders.engine != nil, "kept for the next render")
        let thumbnails = GridThumbnails(
            scheduler: fixture.library.scheduler, packs: model.thumbnailLoader.packs,
            store: { [weak library = fixture.library] in library?.storeThumbnail(for: $0) }, renders: renders,
            decode: model.thumbnailLoader.decode,
        )
        for name in ["IMG_1.JPG", "IMG_3.JPG"] {
            try await fixture.eventually {
                guard let item = fixture.item(name) else { return false }
                if thumbnails.cached(item, edge: 256) == nil {
                    thumbnails.request(item, edge: 256) { _ in }
                }
                return thumbnails.cached(item, edge: 256) != nil
            }
        }
        let (shown, hidden) = try (#require(fixture.item("IMG_1.JPG")), #require(fixture.item("IMG_3.JPG")))
        try #require(thumbnails.cached(shown, edge: 256) != nil && thumbnails.cached(hidden, edge: 256) != nil)
        thumbnails.protected = [shown.url]

        model.windowClosed()
        try await fixture.eventually { !renders.isWindowOpen }
        #expect(renders.engine == nil)
        #expect(thumbnails.cached(shown, edge: 256) != nil && thumbnails.cached(hidden, edge: 256) == nil)
        try fixture.edit("IMG_3.JPG", exposure: -1, telling: true)
        try await Task.sleep(for: .milliseconds(600))
        #expect(renders.statistics.rendered == 2 && renders.engine == nil, "nothing renders while it's closed")

        model.windowReopened()
        try await fixture.eventually { renders.statistics.rendered == 3 }
        #expect(renders.statistics.rendered == 3)
    }
}

/// The first thumbnail each photo's cell showed in a grid: the edit it was the render of, `EditDigest.unedited` for
/// the embedded preview.
@MainActor
final class FirstThumbnails {
    private(set) var edits: [URL: EditDigest] = [:]

    /// Looks at `grid`'s cells every millisecond for `seconds`.
    func follow(_ grid: LibraryGridView, seconds: Double = 20) {
        Task { [weak self, weak grid] in
            let end = ContinuousClock.now + .seconds(seconds)
            while ContinuousClock.now < end, let self, let grid {
                for cell in grid.cells.values where cell.image != nil {
                    if let url = cell.item?.url, edits[url] == nil {
                        edits[url] = cell.shownEdit ?? .unedited
                    }
                }
                try? await Task.sleep(for: .milliseconds(1))
            }
        }
    }
}

/// Renders after a relaunch (LIB-17): the index records each photo's edit whose render is stored, so the render shows
/// from the start, until the photo's sidecar says otherwise; and a photo's first edit renders wherever it is.
@MainActor
extension EditRendersTests {
    @Test func `after a relaunch, an edited photo's stored render shows from the start, before its sidecar is read again`(
    ) async throws {
        let fixture = EditRenderFixture()
        defer { fixture.cleanUp() }
        try fixture.photos(["IMG_1.JPG", "IMG_2.JPG"])
        try fixture.edit("IMG_1.JPG", exposure: 1)
        try await fixture.open()
        let digest = try EditRenderFixture.digest(exposure: 1)
        try await fixture.eventually { fixture.item("IMG_1.JPG").flatMap(fixture.renders.shownEdit(for:)) == digest }
        try await fixture.waitForRecord("IMG_1.JPG", digest)
        #expect(try await fixture.recordedEdit("IMG_2.JPG") == nil, "an unedited photo has none")

        let first = FirstThumbnails()
        var grid: LibraryGridView?
        try await fixture.relaunch(running: false, showing: { model in
            let view = LibraryGridView(model: model)
            fixture.show(view)
            first.follow(view)
            grid = view
        })
        let (edited, plain) = (fixture.photo("IMG_1.JPG"), fixture.photo("IMG_2.JPG"))
        let item = try #require(fixture.library.item(for: edited))
        #expect(item.renderedEdit == digest, "the photo comes from the index with the edit whose render is stored")
        #expect(fixture.library.item(for: plain)?.renderedEdit == nil)
        try await fixture.eventually { first.edits[edited] != nil && first.edits[plain] != nil }
        #expect(first.edits[edited] == digest, "the grid's first thumbnail of it is its render")
        #expect(first.edits[plain] == .unedited)
        let cell = try #require(grid?.cells.values.first { $0.item?.url == edited })
        #expect(!cell.showsUneditedPreview && EditRenderFixture.isRender(cell.image, exposure: 1), "unmarked")
        let thumbnail = await fixture.model.thumbnailLoader.image(for: item)
        #expect(EditRenderFixture.isRender(thumbnail, exposure: 1), "and the filmstrip's is too")
        try await fixture.eventually { fixture.renders.isRendered(item) == true }
        #expect(fixture.renders.isRendered(item) == true, "its sidecar, read again, holds the same edit")
        #expect(fixture.engine.rendered.withLock { $0.count } == 1, "rendered once")
    }

    @Test func `an edit changed while Redlamp was closed is rendered again, and once its sidecar is read the old render never shows`(
    ) async throws {
        let fixture = EditRenderFixture()
        defer { fixture.cleanUp() }
        try fixture.photos(["IMG_1.JPG", "IMG_2.JPG"])
        try fixture.edit("IMG_1.JPG", exposure: 1)
        try await fixture.open()
        let (brighter, darker) = try (EditRenderFixture.digest(exposure: 1), EditRenderFixture.digest(exposure: -1))
        try await fixture.eventually { fixture.item("IMG_1.JPG").flatMap(fixture.renders.shownEdit(for:)) == brighter }
        try await fixture.waitForRecord("IMG_1.JPG", brighter)

        fixture.engine.gate.hold()
        // Saved meanwhile by another Mac, or another app.
        try await fixture.relaunch(whileClosed: { try fixture.edit("IMG_1.JPG", exposure: -1) })
        let url = fixture.photo("IMG_1.JPG")
        try await fixture.eventually { fixture.renders.known[url]?.digest == darker }
        #expect(fixture.renders.known[url]?.digest == darker, "its sidecar is read again")
        let read = try #require(fixture.item("IMG_1.JPG"))
        #expect(fixture.renders.shownEdit(for: read) == nil, "its embedded preview shows until the new edit renders")
        let meanwhile = await fixture.model.thumbnailLoader.image(for: read)
        #expect(meanwhile != nil && !EditRenderFixture.isRender(meanwhile, exposure: 1), "never the old edit's render")

        try await fixture.eventually { fixture.engine.gate.arrived == 1 }
        fixture.engine.gate.release()
        try await fixture.eventually { fixture.item("IMG_1.JPG").flatMap(fixture.renders.shownEdit(for:)) == darker }
        #expect(fixture.item("IMG_1.JPG").flatMap(fixture.renders.shownEdit(for:)) == darker)
        try await fixture.waitForRecord("IMG_1.JPG", darker)
        let key = try #require(fixture.key("IMG_1.JPG"))
        #expect(fixture.store.edits(of: key) == [darker], "the old edit's tiers leave the store")
    }

    @Test func `a recorded render the store no longer holds is made again, the embedded preview showing meanwhile`(
    ) async throws {
        let fixture = EditRenderFixture()
        defer { fixture.cleanUp() }
        try fixture.photos(["IMG_1.JPG", "IMG_2.JPG"])
        try fixture.edit("IMG_1.JPG", exposure: 1)
        try await fixture.open()
        let digest = try EditRenderFixture.digest(exposure: 1)
        try await fixture.eventually { fixture.item("IMG_1.JPG").flatMap(fixture.renders.shownEdit(for:)) == digest }
        try await fixture.waitForRecord("IMG_1.JPG", digest)
        let store = fixture.store.root

        fixture.engine.gate.hold()
        try await fixture.relaunch(whileClosed: { try FileManager.default.removeItem(at: store) })
        let item = try #require(fixture.item("IMG_1.JPG"))
        #expect(item.renderedEdit == digest, "the index still records it")
        _ = await fixture.model.thumbnailLoader.image(for: item)
        try await fixture.eventually { fixture.renders.shownEdit(for: item) == nil }
        #expect(fixture.renders.shownEdit(for: item) == nil, "its embedded preview shows meanwhile")
        let meanwhile = await fixture.model.thumbnailLoader.image(for: item)
        #expect(meanwhile != nil && !EditRenderFixture.isRender(meanwhile, exposure: 1))

        try await fixture.eventually { fixture.engine.gate.arrived == 1 }
        fixture.engine.gate.release()
        try await fixture.eventually { fixture.renders.shownEdit(for: item) == digest }
        let after = await fixture.model.thumbnailLoader.image(for: item)
        #expect(EditRenderFixture.isRender(after, exposure: 1), "rendered again")
    }

    @Test func `a folder listed from the disk before the library opens shows its stored renders once the library takes it over`(
    ) async throws {
        let fixture = EditRenderFixture()
        defer { fixture.cleanUp() }
        let names = (0 ..< 6).map { String(format: "IMG_%02d.JPG", $0) }
        try fixture.photos(names)
        for name in names.prefix(4) {
            try fixture.edit(name, exposure: 1)
        }
        try await fixture.open()
        let digest = try EditRenderFixture.digest(exposure: 1)
        try await fixture.eventually { fixture.renders.statistics.rendered == 4 }
        try await fixture.waitForRecord(names[3], digest)

        // An index without the records (made before them, say), so each photo's sidecar must be read again.
        let index = fixture.paths.index
        try await fixture.relaunch(running: false, waiting: false, whileClosed: {
            try SQLiteDatabase(path: index.path).execute("DELETE FROM photo_edits")
        })
        let urls = names.prefix(4).map { fixture.photo($0) }
        try await fixture.eventually {
            urls.allSatisfy { fixture.library.item(for: $0).flatMap(fixture.renders.shownEdit(for:)) == digest }
        }
        for url in urls {
            let item = try #require(fixture.library.item(for: url))
            #expect(item.renderedEdit == nil, "nothing recorded for it")
            #expect(fixture.renders.shownEdit(for: item) == digest, "its render, its sidecar read again")
        }
        #expect(fixture.engine.rendered.withLock { $0.count } == 4, "none rendered again")
    }

    @Test func `a photo's first edit made off screen is rendered in the background, as other edits are`() async throws {
        let fixture = EditRenderFixture()
        defer { fixture.cleanUp() }
        let names = (0 ..< 24).map { String(format: "IMG_%02d.JPG", $0) }
        try fixture.photos(names)
        try fixture.edit(names[1], exposure: 1)
        try await fixture.open()
        let renders = fixture.renders
        renders.show(0 ..< 3, in: .grid)
        try await fixture.eventually { renders.statistics.rendered == 1 }
        try #require(renders.statistics.rendered == 1)
        // The rest of the source looked at, with nothing more to render.
        try await Task.sleep(for: .milliseconds(300))

        // Paste, Sync or another Mac gives a photo far off screen its first edit.
        try fixture.edit(names[20], exposure: -1, telling: true)
        try await fixture.eventually { renders.statistics.rendered == 2 }
        #expect(renders.statistics.rendered == 2, "rendered without coming near the screen")
        #expect(fixture.engine.opened.withLock { $0.last } == fixture.photo(names[20]))
        let item = try #require(fixture.item(names[20]))
        #expect(try renders.shownEdit(for: item) == EditRenderFixture.digest(exposure: -1))
    }

    @Test func `in a large folder too, a photo's first edit made off screen is rendered in the background`(
    ) async throws {
        let fixture = EditRenderFixture()
        defer { fixture.cleanUp() }
        let names = (0 ..< 24).map { String(format: "IMG_%02d.JPG", $0) }
        try fixture.photos(names)
        try fixture.edit(names[1], exposure: 1)
        fixture.library.largestRead = 8
        fixture.library.firstRead = 4
        try await fixture.open()
        try await fixture.eventually { fixture.model.items.readsOnRequest && fixture.model.items.count == names.count }
        try #require(fixture.model.items.readsOnRequest, "shown as a large folder")
        let renders = fixture.renders
        renders.show(0 ..< 3, in: .grid)
        try await fixture.eventually { renders.statistics.rendered == 1 }
        try #require(renders.statistics.rendered == 1)
        try await Task.sleep(for: .milliseconds(300))

        try fixture.edit(names[20], exposure: -1, telling: true)
        try await fixture.eventually { renders.statistics.rendered == 2 }
        #expect(renders.statistics.rendered == 2, "rendered though its row was never on screen")
        #expect(fixture.engine.opened.withLock { $0.last } == fixture.photo(names[20]))
    }
}
