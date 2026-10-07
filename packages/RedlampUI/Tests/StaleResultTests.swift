import CoreGraphics
import Foundation
import IOSurface
import RedlampDocument
import RedlampEngineAPI
import RedlampRecipes
import Synchronization
import Testing
@testable import RedlampUI

/// Holds the engine's answers until a test lets them through.
final class Gate: Sendable {
    private struct State {
        var held = false
        var arrived = 0
        var waiting: [CheckedContinuation<Void, Never>] = []
    }

    private let state = Mutex(State())

    /// Calls from now on wait for `release`.
    func hold() {
        state.withLock {
            $0.held = true
            $0.arrived = 0
        }
    }

    func release() {
        let waiting = state.withLock { state in
            state.held = false
            defer { state.waiting = [] }
            return state.waiting
        }
        waiting.forEach { $0.resume() }
    }

    /// Calls that reached the gate since `hold`.
    var arrived: Int {
        state.withLock { $0.arrived }
    }

    func pass() async {
        await withCheckedContinuation { continuation in
            let open = state.withLock { state in
                state.arrived += 1
                guard state.held else { return true }
                state.waiting.append(continuation)
                return false
            }
            if open {
                continuation.resume()
            }
        }
    }
}

/// `StubEngine`, with every analysis of the open photo held at a gate.
final class GatedEngine: EditingEngine, @unchecked Sendable {
    let base = StubEngine()
    let gate = Gate()
    var autoToneValues: [ParameterID: Double] = [.exposure: 0.7]
    var autoWhiteBalanceValue = WhiteBalanceValue(temperature: 4300, tint: 9)
    var sampledWhiteBalance = WhiteBalanceValue(temperature: 6100, tint: -7)

    func autoWhiteBalance() async -> WhiteBalanceValue? {
        await gate.pass()
        return autoWhiteBalanceValue
    }

    func whiteBalance(sampledAt _: CGPoint) async -> WhiteBalanceValue? {
        await gate.pass()
        return sampledWhiteBalance
    }

    func autoTone(for _: EditRecipe) async -> [ParameterID: Double] {
        await gate.pass()
        return autoToneValues
    }

    func maskColor(sampledAt point: CGPoint, recipe: EditRecipe) async -> SIMD3<Double>? {
        await gate.pass()
        return await base.maskColor(sampledAt: point, recipe: recipe)
    }

    func computeMasks(_ request: MaskRequest) async throws -> [AIMask] {
        await gate.pass()
        return try await base.computeMasks(request)
    }

    func previewObjectMask(_: MaskRequest) async throws -> MaskBitmap? {
        await gate.pass()
        return MaskBitmap(sha256: "preview", width: 4, height: 4)
    }

    func refineMaskEdges(_ mask: AIMask) async throws -> MaskBitmap {
        await gate.pass()
        return try await base.refineMaskEdges(mask)
    }

    /// Refine Edge brush solves still to fail, the next ones first.
    var failingEdgeSolves = 0

    func refineMaskEdges(_ bitmap: MaskBitmap, along strokes: [BrushStroke]) async throws -> MaskBitmap {
        await gate.pass()
        if failingEdgeSolves > 0 {
            failingEdgeSolves -= 1
            throw MaskComputationError.nothingFound(.subject)
        }
        return try await base.refineMaskEdges(bitmap, along: strokes)
    }

    func detectLines() async -> [DetectedLine] {
        await gate.pass()
        return await base.detectLines()
    }

    func retouchSource(for spot: RetouchSpot, recipe: EditRecipe) async -> ImagePoint? {
        await gate.pass()
        return await base.retouchSource(for: spot, recipe: recipe)
    }

    func detectDust(recipe: EditRecipe, sensitivity: Double) async -> [DetectedSpot] {
        await gate.pass()
        return await base.detectDust(recipe: recipe, sensitivity: sensitivity)
    }

    func detectDust(
        in photos: [(url: URL, recipe: EditRecipe)], sensitivity: Double, progress: @escaping @Sendable (Int) -> Void,
    ) async -> [URL: [DetectedSpot]] {
        await gate.pass()
        return await base.detectDust(in: photos, sensitivity: sensitivity, progress: progress)
    }

    func thingsToFind() async -> [String] {
        await base.thingsToFind()
    }

    func modelNeededToFind() async -> ModelInfo? {
        await base.modelNeededToFind()
    }

