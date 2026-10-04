import CoreGraphics
import Foundation
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

    func refineMaskEdges(_ bitmap: MaskBitmap) async throws -> MaskBitmap {
        await gate.pass()
        return try await base.refineMaskEdges(bitmap)
    }

    func refineMaskEdges(_ bitmap: MaskBitmap, along strokes: [BrushStroke]) async throws -> MaskBitmap {
        await gate.pass()
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
        await base.detectDust(in: photos, sensitivity: sensitivity, progress: progress)
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

    func render(_ request: RenderRequest) {
        base.render(request)
    }

    func frames() -> AsyncStream<RenderedFrame> {
        base.frames()
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
        for _ in 0 ..< 400 where model.info?.url != url {
            try await Task.sleep(for: .milliseconds(5))
        }
        try #require(model.info?.url == url)
        analysis.rearm(model)
    }

    /// Opens A, starts `analysis` on it, and waits until the engine is working on it.
    private func startOnA(_ analysis: Analysis) async throws -> Task<Void, Never> {
        try await open(a, for: analysis)
        await analysis.prepare(model, engine)
        engine.gate.hold()
        let run = analysis.start(model)
        for _ in 0 ..< 400 where engine.gate.arrived == 0 {
            try await Task.sleep(for: .milliseconds(5))
        }
        try #require(engine.gate.arrived > 0, "the analysis reached the engine")
        return run
    }

    /// Lets the result through, and gives it time to land.
    private func release(_ run: Task<Void, Never>, until landed: () -> Bool = { false }) async throws {
        engine.gate.release()
        await run.value
        for _ in 0 ..< 40 where !landed() {
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

    @Test func `Remove Dust across a selection heals the open photo through the sync once it is left`() async throws {
        defer { try? FileManager.default.removeItem(at: folder) }
        let c = folder.appending(path: "C.ARW")
        let speck = DetectedSpot(center: ImagePoint(x: 0.3, y: 0.2), radius: 0.01, strength: 20)
        let worker = StubEngine()
        worker.retouchSource = ImagePoint(x: 0.35, y: 0.25)
        worker.shootDust = [a: [speck], b: [speck]]
        model.makeWorkerEngine = { worker }
        [a, b, c].forEach { model.library.insert(LibraryItem(url: $0)) }
        try await open(a, for: .removeDust)
        model.selectAllPhotos()
        model.activeTool = .heal
        engine.gate.hold()
        let run = Task { await model.removeDustInSelection() }
        for _ in 0 ..< 400 where engine.gate.arrived == 0 {
            try await Task.sleep(for: .milliseconds(5))
        }
        try #require(engine.gate.arrived > 0)
        try await open(c, for: .removeDust)
        let before = EditorState(model)
        try await release(run)
        await model.settingsSync.idle()

        #expect(EditorState(model) == before, "nothing lands on the photo opened meanwhile")
        for url in [a, b] {
            let saved = try #require(model.settingsSync.store.load(for: url))
            #expect(saved.recipe.spots.map(\.center) == [speck.center])
            #expect(saved.recipe.spots.first?.source == ImagePoint(x: 0.35, y: 0.25))
        }
    }
}
