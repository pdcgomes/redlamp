import CoreGraphics
import Foundation
import RedlampEngineAPI
import Testing
@testable import RedlampUI

/// An engine that opens anything instantly and renders nothing: enough to drive the editor.
final class StubEngine: EditingEngine, @unchecked Sendable {
    var sampledColor = SIMD3<Double>(0.62, 0, 0)
    /// What `detectLines` finds, for automatic Upright.
    var detectedLines: [DetectedLine] = []
    /// What the library reads focus stacks from.
    var files: any FileInspecting = UnreadableFiles()

    func detectLines() async -> [DetectedLine] {
        detectedLines
    }

    /// Where `retouchSource` says a spot should copy from; nil finds none.
    var retouchSource: ImagePoint?

    func retouchSource(for _: RetouchSpot, recipe _: EditRecipe) async -> ImagePoint? {
        retouchSource
    }

    /// What `detectDust` finds.
    var dust: [DetectedSpot] = []

    func detectDust(recipe _: EditRecipe, sensitivity _: Double) async -> [DetectedSpot] {
        dust
    }

    /// What `detectDust(in:)` finds, and the photos it was asked about.
    var shootDust: [URL: [DetectedSpot]] = [:]
    var shootPhotos: [URL] = []

    func detectDust(
        in photos: [(url: URL, recipe: EditRecipe)], sensitivity _: Double, progress: @escaping @Sendable (Int) -> Void,
    ) async -> [URL: [DetectedSpot]] {
        shootPhotos = photos.map(\.url)
        progress(photos.count)
        return shootDust
    }

    /// Whether generative fill can run; the spots `generateFills` was asked to fill, how long it
    /// takes, and how often the model was let go.
    var generativeAvailability = GenerativeFillAvailability.unavailable("")
    var generatedFor: [UUID] = []
    var generationTime = Duration.zero
    var generativeReleases = 0
    /// Why generative fill may not work here, and what `generateFills` throws instead of filling.
    var generativeCaution: String?
    var fillError: (any Error)?

    func generativeFillAvailability() async -> GenerativeFillAvailability {
        generativeAvailability
    }

    func generativeFillCaution() async -> String? {
        generativeCaution
    }

    /// One fill for each seed, each with its own bitmap.
    func generateFills(
        for spot: RetouchSpot, in _: EditRecipe, seeds: [Int], options _: GenerativeFillOptions,
        progress: @escaping @Sendable (Double) -> Void,
    ) async throws -> [GeneratedFill] {
        generatedFor.append(spot.id)
        let made = generatedFor.count
        progress(0.5)
        try await Task.sleep(for: generationTime)
        if let fillError {
            throw fillError
        }
        return seeds.map { seed in
            GeneratedFill(
                bitmap: MaskBitmap(png: Data("fill \(made) \(seed)".utf8), width: 1, height: 1), peak: 1,
                box: .init(x: 0, y: 0, width: 1, height: 1), photoSize: PixelSize(width: 1, height: 1),
                model: "stub", modelVersion: 1, seed: seed, prompt: "remove",
            )
        }
    }

    func releaseGenerativeFill() async {
        generativeReleases += 1
    }

    /// What `open` throws instead of opening the photo.
    var openError: (any Error)?
    /// The size of every photo it opens.
    var pixelSize = PixelSize(width: 600, height: 400)

    func open(_ url: URL) async throws -> ImageInfo {
        if let openError {
            throw openError
        }
        return ImageInfo(
            url: url,
            pixelSize: pixelSize,
            isRaw: true,
            sensorDescription: "stub",
        )
    }

    /// Photos `openIfReady` opens at once, as if decoded ahead.
    var ready: Set<URL> = []

    func openIfReady(_ url: URL) -> ImageInfo? {
        guard ready.contains(url) else { return nil }
        return ImageInfo(
            url: url,
            pixelSize: pixelSize,
            isRaw: true,
            sensorDescription: "stub",
        )
    }

    func prefetch(_: [URL]) {}
    /// Every render asked for, most recent last.
    var renders: [RenderRequest] = []
    /// The last render asked for.
    var lastRender: RenderRequest? {
        renders.last
    }

    func render(_ request: RenderRequest) {
        renders.append(request)
    }

    func frames() -> AsyncStream<RenderedFrame> {
        AsyncStream { _ in }
    }

    /// Every still asked for, most recent last.
    var stills: [StillRequest] = []