    func findThings(_ things: Set<String>, threshold: Double) async throws -> [FoundThing] {
        await gate.pass()
        return try await base.findThings(things, threshold: threshold)
    }

    func open(_ url: URL) async throws -> ImageInfo {
        try await base.open(url)
    }

    func openIfReady(_ url: URL) -> ImageInfo? {
        base.openIfReady(url)
    }

    func prefetch(_ urls: [URL]) {
        base.prefetch(urls)
    }

    /// Sends a frame for each render from then on, as the engine does.
    var sendsFrames = false
    private let rendered = AsyncStream.makeStream(of: RenderedFrame.self)

    func render(_ request: RenderRequest) {
        base.render(request)
        let properties: [CFString: Any] = [
            kIOSurfaceWidth: request.targetSize.width, kIOSurfaceHeight: request.targetSize.height,
            kIOSurfaceBytesPerElement: 8, kIOSurfacePixelFormat: 0x5247_6841,
        ]
        guard sendsFrames, let surface = IOSurfaceCreate(properties as CFDictionary) else { return }
        rendered.continuation.yield(RenderedFrame(
            surface: surface, size: request.targetSize, histogram: .empty,
            generation: request.generation, renderDuration: .zero,
        ))
    }

    func frames() -> AsyncStream<RenderedFrame> {
        rendered.stream
    }

    func renderStill(_ request: StillRequest) async throws -> CGImage {
        try await base.renderStill(request)
    }

    func availableMaskKinds() -> Set<MaskKind> {
        base.availableMaskKinds()
    }

    func availablePersonParts() -> Set<PersonPart> {
        base.availablePersonParts()
    }

    func modelNeeded(for kind: MaskKind) async -> ModelInfo? {
        await base.modelNeeded(for: kind)
    }

    func models() async -> [ModelInfo] {
        await base.models()
    }

