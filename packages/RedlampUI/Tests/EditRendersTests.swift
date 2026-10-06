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
    let rendered = Mutex<[StillRequest]>([])
    /// Renders that found themselves cancelled once through the gate.
    let cancelled = Mutex(0)

    static let size = PixelSize(width: 3000, height: 2000)

    static func shade(_ exposure: Double) -> Double {
        0.5 + exposure * 0.2
    }

    func open(_ url: URL) async throws -> ImageInfo {
        opened.withLock { $0.append(url) }
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

    func refineMaskEdges(_ bitmap: MaskBitmap) async throws -> MaskBitmap {
        try await base.refineMaskEdges(bitmap)
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
    let library = FolderLibrary()
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

    /// The library indexes the root and shows it in an editor, in `module`, renders paused while
    /// `running` is false.
    func open(module: AppModule = .library, running: Bool = true) async throws {
        library.add([root])
        service = LibraryService(
            paths: LibraryPaths(root: base.appending(path: "Library")),
            sidecars: library.sidecars,
        ) {
            url, size in StoreThumbnailMaker.imageIO(url, nil, size)
        }
        library.attach(service)
        for _ in 0 ..< 2000 {
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
        model.open([root])
        try await eventually(seconds: 20) { self.library.isShownFromLibrary && !self.library.isListing }
        try #require(library.isShownFromLibrary, "the folder is shown from the library")
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
        service?.close()
        try? FileManager.default.removeItem(at: base)
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

    @Test func `Develop's renders never wait behind the queue's, which waits for Develop to be quiet between its steps`(
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
        for _ in 0 ..< 30 {
            model.requestRender()
            try await Task.sleep(for: .milliseconds(50))
        }
        #expect(fixture.engine.opened.withLock { $0.isEmpty }, "nothing opened while Develop renders")
        try await fixture.eventually { fixture.engine.gate.arrived == 1 }
        #expect(fixture.engine.opened.withLock { $0.count } == 1, "a photo opened once Develop was quiet")
        #expect(renders.statistics.waits >= 1 && renders.statistics.waited >= .milliseconds(900))

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
            try await Task.sleep(for: .milliseconds(50))
        }
        #expect(fixture.engine.opened.withLock { $0.count } == 1, "the next photo waits while Develop renders")
        try await fixture.eventually { renders.statistics.rendered == 2 }
        #expect(renders.statistics.rendered == 2)
        #expect(!fixture.engine.opened.withLock { $0 }.contains(fixture.photo("IMG_1.JPG")))
    }
}