    /// A grey still at the requested size, or the photo's.
    func renderStill(_ request: StillRequest) async throws -> CGImage {
        stills.append(request)
        let size = request.maxLongEdge.map { PixelSize(width: 600, height: 400).fitted(within: PixelSize(
            width: $0,
            height: $0,
        )) }
            ?? PixelSize(width: 600, height: 400)
        guard let space = CGColorSpace(name: CGColorSpace.sRGB), let context = CGContext(
            data: nil, width: size.width, height: size.height, bitsPerComponent: 8, bytesPerRow: 0,
            space: space, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue,
        ) else { throw CancellationError() }
        context.setFillColor(gray: 0.5, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: size.width, height: size.height))
        guard let image = context.makeImage() else { throw CancellationError() }
        return image
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

    func maskColor(sampledAt _: CGPoint, recipe _: EditRecipe) async -> SIMD3<Double>? {
        sampledColor
    }

    /// What Point Color's eyedropper finds.
    var pointColorSample: OKLCh? = OKLCh(lightness: 0.7, chroma: 0.08, hue: 55)

    func pointColorInput(sampledAt _: CGPoint, radius _: Double, recipe _: EditRecipe) async -> OKLCh? {
        pointColorSample
    }

    var computed: [AIMask] = []

    var lastRequest: MaskRequest?
    /// Every AI mask asked for, in order.
    var requests: [MaskRequest] = []

    /// People parts `computeMasks` can't compute, as without SAM 3.
    var missingParts: Set<PersonPart> = []

    func computeMasks(_ request: MaskRequest) async throws -> [AIMask] {
        lastRequest = request
        requests.append(request)
        if request.kind == .people, missingParts.contains(request.part) {
            throw MaskComputationError.needsSAM3(request.part)
        }
        let masks = computed.map { mask in
            var mask = mask
            mask.kind = request.kind
            if !request.prompts.isEmpty {
                mask.prompts = request.prompts
            }
            if !request.excluded.isEmpty {
                mask.excludedPrompts = request.excluded
            }
            mask.box = request.box ?? mask.box
            if request.people != nil {
                mask.part = request.part.rawValue
            }
            return mask
        }
        guard request.kind == .people, let chosen = request.people else { return masks }
        return masks.filter { $0.instance.map(chosen.contains) ?? true }
    }

    /// Who `peopleFound` reports.
    var people: [PersonFound] = []

    func peopleFound() async throws -> [PersonFound] {
        people
    }

    /// What `withShadowAndReflection` gives in place of a mask; nil gives the mask itself.
    var withShadow: AIMask?

    func withShadowAndReflection(_ mask: AIMask) async -> AIMask {
        withShadow ?? mask
    }

    var availableKinds: Set<MaskKind> = [.subject, .background, .people, .sky, .objects]

    func availableMaskKinds() -> Set<MaskKind> {
        availableKinds
    }

    var personParts = Set(PersonPart.allCases)

    func availablePersonParts() -> Set<PersonPart> {
        personParts
    }

    var neededModel: ModelInfo?
    /// The mask kinds and People parts `neededModel` is for.
    var kindsNeedingModel: Set<MaskKind> = [.objects]
    var partsNeedingModel: Set<PersonPart> = []
    var downloaded: [String] = []

    func modelNeeded(for kind: MaskKind) async -> ModelInfo? {
        kindsNeedingModel.contains(kind) ? neededModel : nil
    }

    func modelNeeded(for kind: MaskKind, part: PersonPart) async -> ModelInfo? {
        kind == .people && partsNeedingModel.contains(part) ? neededModel : await modelNeeded(for: kind)
    }

    /// What Find can look for and finds, the model it still needs, and what it was last asked for.
    var things: [String] = []
    var found: [FoundThing] = []
    var findingModel: ModelInfo?
    var lastFind: Set<String>?

    func thingsToFind() async -> [String] {
        things
    }

    func modelNeededToFind() async -> ModelInfo? {
        findingModel
    }

    func findThings(_ wanted: Set<String>, threshold _: Double) async throws -> [FoundThing] {
        lastFind = wanted
        return found.filter { wanted.contains($0.thing) }
    }

    func models() async -> [ModelInfo] {
        neededModel.map { [$0] } ?? []
    }

    func downloadModel(_ id: String, progress: @escaping @Sendable (Double) -> Void) async throws {
        progress(1)
        downloaded.append(id)
        neededModel = nil
    }

    func removeModel(_: String) async throws {}

    func previewObjectMask(_: MaskRequest) async throws -> MaskBitmap? {
        nil
    }