    func downloadModel(_ id: String, progress: @escaping @Sendable (Double) -> Void) async throws {
        await gate.pass()
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

/// Each analysis that applies its result to the open photo.
enum Analysis: String, CaseIterable, Sendable {
    case autoTone
    case autoWhiteBalance
    case whiteBalanceSelector
    case recipeWithAutoWhiteBalance
    case recipePreview
    case whiteBalancePreview
    case upright
    case luminanceRange
    case objectHover
    case objectSelection
    case objectRefinement
    case aiMask
    case updateAIMasks
    case maskPreset
    case refineEdges
    case edgeBrush
    case pickObject
    case spot
    case brushedSpot
    case removeDust
    case find
    case removeFound
    case removeAllFound
    case spotMode
    case newSource

    private static func mask(_ kind: MaskKind, _ sha: String) -> AIMask {
        AIMask(
            kind: kind, provider: "stub", revision: 1, prompts: kind == .objects ? [ImagePoint(x: 0.5, y: 0.5)] : [],
            analysisHash: "h", center: ImagePoint(x: 0.5, y: 0.5), bitmap: MaskBitmap(sha256: sha, width: 4, height: 4),
        )
    }

    private static let autoWhiteBalanceRecipe = {
        var settings = RecipeSettings()
        settings.whiteBalanceMode = .auto
        return Recipe(
            id: "stale.auto-wb",
            name: "Auto WB",
            group: "Tests",
            includes: [.whiteBalance],
            settings: settings,
        )
    }()

    private static let car = FoundThing(
        thing: "car",
        score: 0.6,
        box: ImageRect(x: 0.1, y: 0.5, width: 0.3, height: 0.2),
    )

    /// What the engine answers, and the open photo's state before the analysis starts.
    @MainActor func prepare(_ model: EditorModel, _ engine: GatedEngine) async {
        let stub = engine.base
        stub.computed = [Self.mask(.subject, "s")]
        stub.retouchSource = ImagePoint(x: 0.2, y: 0.6)
        switch self {
        case .upright:
            stub.detectedLines = [0.2, 0.4, 0.6, 0.8].map { x in
                let lean = (x - 0.5) * 0.06
                return DetectedLine(
                    line: GuideLine(start: ImagePoint(x: x - lean, y: 0.1), end: ImagePoint(x: x + lean, y: 0.9)),
                    strength: 200,
                )
            }
        case .objectSelection, .objectRefinement, .objectHover:
            stub.computed = [Self.mask(.objects, "o")]
            if self == .objectRefinement {
                model.armObjectSelection()
                await model.selectObject(at: ImagePoint(x: 0.5, y: 0.5))
            }
        case .maskPreset:
            stub.computed = [Self.mask(.sky, "sky")]
        case .updateAIMasks, .refineEdges, .edgeBrush:
            await model.createAIMask(.subject)
            stub.computed = [Self.mask(.subject, "s2")]
            if self == .edgeBrush, let mask = model.recipe.masks.first, let component = mask.components.first {
                model.startRefiningEdges(component.id, in: mask.id)
                model.beginStroke(at: ImagePoint(x: 0.2, y: 0.2))
                model.continueStroke(to: ImagePoint(x: 0.4, y: 0.2))
            }
        case .removeDust:
            stub.dust = [DetectedSpot(center: ImagePoint(x: 0.2, y: 0.2), radius: 0.01, strength: 30)]
        case .find, .removeFound, .removeAllFound:
            stub.things = ["car"]
            stub.found = [Self.car]
            stub.computed = [Self.mask(.objects, "car")]
            if self != .find {
                model.activeTool = .heal
                await model.findThings()
            }
        case .spotMode:
            model.activeTool = .heal
            await model.setSpotMode(.remove)
            await model.addSpot(at: ImagePoint(x: 0.5, y: 0.5))
        case .newSource:
            model.activeTool = .heal
            await model.addSpot(at: ImagePoint(x: 0.5, y: 0.5))
            stub.retouchSource = ImagePoint(x: 0.7, y: 0.3)
        default:
            break
        }
        rearm(model)
    }

    /// The tool the analysis needs, armed again on whichever photo is open, so only the photo
    /// check can stop a stale result.
    @MainActor func rearm(_ model: EditorModel) {
        switch self {
        case .luminanceRange:
            model.startDrawing(.luminanceRange)
        case .objectHover, .objectSelection, .objectRefinement:
            if model.drawingKind != .objects {
                model.armObjectSelection()
            }
        case .pickObject:
            model.activeTool = .heal
            model.spotPick = .object
        case .spot, .brushedSpot, .removeDust, .find, .removeFound, .removeAllFound, .spotMode, .newSource:
            model.activeTool = .heal
        default:
            break
        }
    }

    /// Starts the analysis on the open photo.
    @MainActor func start(_ model: EditorModel) -> Task<Void, Never> {
        let point = ImagePoint(x: 0.6, y: 0.5)
        switch self {
        case .autoTone:
            model.autoTone()
        case .autoWhiteBalance:
            model.setWhiteBalanceMode(.auto)
        case .whiteBalanceSelector:
            model.sampleWhiteBalance(at: CGPoint(x: 0.5, y: 0.5))
        case .recipeWithAutoWhiteBalance:
            model.applyRecipe(Self.autoWhiteBalanceRecipe)
        case .recipePreview:
            model.previewRecipe(Self.autoWhiteBalanceRecipe)
        case .whiteBalancePreview:
            return Task { _ = await model.edit(withWhiteBalance: .auto) }
        case .upright:
            model.applyUpright(.vertical)
        case .luminanceRange:
            return Task { await model.sampleLuminanceRange(at: point) }
        case .objectHover:
            model.hoverObject(at: point)
        case .objectSelection, .objectRefinement:
            return Task { await model.selectObject(at: point) }
        case .aiMask:
            return Task { await model.createAIMask(.subject) }
        case .updateAIMasks:
            return Task { await model.updateAIMasks() }
        case .maskPreset:
            let preset = MaskPreset.builtIn.first { $0.name == "Blue Sky" }
            return Task {
                if let preset {
                    await model.applyMaskPreset(preset)
                }
            }
        case .refineEdges:
            let mask = model.recipe.masks.first
            return Task {
                if let mask, let component = mask.components.first {
                    await model.refineEdges(component.id, in: mask.id)
                }
            }
        case .edgeBrush:
            return Task { await model.endEdgeStroke() }
        case .pickObject:
            return Task { await model.pickRegion(at: point) }
        case .spot:
            return Task { await model.addSpot(at: point) }
        case .brushedSpot:
            return Task { await model.addStroke((0 ... 40).map { ImagePoint(x: 0.3 + Double($0) * 0.005, y: 0.4) }) }
        case .removeDust:
            return Task { await model.removeDust() }
        case .find:
            return Task { await model.findThings() }
        case .removeFound:
            let found = model.foundThings.first
            return Task {
                if let found {
                    await model.removeFound(found)
                }
            }
        case .removeAllFound:
            return Task { await model.removeAllFound() }
        case .spotMode:
            return Task { await model.setSpotMode(.heal) }
        case .newSource:
            return Task { await model.findNewSource() }
        }
        return Task {}
    }
}

/// What an analysis can change on the open photo.
struct EditorState: Equatable {
    var recipe: EditRecipe
    var steps: Int
    var autoWhiteBalance: WhiteBalanceValue?
    var objectPreview: MaskBitmap?
    var foundThings: [FoundThing]

    @MainActor init(_ model: EditorModel) {
        recipe = model.recipe
        steps = model.history.count
        autoWhiteBalance = model.autoWhiteBalance
        objectPreview = model.objectPreview
        foundThings = model.foundThings
    }
}

/// An analysis applies its result only to the photo it was computed for: the engine analyses
/// whichever photo is open when the request reaches it (CONC-03).
@MainActor
struct StaleResultTests {
    private let folder = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    private let engine = GatedEngine()
    private let model: EditorModel
    private var a: URL {
        folder.appending(path: "A.ARW")
    }

    private var b: URL {
        folder.appending(path: "B.ARW")
    }

    init() throws {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        model = EditorModel(engine: engine)
    }

    private func open(_ url: URL, for analysis: Analysis) async throws {
        model.select(url)
        try await eventually { model.info?.url == url }
        try #require(model.info?.url == url)
        analysis.rearm(model)
    }

    /// Opens A, starts `analysis` on it, and waits until the engine is working on it.
    private func startOnA(_ analysis: Analysis) async throws -> Task<Void, Never> {
        try await open(a, for: analysis)
        await analysis.prepare(model, engine)
        engine.gate.hold()
        let run = analysis.start(model)
        try await eventually { engine.gate.arrived > 0 }
        try #require(engine.gate.arrived > 0, "the analysis reached the engine")
        return run
    }

    /// Lets the result through, and gives it time to land.
    private func release(_ run: Task<Void, Never>, until landed: (() -> Bool)? = nil) async throws {
        engine.gate.release()
        await run.value
        if let landed {
            try await eventually(landed)
        } else {
            try await Task.sleep(for: .milliseconds(200))
        }
    }

    /// Waits for `condition`, for as long as a loaded machine may need.
    private func eventually(_ condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(30)
        while !condition(), ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(5))
        }
    }

    @Test(arguments: Analysis.allCases)
    func `a result lands while its photo stays open`(_ analysis: Analysis) async throws {
        defer { try? FileManager.default.removeItem(at: folder) }
        let run = try await startOnA(analysis)
        let before = EditorState(model)
        try await release(run) { EditorState(model) != before }
        #expect(EditorState(model) != before)
    }

    @Test(arguments: Analysis.allCases)
    func `a result for one photo changes nothing on the next`(_ analysis: Analysis) async throws {
        defer { try? FileManager.default.removeItem(at: folder) }
        let run = try await startOnA(analysis)
        try await open(b, for: analysis)
        let before = EditorState(model)
        try await release(run)
        #expect(EditorState(model) == before)
    }

    @Test(arguments: Analysis.allCases)
    func `a result is dropped when its photo is opened again`(_ analysis: Analysis) async throws {
        defer { try? FileManager.default.removeItem(at: folder) }
        let run = try await startOnA(analysis)
        try await open(b, for: analysis)
        try await open(a, for: analysis)
        let before = EditorState(model)
        try await release(run)
        #expect(EditorState(model) == before)
    }

    /// Opens `url` with a subject mask, and arms the Refine Edge brush on it with a stroke painted.
    private func paintEdgeStroke(on url: URL) async throws {
        try await open(url, for: .edgeBrush)
        if model.recipe.masks.isEmpty {
            await model.createAIMask(.subject)
        }
        let mask = try #require(model.recipe.masks.first)
        let component = try #require(mask.components.first)
        model.startRefiningEdges(component.id, in: mask.id)
        model.beginStroke(at: ImagePoint(x: 0.2, y: 0.2))
        model.continueStroke(to: ImagePoint(x: 0.4, y: 0.2))
    }