    func refineMaskEdges(_ mask: AIMask) async throws -> MaskBitmap {
        MaskBitmap(sha256: mask.bitmap.sha256 + "-refined", width: mask.bitmap.width, height: mask.bitmap.height)
    }

    var brushRefinements: [[BrushStroke]] = []

    func refineMaskEdges(_ bitmap: MaskBitmap, along strokes: [BrushStroke]) async throws -> MaskBitmap {
        brushRefinements.append(strokes)
        return MaskBitmap(
            sha256: bitmap.sha256 + "-brushed\(strokes.count)",
            width: bitmap.width,
            height: bitmap.height,
        )
    }

    func thumbnail(for _: URL, maxPixelSize _: Int) async -> CGImage? {
        nil
    }

    func registerBaseLook(_: BaseLookDefinition) {}
    func canRender(_: BaseLookReference) -> Bool {
        true
    }

    /// What `focusStack` merges every stack into; nil fails the merge.
    var focusStackPreview: FocusStackPreview?

    func focusStack(
        at _: URL, maxLongEdge _: Int, progress _: @escaping @Sendable (Double) -> Void,
    ) async throws -> FocusStackPreview {
        guard let focusStackPreview else { throw CancellationError() }
        return focusStackPreview
    }
}

@MainActor
struct MaskEditingTests {
    /// An editor with a photo open, in a temporary folder its sidecar can be written to.
    private func openEditor() async throws -> (EditorModel, () -> Void) {
        let folder = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let model = EditorModel(engine: StubEngine())
        model.select(folder.appending(path: "IMG_0001.ARW"))
        for _ in 0 ..< 200 where model.info == nil {
            try await Task.sleep(for: .milliseconds(5))
        }
        #expect(model.info != nil)
        return (model, { try? FileManager.default.removeItem(at: folder) })
    }

    @Test func `strokes paint into one brush component`() async throws {
        let (model, cleanup) = try await openEditor()
        defer { cleanup() }
        model.startDrawing(.brush)
        model.beginStroke(at: ImagePoint(x: 0.2, y: 0.2))
        model.continueStroke(to: ImagePoint(x: 0.4, y: 0.25))
        model.continueStroke(to: ImagePoint(x: 0.4001, y: 0.25)) // too close: skipped
        model.endStroke()
        model.beginStroke(at: ImagePoint(x: 0.6, y: 0.6))
        model.endStroke()

        #expect(model.recipe.masks.count == 1)
        let components = model.recipe.masks[0].components
        #expect(components.count == 1)
        guard case let .brush(brush) = components[0].shape else {
            Issue.record("expected a brush")
            return
        }
        #expect(brush.strokes.count == 2)
        #expect(brush.strokes[0].points.count == 2)
        #expect(brush.strokes[0].size == model.brushes.a.radius)
        #expect(model.history.map(\.name).suffix(2) == ["New Brush", "Brush Stroke"])
        #expect(model.isBrushing)
    }

    @Test func `erasing needs a brush and uses the erase settings`() async throws {
        let (model, cleanup) = try await openEditor()
        defer { cleanup() }
        model.startDrawing(.brush)
        model.beginStroke(at: ImagePoint(x: 0.5, y: 0.5), erasing: true)
        model.endStroke()
        #expect(model.recipe.masks.isEmpty)

        model.beginStroke(at: ImagePoint(x: 0.5, y: 0.5))
        model.endStroke()
        model.brushes.erase.flow = 40
        model.beginStroke(at: ImagePoint(x: 0.5, y: 0.5), erasing: true)
        model.endStroke()
        guard case let .brush(brush) = model.recipe.masks.first?.components.first?.shape else {
            Issue.record("expected a brush")
            return
        }
        #expect(brush.strokes.map(\.erase) == [false, true])
        #expect(brush.strokes[1].flow == 40)
    }

    @Test func `brush keys size the brush while brushing`() async throws {
        let (model, cleanup) = try await openEditor()
        defer { cleanup() }
        model.brushes.a.size = 20
        model.startDrawing(.brush)
        model.nudgeBrush(direction: 1, feather: false)
        #expect(model.brushes.a.size > 20)
        model.setSliderValue(.maskBrushFlow, 30)
        #expect(model.brushes.a.flow == 30)
        #expect(model.sliderValue(.maskBrushFlow) == 30)
    }