    /// A stroke ended on B while A's is solved, A's solve succeeding or failing.
    private func solveAcrossSwitch(failing: Bool) async throws {
        engine.base.computed = [AIMask(
            kind: .subject, provider: "stub", revision: 1, analysisHash: "h",
            center: ImagePoint(x: 0.5, y: 0.5), bitmap: MaskBitmap(sha256: "s", width: 4, height: 4),
        )]
        try await open(b, for: .edgeBrush)
        await model.createAIMask(.subject)
        try await paintEdgeStroke(on: a)
        engine.gate.hold()
        engine.failingEdgeSolves = failing ? 1 : 0
        let solvingA = Task { await model.endEdgeStroke() }
        try await eventually { engine.gate.arrived > 0 }
        try #require(engine.gate.arrived > 0)
        try await paintEdgeStroke(on: b)
        await model.endEdgeStroke()
        try await release(solvingA)

        #expect(model.edgeBrushStrokes.isEmpty, "B's stroke was solved")
        guard case let .ai(refined) = model.recipe.masks.first?.components.first?.shape else {
            Issue.record("B lost its AI mask")
            return
        }
        #expect(refined.bitmap.sha256 == "s-brushed1")
        #expect(model.maskMessage == nil, "A's error isn't shown on B")
    }

    @Test func `a stroke ended on the next photo while the last one's is solved is solved next`() async throws {
        defer { try? FileManager.default.removeItem(at: folder) }
        try await solveAcrossSwitch(failing: false)
    }

    @Test func `a stroke that fails on the photo left doesn't touch the next photo's strokes`() async throws {
        defer { try? FileManager.default.removeItem(at: folder) }
        try await solveAcrossSwitch(failing: true)
    }

    @Test func `a model agreed to on one photo doesn't start its mask on the next`() async throws {
        defer { try? FileManager.default.removeItem(at: folder) }
        engine.base.neededModel = ModelInfo(
            id: "sam2.1-tiny", name: "Segment Anything 2.1 (tiny)", purpose: "Objects", downloadBytes: 1,
            state: .notDownloaded,
        )
        try await open(a, for: .objectSelection)
        model.cancelDrawing()
        await model.startAIMask(.objects)
        #expect(model.pendingModel != nil)
        engine.gate.hold()
        let download = Task { await model.downloadPendingModel() }
        try await eventually { engine.gate.arrived > 0 }
        try await open(b, for: .autoTone)
        try await release(download)
        #expect(model.drawingKind == nil, "Objects isn't armed on B")

        engine.base.neededModel = ModelInfo(
            id: "sam2.1-tiny", name: "Segment Anything 2.1 (tiny)", purpose: "Objects", downloadBytes: 1,
            state: .notDownloaded,
        )
        await model.startAIMask(.objects)
        #expect(model.pendingModel != nil)
        try await open(a, for: .autoTone)
        #expect(model.pendingModel == nil, "the question isn't asked on another photo")
    }

    /// Remove Dust across A, B and C, with dust on A and B; the search waits at `gate` (the
    /// worker's, or the editor's for the open photo's sources).
    private func startDustSearch(holding gate: (GatedEngine, GatedEngine) -> Gate) async throws -> (
        task: Task<Void, Never>, c: URL, speck: DetectedSpot,
    ) {
        let c = folder.appending(path: "C.ARW")
        let speck = DetectedSpot(center: ImagePoint(x: 0.3, y: 0.2), radius: 0.01, strength: 20)
        let worker = GatedEngine()
        worker.base.retouchSource = ImagePoint(x: 0.35, y: 0.25)
        worker.base.shootDust = [a: [speck], b: [speck]]
        engine.base.retouchSource = ImagePoint(x: 0.4, y: 0.2)
        model.makeWorkerEngine = { worker }
        [a, b, c].forEach { model.library.insert(LibraryItem(url: $0)) }
        try await open(a, for: .removeDust)
        model.selectAllPhotos()
        model.activeTool = .heal
        let held = gate(engine, worker)
        held.hold()
        let task = Task { await model.removeDustInSelection() }
        try await eventually { held.arrived > 0 }
        try #require(held.arrived > 0)
        return (task, c, speck)
    }

    private func finish(_ task: Task<Void, Never>) async {
        engine.gate.release()
        (model.makeWorkerEngine?() as? GatedEngine)?.gate.release()
        await task.value
        await model.settingsSync.idle()
    }

    private func healedBySync(_ url: URL, _ speck: DetectedSpot) throws {
        let saved = try #require(model.settingsSync.store.load(for: url))
        #expect(saved.recipe.spots.map(\.center) == [speck.center])
        #expect(saved.recipe.spots.first?.source == ImagePoint(x: 0.35, y: 0.25), "the worker found its source")
    }

    private func healedInEditor(_ speck: DetectedSpot) {
        #expect(model.recipe.spots.map(\.center) == [speck.center])
        #expect(model.recipe.spots.first?.source == ImagePoint(x: 0.4, y: 0.2), "the editor found its source")
        #expect(model.history.last?.name == "Remove Dust")
    }

    @Test func `Remove Dust across a selection, left while it searches, heals the photo through the sync`(
    ) async throws {
        defer { try? FileManager.default.removeItem(at: folder) }
        let (task, c, speck) = try await startDustSearch { _, worker in worker.gate }
        try await open(c, for: .removeDust)
        let before = EditorState(model)
        await finish(task)
        #expect(EditorState(model) == before, "nothing lands on the photo opened meanwhile")
        try healedBySync(a, speck)
        try healedBySync(b, speck)
        #expect(model.dustMessage == "Healed 1 speck of dust in 2 photos.")
    }

    @Test func `Remove Dust across a selection, left while the open photo's sources are found, heals it through the sync`(
    ) async throws {
        defer { try? FileManager.default.removeItem(at: folder) }
        let (task, c, speck) = try await startDustSearch { editor, _ in editor.gate }
        try await open(c, for: .removeDust)
        let before = EditorState(model)
        await finish(task)
        #expect(EditorState(model) == before)
        try healedBySync(a, speck)
        try healedBySync(b, speck)
        #expect(model.dustMessage == "Healed 1 speck of dust in 2 photos.")
    }

    @Test func `Remove Dust across a selection heals the photo left and opened again in the editor`() async throws {
        defer { try? FileManager.default.removeItem(at: folder) }
        let (task, c, speck) = try await startDustSearch { _, worker in worker.gate }
        try await open(c, for: .removeDust)
        try await open(a, for: .removeDust)
        await finish(task)
        healedInEditor(speck)
        try healedBySync(b, speck)
        #expect(model.dustMessage == "Healed 1 speck of dust in 2 photos.")
    }

    @Test func `Remove Dust across a selection heals the photo moved to in the editor, and the one left through the sync`(
    ) async throws {
        defer { try? FileManager.default.removeItem(at: folder) }
        let (task, _, speck) = try await startDustSearch { _, worker in worker.gate }
        try await open(b, for: .removeDust)
        let steps = model.history.count
        await finish(task)
        healedInEditor(speck)
        #expect(model.history.count == steps + 1, "healed once, as a step of its history")
        try healedBySync(a, speck)
        #expect(model.dustMessage == "Healed 1 speck of dust in 2 photos.")
    }

    @Test func `Remove Dust on the open photo waits for a Remove Dust batch, so no speck is healed twice`(
    ) async throws {
        defer { try? FileManager.default.removeItem(at: folder) }
        let (task, _, speck) = try await startDustSearch { editor, _ in editor.gate }
        engine.base.dust = [speck]
        #expect(model.isFindingDust, "Remove Dust is disabled while the batch runs")
        let single = Task { await model.removeDust() }
        await finish(task)
        await single.value
        healedInEditor(speck)
        try healedBySync(b, speck)
    }

    /// Started while A was read-only because its sidecar couldn't be read; the read then
    /// succeeds and A opens again with its edit, in a visit of its own.
    @Test(arguments: [Analysis.autoTone, .autoWhiteBalance, .aiMask, .maskPreset, .edgeBrush, .spot])
    func `a result started while its photo was read-only changes nothing once it reads`(
        _ analysis: Analysis,
    ) async throws {
        defer { try? FileManager.default.removeItem(at: folder) }
        let store = SidecarStore()
        var edit = EditRecipe()
        edit[.exposure] = 0.5
        try store.save(Sidecar(recipe: edit), for: a)
        let presenter = SidecarReadFailureTests.FailingPresenter(store.url(for: a), failures: [true])
        NSFileCoordinator.addFilePresenter(presenter)
        defer { NSFileCoordinator.removeFilePresenter(presenter) }
        model.sidecarReadRetryDelay = .milliseconds(500)

        let run = try await startOnA(analysis)
        try #require(model.isReadOnly, "started while it was read-only")
        try await eventually { !model.isReadOnly }
        try #require(!model.isReadOnly && model.recipe[.exposure] == 0.5)
        let read = EditorState(model)
        try await release(run)
        #expect(EditorState(model) == read)
        model.saveNow()
        await model.saves.flush()
        #expect(store.load(for: a)?.recipe == read.recipe)
    }
}