    @Test func `color samples replace or add`() async throws {
        let (model, cleanup) = try await openEditor()
        defer { cleanup() }
        model.startDrawing(.colorRange)
        model.sampleColorRange(at: ImagePoint(x: 0.1, y: 0.1), adding: false)
        model.sampleColorRange(at: ImagePoint(x: 0.2, y: 0.2), adding: true)
        model.sampleColorRange(at: ImagePoint(x: 0.3, y: 0.3), radius: 0.05, adding: true)
        #expect(model.selectedColorRange?.samples.count == 3)
        model.sampleColorRange(at: ImagePoint(x: 0.9, y: 0.9), adding: false)
        #expect(model.selectedColorRange?.samples == [ColorSample(center: ImagePoint(x: 0.9, y: 0.9))])
        model.setSliderValue(.maskColorRefine, 80)
        #expect(model.selectedColorRange?.refine == 80)
        #expect(model.recipe.masks.count == 1)
    }

    @Test func `luminance eyedropper centres a range on the sampled tone`() async throws {
        let (model, cleanup) = try await openEditor()
        defer { cleanup() }
        model.startDrawing(.luminanceRange, operation: .intersect)
        await model.sampleLuminanceRange(at: ImagePoint(x: 0.5, y: 0.5))
        let range = try #require(model.selectedLuminanceRange)
        #expect(abs(range.lower - 52) < 1e-6)
        #expect(abs(range.upper - 72) < 1e-6)

        var edited = range
        edited.upper = 90
        model.beginEdit()
        model.setLuminanceRange(edited)
        model.endEdit(name: "Luminance Range")
        #expect(model.selectedLuminanceRange?.upper == 90)
    }

    /// A Landscape mask asks the engine for its class and is named for it.
    @Test func `a Landscape mask is named for its class`() async throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let engine = StubEngine()
        engine.availableKinds.insert(.landscape)
        engine.computed = [AIMask(
            kind: .landscape, provider: "stub", revision: 1, part: LandscapeClass.water.rawValue, analysisHash: "h",
            center: ImagePoint(x: 0.5, y: 0.5), bitmap: MaskBitmap(sha256: "w", width: 4, height: 4),
        )]
        let model = EditorModel(engine: engine)
        model.select(folder.appending(path: "IMG_0003.ARW"))
        for _ in 0 ..< 200 where model.info == nil || model.availableAIMaskKinds.isEmpty {
            try await Task.sleep(for: .milliseconds(5))
        }
        #expect(model.canCreateMask(.landscape))
        await model.createAIMask(.landscape, landscape: .water)
        #expect(engine.lastRequest?.landscape == .water)
        #expect(model.recipe.masks.first?.name == "Water")

        // A class the engine finds none of says which class, rather than nothing happening.
        engine.computed = []
        await model.createAIMask(.landscape, landscape: .mountains)
        #expect(model.maskMessage == "No mountains were found in this photo.")
        #expect(model.recipe.masks.count == 1)
    }

    /// The People menus offer only the parts the engine can make, in Lightroom's order.
    @Test func `people menus offer the parts there are`() async throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let engine = StubEngine()
        engine.personParts = [.hair, .clothes, .entirePerson, .lips]
        let model = EditorModel(engine: engine)
        model.select(folder.appending(path: "IMG_0004.ARW"))
        for _ in 0 ..< 200 where model.info == nil || model.availableAIMaskKinds.isEmpty {
            try await Task.sleep(for: .milliseconds(5))
        }
        #expect(model.availablePersonParts == [.entirePerson, .lips, .hair, .clothes])
    }

    /// Dragging a mask's adjustment hides its overlay, so the edit shows; it comes back on release.
    /// Sliders that shape the mask keep it.
    @Test func `the overlay hides while a mask's adjustment is dragged`() async throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let model = EditorModel(engine: StubEngine())
        model.select(folder.appending(path: "IMG_0005.ARW"))
        for _ in 0 ..< 200 where model.info == nil {
            try await Task.sleep(for: .milliseconds(5))
        }
        model.startDrawing(.radial)
        model.beginDrawing(.radial(RadialMask(center: ImagePoint(x: 0.5, y: 0.5), radiusX: 0.2, radiusY: 0.2)))
        model.finishDrawing()
        let mask = try #require(model.selectedMaskID)
        #expect(model.maskOverlayShown == mask)

        model.beginEdit(.localExposure)
        model.setValue(.localExposure, 1)
        #expect(model.maskOverlayShown == nil)
        model.endEdit()
        #expect(model.maskOverlayShown == mask)

        model.beginEdit(.maskAmount)
        #expect(model.maskOverlayShown == nil)
        model.endEdit()
        model.beginEdit(.maskFeather)
        #expect(model.maskOverlayShown == mask, "feather shapes the mask: the overlay shows it")
        model.endEdit()
    }

    /// The new panel's thumbnails (UX-23): each mask's black and white overlay, small, a hidden
    /// mask's as if shown; drawn again only when the mask's coverage may have changed.
    @Test func `a mask's thumbnail is drawn once, and again only when its coverage may change`() async throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let engine = StubEngine()
        let model = EditorModel(engine: engine)
        model.select(folder.appending(path: "IMG_0007.ARW"))
        for _ in 0 ..< 200 where model.info == nil {
            try await Task.sleep(for: .milliseconds(5))
        }
        func drawRadial() {
            model.startDrawing(.radial)
            model.beginDrawing(.radial(RadialMask(center: ImagePoint(x: 0.5, y: 0.5), radiusX: 0.2, radiusY: 0.2)))
            model.finishDrawing()
        }
        drawRadial()
        drawRadial()
        let hidden = model.masks[0].id
        model.toggleMaskVisibility(hidden)
        engine.stills.removeAll()
        await model.refreshMaskThumbnails()
        #expect(model.maskThumbnails.count == 2)
        #expect(engine.stills.count == 2)
        #expect(engine.stills.allSatisfy {
            $0.maskOverlayStyle == .blackAndWhite && $0.maxLongEdge == EditorModel.maskThumbnailLongEdge
        })
        let drawnHidden = engine.stills.first { $0.maskOverlay == hidden }
        #expect(drawnHidden?.recipe.masks.first { $0.id == hidden }?.isVisible == true)

        model.selectMask(model.masks[1].id)
        model.setValue(.localExposure, 1)
        engine.stills.removeAll()
        await model.refreshMaskThumbnails()
        #expect(engine.stills.isEmpty, "a mask's own adjustment changes no coverage")

        drawRadial()
        await model.refreshMaskThumbnails()
        #expect(engine.stills.count == 1, "only the new mask is drawn")
        #expect(model.maskThumbnails.count == 3)
    }

    /// Option-click on a mask's eye (UX-24): that mask alone as one history step, and every mask
    /// again from there.
    @Test func `Option-click on an eye shows a mask alone, and every mask again`() async throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let model = EditorModel(engine: StubEngine())
        model.select(folder.appending(path: "IMG_0008.ARW"))
        for _ in 0 ..< 200 where model.info == nil {
            try await Task.sleep(for: .milliseconds(5))
        }
        for _ in 0 ..< 3 {
            model.startDrawing(.radial)
            model.beginDrawing(.radial(RadialMask(center: ImagePoint(x: 0.5, y: 0.5), radiusX: 0.2, radiusY: 0.2)))
            model.finishDrawing()
        }
        let middle = model.masks[1].id
        model.showMaskAlone(middle)
        #expect(model.masks.map(\.isVisible) == [false, true, false])
        model.showMaskAlone(middle)
        #expect(!model.masks.contains { !$0.isVisible }, "every mask shown again")
        model.undo()
        #expect(model.masks.map(\.isVisible) == [false, true, false], "one step back: alone again")
    }

    /// Invert for the whole mask (UX-24): one history step; and Duplicate and Invert inverts the
    /// copy as a whole, its components as they were.
    @Test func `Invert inverts the whole mask, and Duplicate and Invert inverts the copy`() async throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let model = EditorModel(engine: StubEngine())
        model.select(folder.appending(path: "IMG_0009.ARW"))
        for _ in 0 ..< 200 where model.info == nil {
            try await Task.sleep(for: .milliseconds(5))
        }
        model.startDrawing(.radial)
        model.beginDrawing(.radial(RadialMask(center: ImagePoint(x: 0.5, y: 0.5), radiusX: 0.2, radiusY: 0.2)))
        model.finishDrawing()
        let mask = try #require(model.selectedMaskID)
        model.setMaskInverted(mask, true)
        #expect(model.recipe.mask(mask)?.inverted == true)
        #expect(model.maskOutlines.first { $0.id == mask }?.inverted == true)
        model.undo()
        #expect(model.recipe.mask(mask)?.inverted == false, "one step")

        model.duplicateMask(mask, inverted: true)
        let copy = try #require(model.masks.last)
        #expect(copy.id != mask && copy.inverted)
        #expect(copy.components.map(\.inverted) == [false], "the components as they were")
    }

    /// The new panel's list previews the mask under the pointer (UX-23), with the overlay on or
    /// off, and only in the Masking tool.
    @Test func `the overlay shows the mask under the pointer, overlay on or off`() async throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let model = EditorModel(engine: StubEngine())
        model.select(folder.appending(path: "IMG_0006.ARW"))
        for _ in 0 ..< 200 where model.info == nil {
            try await Task.sleep(for: .milliseconds(5))
        }
        for _ in 0 ..< 2 {
            model.startDrawing(.radial)
            model.beginDrawing(.radial(RadialMask(center: ImagePoint(x: 0.5, y: 0.5), radiusX: 0.2, radiusY: 0.2)))
            model.finishDrawing()
        }
        let selected = try #require(model.selectedMaskID)
        let other = try #require(model.masks.map(\.id).first { $0 != selected })
        model.hoveredMaskID = other
        #expect(model.maskOverlayShown == other)
        model.showMaskOverlay = false
        #expect(model.maskOverlayShown == other)
        model.hoveredMaskID = nil
        #expect(model.maskOverlayShown == nil)
        model.showMaskOverlay = true
        #expect(model.maskOverlayShown == selected)
        model.hoveredMaskID = other
        model.activeTool = .edit
        #expect(model.maskOverlayShown == nil)
    }

    @Test func `AI masks become components and update in place`() async throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let engine = StubEngine()
        func person(_ index: Int, sha: String) -> AIMask {
            AIMask(
                kind: .people, provider: "stub", revision: 1, instance: index, analysisHash: "h",
                center: ImagePoint(x: 0.5, y: 0.5), bitmap: MaskBitmap(sha256: sha, width: 4, height: 4),
            )
        }
        engine.computed = [person(0, sha: "a"), person(1, sha: "b")]
        let model = EditorModel(engine: engine)
        model.select(folder.appending(path: "IMG_0002.ARW"))
        for _ in 0 ..< 200 where model.info == nil || model.availableAIMaskKinds.isEmpty {
            try await Task.sleep(for: .milliseconds(5))
        }
        #expect(model.canCreateMask(.people))
        #expect(!model.canCreateMask(.landscape))

        await model.createAIMask(.people)
        #expect(model.recipe.masks.count == 1)
        #expect(model.recipe.masks[0].components.count == 2)
        #expect(model.recipe.masks[0].name == "People")
        #expect(model.aiMaskCount == 2)

        engine.computed = [person(1, sha: "b2"), person(0, sha: "a2")]
        let ids = model.recipe.masks[0].components.map(\.id)
        await model.updateAIMasks()
        let updated = model.recipe.masks[0].components
        #expect(updated.map(\.id) == ids)
        let hashes = updated.compactMap { component -> String? in
            if case let .ai(mask) = component.shape {
                mask.bitmap.sha256
            } else {
                nil
            }
        }
        #expect(hashes == ["a2", "b2"])
        #expect(model.history.last?.name == "Update AI Masks")
    }

    /// Each Refine Edge stroke is solved by the engine, kept with the mask and a step of its own;
    /// Update AI Masks applies the strokes to the new mask.
    @Test func `the refine edge brush refines an AI mask stroke by stroke`() async throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let engine = StubEngine()
        engine.computed = [AIMask(
            kind: .subject, provider: "stub", revision: 1, analysisHash: "h",
            center: ImagePoint(x: 0.5, y: 0.5), bitmap: MaskBitmap(sha256: "s", width: 4, height: 4),
        )]
        let model = EditorModel(engine: engine)
        model.select(folder.appending(path: "IMG_0004.ARW"))
        for _ in 0 ..< 200 where model.info == nil {
            try await Task.sleep(for: .milliseconds(5))
        }
        await model.createAIMask(.subject)
        let mask = try #require(model.recipe.masks.first)
        let component = try #require(mask.components.first)
        model.startRefiningEdges(component.id, in: mask.id)
        #expect(model.isRefiningEdges)

        model.beginStroke(at: ImagePoint(x: 0.2, y: 0.2))
        model.continueStroke(to: ImagePoint(x: 0.4, y: 0.2))
        await model.endEdgeStroke()
        #expect(model.edgeBrushStrokes.isEmpty)
        guard case let .ai(refined) = model.recipe.masks[0].components[0].shape else {
            Issue.record("not an AI mask")
            return
        }
        #expect(refined.bitmap.sha256 == "s-brushed1")
        #expect(refined.refinements?.first?.points.count == 2)
        #expect(refined.refinements?.first?.size == model.edgeBrushRadius)
        #expect(model.history.last?.name == "Refine Edge Brush")

        engine.computed[0].bitmap = MaskBitmap(sha256: "s2", width: 4, height: 4)
        await model.updateAIMasks()
        guard case let .ai(updated) = model.recipe.masks[0].components[0].shape else { return }
        #expect(updated.bitmap.sha256 == "s2-brushed1")
        #expect(updated.refinements?.count == 1)

        model.cancelDrawing()
        #expect(!model.isRefiningEdges)
    }

    /// A Landscape class, and a People part only SAM 3 makes, ask before downloading it as
    /// Objects do, and the mask follows the download.
    @Test func `landscape classes and SAM 3's people parts ask before downloading it`() async throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let engine = StubEngine()
        engine.availableKinds.insert(.landscape)
        engine.neededModel = ModelInfo(
            id: "sam3", name: "SAM 3", purpose: "Landscape", downloadBytes: 988_000_000, state: .notDownloaded,
        )
        engine.kindsNeedingModel = [.landscape]
        engine.partsNeedingModel = [.clothes]
        engine.computed = [AIMask(
            kind: .landscape, provider: "stub", revision: 1, part: LandscapeClass.water.rawValue, analysisHash: "h",
            center: ImagePoint(x: 0.5, y: 0.5), bitmap: MaskBitmap(sha256: "w", width: 4, height: 4),
        )]
        let model = EditorModel(engine: engine)
        model.select(folder.appending(path: "IMG_0003.ARW"))
        for _ in 0 ..< 200 where model.info == nil {
            try await Task.sleep(for: .milliseconds(5))
        }
        await model.startAIMask(.people, part: .clothes)
        #expect(model.pendingModel?.model.id == "sam3")
        #expect(model.pendingModel?.part == .clothes)
        model.declinePendingModel()

        await model.startAIMask(.landscape, landscape: .water)
        #expect(model.pendingModel?.landscape == .water)
        #expect(model.recipe.masks.isEmpty)
        await model.downloadPendingModel()
        #expect(engine.downloaded == ["sam3"])
        #expect(engine.lastRequest?.landscape == .water)
        #expect(model.recipe.masks.first?.name == "Water")
    }

    /// A photo holds up to 16 masks; a 17th says why it isn't made, rather than nothing happening.
    @Test func `a seventeenth mask says why it isn't made`() async throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let engine = StubEngine()
        engine.computed = [AIMask(
            kind: .subject, provider: "stub", revision: 1, analysisHash: "h", center: ImagePoint(x: 0.5, y: 0.5),
            bitmap: MaskBitmap(sha256: "s", width: 4, height: 4),
        )]
        let model = EditorModel(engine: engine)
        model.select(folder.appending(path: "IMG_0003.ARW"))
        for _ in 0 ..< 200 where model.info == nil {
            try await Task.sleep(for: .milliseconds(5))
        }
        await model.createAIMask(.subject)
        let first = try #require(model.recipe.masks.first?.id)
        for _ in 1 ..< MaskLayer.maximumLayers {
            model.duplicateMask(first)
        }
        #expect(model.recipe.masks.count == MaskLayer.maximumLayers)
        #expect(model.maskMessage == nil)
        model.duplicateMask(first)
        #expect(model.recipe.masks.count == MaskLayer.maximumLayers)
        #expect(model.maskMessage == "A photo can have up to 16 masks: delete one to make another.")
    }

    @Test func `objects ask before downloading their model, then refine with clicks`() async throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let engine = StubEngine()
        engine.neededModel = ModelInfo(
            id: "sam2.1-tiny", name: "Segment Anything 2.1 (tiny)", purpose: "Objects", downloadBytes: 79_644_968,
            state: .notDownloaded,
        )
        engine.computed = [AIMask(
            kind: .objects, provider: "stub", revision: 1, prompts: [ImagePoint(x: 0.5, y: 0.5)], analysisHash: "h",
            center: ImagePoint(x: 0.5, y: 0.5), bitmap: MaskBitmap(sha256: "o", width: 4, height: 4),
        )]
        let model = EditorModel(engine: engine)
        model.select(folder.appending(path: "IMG_0003.ARW"))
        for _ in 0 ..< 200 where model.info == nil {
            try await Task.sleep(for: .milliseconds(5))
        }
        await model.startAIMask(.objects)
        #expect(model.pendingModel?.model.id == "sam2.1-tiny")
        #expect(model.drawingKind == nil)
        #expect(engine.downloaded.isEmpty)

        await model.downloadPendingModel()
        #expect(engine.downloaded == ["sam2.1-tiny"])
        #expect(model.drawingKind == .objects)

        await model.selectObject(at: ImagePoint(x: 0.5, y: 0.5))
        #expect(model.recipe.masks.count == 1)
        await model.selectObject(at: ImagePoint(x: 0.6, y: 0.5))
        #expect(model.recipe.masks.count == 1)
        #expect(model.recipe.masks[0].components.count == 1)
        #expect(model.history.map(\.name).suffix(2) == ["New Objects", "Add to Object"])
    }

    @Test func `adaptive presets compute their masks and carry their adjustments`() async throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let engine = StubEngine()
        engine.computed = [AIMask(
            kind: .sky, provider: "stub", revision: 1, analysisHash: "h", center: ImagePoint(x: 0.5, y: 0.2),
            bitmap: MaskBitmap(sha256: "s", width: 4, height: 4),
        )]
        let model = EditorModel(engine: engine)
        model.select(folder.appending(path: "IMG_0004.ARW"))
        for _ in 0 ..< 200 where model.info == nil {
            try await Task.sleep(for: .milliseconds(5))
        }
        let blueSky = try #require(MaskPreset.builtIn.first { $0.name == "Blue Sky" })
        #expect(model.canApply(blueSky))
        await model.applyMaskPreset(blueSky)
        let mask = try #require(model.recipe.masks.first)
        #expect(mask.name == "Blue Sky")
        #expect(mask[.localTemperature] == -12)
        guard case let .ai(sky) = mask.components.first?.shape else {
            Issue.record("expected an AI component")
            return
        }
        #expect(sky.kind == .sky)

        // Saved as a preset, the sky becomes a request again.
        let preset = MaskPreset(mask, name: "My Sky")
        #expect(preset.aiKinds == [.sky])
        #expect(preset.localAdjustments[.localExposure] == -0.3)
        let decoded = try JSONDecoder().decode(MaskPreset.self, from: JSONEncoder().encode(preset))
        #expect(decoded == preset)
    }

    @Test func `Landscape presets ask for their class, and a saved Landscape mask keeps it`() async throws {
        let engine = StubEngine()
        engine.computed = [AIMask(
            kind: .landscape, provider: "stub", revision: 1, part: LandscapeClass.snow.rawValue, analysisHash: "h",
            center: ImagePoint(x: 0.5, y: 0.8), bitmap: MaskBitmap(sha256: "s", width: 4, height: 4),
        )]
        let folder = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let model = EditorModel(engine: engine)
        model.select(folder.appending(path: "IMG_0004.ARW"))
        for _ in 0 ..< 200 where model.info == nil {
            try await Task.sleep(for: .milliseconds(5))
        }
        let snow = try #require(MaskPreset.builtIn.first { $0.name == "Brighten Snow" })
        await model.applyMaskPreset(snow)
        #expect(engine.lastRequest?.kind == .landscape && engine.lastRequest?.landscape == .snow)
        let mask = try #require(model.recipe.masks.first)
        #expect(mask.name == "Brighten Snow" && mask[.localWhites] == 15)

        let saved = MaskPreset(mask, name: "My Snow")
        #expect(saved.landscapeClasses == [.snow] && saved.landscapeClass(at: 0) == .snow)
        let decoded = try JSONDecoder().decode(MaskPreset.self, from: JSONEncoder().encode(saved))
        #expect(decoded == saved)
        // A preset saved before Landscape presets kept their class reads as Vegetation.
        var old = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(saved)) as? [String: Any])
        old["landscapeClasses"] = nil
        let earlier = try JSONDecoder().decode(MaskPreset.self, from: JSONSerialization.data(withJSONObject: old))
        #expect(earlier.landscapeClasses == nil && earlier.landscapeClass(at: 0) == .vegetation)
    }

    @Test func `ranges add to an existing mask with the chosen operation`() async throws {
        let (model, cleanup) = try await openEditor()
        defer { cleanup() }
        model.startDrawing(.brush)
        model.beginStroke(at: ImagePoint(x: 0.5, y: 0.5))
        model.endStroke()
        let mask = try #require(model.selectedMaskID)
        model.startDrawing(.colorRange, operation: .intersect, addingTo: mask)
        model.sampleColorRange(at: ImagePoint(x: 0.5, y: 0.5), adding: false)
        let components = model.recipe.masks[0].components
        #expect(components.count == 2)
        #expect(components[1].operation == .intersect)
    }
}
