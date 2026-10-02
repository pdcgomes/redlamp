import CoreGraphics
import Foundation
import Observation
import RedlampCanvas
import RedlampDocument
import RedlampEngineAPI
import RedlampRecipes

/// All editor state. Views read it; only its methods change it.
///
/// Talks to the rendering engine exclusively through `EditingEngine`.
@MainActor
@Observable
public final class EditorModel {
    public let engine: any EditingEngine
    public let canvas = CanvasController()
    @ObservationIgnored private let sidecars = SidecarStore()

    // MARK: Library

    /// The open folder's photos.
    public let library: FolderLibrary
    public var folder: URL? {
        library.openFolder
    }

    /// Not observed: views observe `library.count` or `library.revision`.
    public var items: [LibraryItem] {
        library.items
    }

    public internal(set) var thumbnails: [URL: CGImage] = [:]
    public internal(set) var selection: URL?
    /// Focus stacks found in the folder that have no stack document yet.
    public internal(set) var stackSuggestions: [StackSuggestion] = []
    /// The Stack workspace, when open over the editor.
    public var stackWorkspace: StackWorkspaceModel?

    // MARK: Current image

    public private(set) var info: ImageInfo?
    public private(set) var isLoading = false
    public internal(set) var errorMessage: String?
    /// The photo's sidecar was written by a newer Redlamp. Its edit is shown, but changes aren't
    /// saved: this version would lose settings it doesn't understand.
    public private(set) var isReadOnly = false
    /// The open photo's rating, flag and label, saved with its edit.
    public internal(set) var photoMetadata = PhotoMetadata()
    /// The rating, flag or label changed while the photo was opening, so its sidecar's are stale.
    @ObservationIgnored var metadataChangedWhileOpening = false
    /// Reading `recipe` observes every change to it. Views observe only what they show —
    /// `value(_:)` for one parameter, or `masks`, `pointCurve`, … — so a slider drag
    /// re-evaluates a single row rather than every panel.
    public private(set) var recipe: EditRecipe {
        get {
            access(keyPath: \.recipe)
            return storedRecipe
        }
        set {
            let old = storedRecipe
            withMutation(keyPath: \.recipe) { storedRecipe = newValue }
            for parameter in newValue.parametersChanged(from: old) {
                withMutation(keyPath: \.[observing: parameter]) {}
            }
            if newValue.treatment != old.treatment {
                withMutation(keyPath: \.treatment) {}
            }
            if newValue.baseLook != old.baseLook {
                withMutation(keyPath: \.baseLook) {}
            }
            if newValue.appliedRecipe != old.appliedRecipe {
                withMutation(keyPath: \.appliedRecipe) {}
            }
            if newValue.whiteBalanceMode != old.whiteBalanceMode {
                withMutation(keyPath: \.whiteBalanceMode) {}
            }
            if newValue.pointCurve != old.pointCurve {
                withMutation(keyPath: \.pointCurve) {}
            }
            if newValue.masks != old.masks {
                withMutation(keyPath: \.masks) {}
                if newValue.masks.map(MaskOutline.init) != old.masks.map(MaskOutline.init) {
                    withMutation(keyPath: \.maskOutlines) {}
                }
                if Self.shapes(of: newValue) != Self.shapes(of: old) {
                    withMutation(keyPath: \.maskShapes) {}
                }
            }
        }
    }

    @ObservationIgnored private var storedRecipe = EditRecipe()

    /// The edit, read without observing it (for lists that must not reload during drags).
    var unobservedRecipe: EditRecipe {
        storedRecipe
    }

    private subscript(observing parameter: ParameterID) -> Double {
        access(keyPath: \.[observing: parameter])
        return storedRecipe[parameter]
    }

    public var treatment: Treatment {
        access(keyPath: \.treatment)
        return storedRecipe.treatment
    }

    public var baseLook: BaseLookReference {
        access(keyPath: \.baseLook)
        return storedRecipe.baseLook
    }

    public var appliedRecipe: AppliedRecipe? {
        access(keyPath: \.appliedRecipe)
        return storedRecipe.appliedRecipe
    }

    public var whiteBalanceMode: WhiteBalanceMode {
        access(keyPath: \.whiteBalanceMode)
        return storedRecipe.whiteBalanceMode
    }

    public var pointCurve: [CurvePoint] {
        access(keyPath: \.pointCurve)
        return storedRecipe.pointCurve
    }

    public var masks: [MaskLayer] {
        access(keyPath: \.masks)
        return storedRecipe.masks
    }

    /// The masks without their adjustment values: views that list masks and components
    /// observe this, so dragging a mask's slider doesn't re-render them.
    public var maskOutlines: [MaskOutline] {
        access(keyPath: \.maskOutlines)
        return storedRecipe.masks.map(MaskOutline.init)
    }

    /// Every mask component's shape, by component: the canvas guides observe this.
    public var maskShapes: [UUID: MaskShape] {
        access(keyPath: \.maskShapes)
        return Self.shapes(of: storedRecipe)
    }

    private static func shapes(of recipe: EditRecipe) -> [UUID: MaskShape] {
        Dictionary(recipe.masks.flatMap(\.components).map { ($0.id, $0.shape) }) { first, _ in first }
    }

    /// Just the tone curve, observing only the parameters that shape it.
    public var toneCurve: EditRecipe {
        var curve = EditRecipe()
        curve.pointCurve = pointCurve
        for parameter in PanelID.toneCurve.parameters {
            curve[parameter] = value(parameter)
        }
        return curve
    }

    /// This session's steps: everything since the photo was opened.
    public internal(set) var history: [HistoryStep] = []
    public internal(set) var historyIndex = 0
    /// The photo's earlier sessions, newest first. They load after the photo opens.
    public internal(set) var earlierSessions: [HistorySession] = []
    public private(set) var snapshots: [Snapshot] = []
    /// Frames go straight to the canvases; views only observe whether there is one.
    @ObservationIgnored public let frames = FrameFeed()
    public private(set) var hasFrame = false
    /// Published at most ~30 times a second: enough for a live readout, while frames
    /// arrive at up to the display rate.
    public private(set) var histogram = Histogram.empty
    public private(set) var lastRenderTime: Duration?

    // MARK: View state

    /// Before / After (`\`), shown in `compareLayout`.
    public var showBefore = false {
        didSet { updateComparison() }
    }

    public var compareLayout = CompareLayout.toggle {
        didSet {
            guard compareLayout != oldValue else { return }
            onCompareLayoutChange?(compareLayout)
            updateComparison()
        }
    }

    /// Where the diagonal split's line sits: 0 top-left, 0.5 through the centre, 1 bottom-right.
    public var splitPosition = 0.5 {
        didSet { canvas.comparison = canvasComparison }
    }

    public var showClipping = false {
        didSet { requestRender() }
    }

    /// Marks photosites the sensor clipped, by channel (darktable's raw overexposed indicator).
    public var showRawClipping = false {
        didSet { requestRender() }
    }

    /// A middle-grey surround and white frame for judging colour (ISO 12646).
    public var colorAssessment = false

    public var eyedropperActive = false
    public var activeTool: EditTool = .edit {
        didSet {
            if activeTool != .masking {
                drawingKind = nil
            }
            requestRender()
        }
    }

    /// Crop tool settings: the aspect the crop keeps, and whether it stays inside the photo
    /// (Lightroom's Constrain to Image).
    public var cropAspect: CropAspect = .original
    public var cropAspectLocked = true
    /// The guide drawn in the crop (`O` cycles it, `⇧O` turns it).
    public var cropOverlay: CropOverlay = .thirds
    public var cropOverlayTurns = 0
    /// The next drag in the Crop tool draws a line to level (as ⌘-drag always does).
    public var isStraightening = false
    /// Guided Upright: drags on the canvas draw guides, in the photo's coordinates.
    public var isPlacingGuides = false {
        didSet { requestRender() }
    }

    public internal(set) var uprightGuides: [GuideLine] = []
    public var constrainCropToImage = true {
        didSet {
            guard constrainCropToImage, !oldValue else { return }
            var next = recipe
            constrainCrop(&next)
            commit(next, .crop, "Constrain to Image")
        }
    }

    /// The crop as last drawn, which Angle and Transform changes fit inside the photo again.
    @ObservationIgnored var cropIntent: CropRect = .full

    // MARK: Masking state

    public var selectedMaskID: UUID? {
        didSet { requestRender() }
    }

    public var selectedComponentID: UUID?
    public var showMaskOverlay = true {
        didSet { requestRender() }
    }

    /// The mask type armed for drawing on the canvas, if any.
    public internal(set) var drawingKind: MaskKind?
    public internal(set) var drawingOperation: MaskOperation = .add
    /// When set, the drawn shape is added to this mask instead of creating a new one.
    public internal(set) var drawingTarget: UUID?
    /// While brushing: the brush component strokes go into, once the first stroke made it.
    public internal(set) var drawingComponentID: UUID?
    /// Lightroom's A and B brushes and Erase, saved across launches.
    public var brushes = BrushSettingsSet.saved() {
        didSet { brushes.save() }
    }

    public var activeBrush: BrushChoice = .a
    /// The AI mask being computed, for a progress indicator.
    public internal(set) var aiMaskProgress: MaskKind?
    /// Why the last AI mask couldn't be made, shown in the Masking panel.
    public var maskMessage: String?
    /// The AI mask kinds the engine can make for the open photo.
    public internal(set) var availableAIMaskKinds: Set<MaskKind> = []
    /// A model the chosen mask needs, waiting for the user to agree to download it.
    public internal(set) var pendingModel: (model: ModelInfo, kind: MaskKind)?
    /// The model being downloaded, 0...1.
    public internal(set) var modelDownloadProgress: Double?
    /// What a click would select while choosing an object (a low-resolution mask).
    public internal(set) var objectPreview: MaskBitmap?
    @ObservationIgnored var objectHoverTask: Task<Void, Never>?
    /// Bumped when the user's mask presets change, so menus listing them update.
    var maskPresetsVersion = 0
    public var expandedPanels: Set<PanelID> = [.basic, .toneCurve, .colorMixer]
    public var expandedSidebarSections = Set(SidebarSection.allCases)
    public var soloMode = false
    public var leftPanelVisible = true
    public var rightPanelVisible = true
    public var filmstripVisible = true

    // MARK: Shortcut-driven view state

    /// 0 off, 1 basic, 2 detailed (Lightroom's `I`).
    public var infoOverlay = 0
    /// 0 normal, 1 dimmed, 2 off (Lightroom's `L`).
    public var lightsOut = 0
    public internal(set) var isPresenting = false
    @ObservationIgnored var visibilityBeforePresenting: (left: Bool, right: Bool, filmstrip: Bool)?
    /// The slider `,` `.` select and `-` `=` nudge; highlighted in the panels.
    public var focusedParameter: ParameterID?
    public var revealedParameter: ParameterID?
    /// The command palette (⌘K, or ⌘F for sliders), while it's open.
    var presentedPalette: CommandPaletteModel?
    /// Everything the command palette does, for the harness's log and the tests.
    @ObservationIgnored @_spi(Harness) public var onCommandPaletteEvent: ((PaletteEvent) -> Void)?
    /// Holding Option turns group titles into "Reset …" buttons, as in Lightroom.
    public var optionKeyHeld = false
    public var showMaskPins = true
    public var maskOverlayColor: MaskOverlayColor = .red {
        didSet { requestRender() }
    }

    public var maskOverlayStyle: MaskOverlayStyle = .colorOverlay {
        didSet { requestRender() }
    }

    /// Luminance Range's "Show Luminance Map": the photo's lightness in grey, the range tinted.
    public var showLuminanceMap = false {
        didSet { requestRender() }
    }

    public var showShortcuts = false
    /// The photo viewed before the current one, for Paste from Previous.
    public internal(set) var previousSelection: URL?
    /// Window-level effects the app layer performs (full screen, toolbar visibility).
    @ObservationIgnored public var onToggleFullScreen: (() -> Void)?
    @ObservationIgnored public var onToggleToolbar: (() -> Void)?

    /// Every recipe and Base Look on this machine.
    public let recipes: RecipeCatalog
    /// The recipe under the pointer, rendered without being applied.
    public internal(set) var previewingRecipe: Recipe?
    /// An edit rendered in place of the photo's without being applied: the command
    /// palette's white balance, treatment, snapshot and history previews.
    public internal(set) var previewingEdit: EditRecipe?
    /// The last applied recipe and the edit it was applied to, so its Amount stays adjustable.
    var recipeApplication: (recipe: Recipe, base: EditRecipe)?
    /// The photo's auto white balance, for recipes that ask for it.
    @ObservationIgnored var autoWhiteBalance: WhiteBalanceValue?
    public private(set) var hasClipboard = false
    /// An app-modal dialog (Export) is open: every action is unavailable, so menus, keys and
    /// the palette can't change the photo behind it.
    public internal(set) var isModalDialogOpen = false
    /// What a background export is doing ("Exporting…", then "Exported…" for a moment).
    public internal(set) var exportStatus: String?
    @ObservationIgnored var exportStatusTask: Task<Void, Never>?

    /// Called when the folder changes, so the app can remember it.
    @ObservationIgnored public var onFolderChange: ((URL) -> Void)?
    /// Called when the Before / After layout changes, so the app can remember it.
    @ObservationIgnored public var onCompareLayoutChange: ((CompareLayout) -> Void)?

    @ObservationIgnored private var temporaryClipping = false
    @ObservationIgnored private var clipboard: EditRecipe?
    @ObservationIgnored var pendingDrawingName: String?
    @ObservationIgnored var pendingDrawingKind: MaskKind?
    @ObservationIgnored var editStart: EditRecipe?
    @ObservationIgnored var editParameter: ParameterID?
    @ObservationIgnored private var session = (id: UUID(), started: Date())
    /// Whether `earlierSessions` is known: until it is, a sidecar isn't deleted, since it may hold them.
    @ObservationIgnored var earlierSessionsLoaded = true
    /// The next save removes the earlier sessions' files (Clear History).
    @ObservationIgnored var clearsSavedHistory = false
    @ObservationIgnored var historyTask: Task<Void, Never>?
    @ObservationIgnored private var generation: UInt64 = 0
    /// Canvas geometry for a photo whose first frame hasn't arrived yet. Until it does, the
    /// previous photo stays on screen rather than flashing the placeholder in between.
    @ObservationIgnored private var pendingCanvas: (imageSize: PixelSize, firstGeneration: UInt64)?
    @ObservationIgnored private var saveTask: Task<Void, Never>?
    @ObservationIgnored private var saveDeadline: ContinuousClock.Instant?
    @ObservationIgnored private var openTask: Task<Void, Never>?
    @ObservationIgnored private var framesTask: Task<Void, Never>?

    public init(engine: any EditingEngine, recipes: RecipeCatalog? = nil, library: FolderLibrary? = nil) {
        self.engine = engine
        self.recipes = recipes ?? RecipeCatalog(engine: engine)
        self.library = library ?? FolderLibrary()
        canvas.onRenderSizeChange = { [weak self] _ in self?.requestRender() }
        let frames = engine.frames()
        framesTask = Task { [weak self] in
            for await frame in frames {
                self?.receive(frame)
            }
        }
    }

    // MARK: - Opening a photo (folders: EditorModel+Library)

    public func select(_ url: URL) {
        guard url != selection else { return }
        saveNow()
        engine.prefetch(workingSet(around: url, comingFrom: selection))
        if let selection {
            previousSelection = selection
        }
        selection = url
        // Cleared first so the resets below don't render the outgoing photo; a ready photo
        // sets it again before the UI updates.
        info = nil
        errorMessage = nil
        isReadOnly = false
        photoMetadata = library.item(for: url)?.metadata ?? PhotoMetadata()
        metadataChangedWhileOpening = false
        eyedropperActive = false
        previewingRecipe = nil
        previewingEdit = nil
        recipeApplication = nil
        autoWhiteBalance = nil
        selectedMaskID = nil
        selectedComponentID = nil
        drawingKind = nil
        openTask?.cancel()
        // The sidecar is read off the main thread even for a photo already decoded: it is
        // coordinated, and iCloud Drive may have to download it first.
        let readSidecar = { [sidecars, scheduler = library.scheduler] in
            try? await scheduler.run(.onScreen) {
                OpenedSidecar(sidecar: sidecars.load(for: url), isNewer: sidecars.isWrittenByNewerVersion(for: url))
            }
        }
        if let opened = engine.openIfReady(url) {
            openTask = Task {
                let read = await readSidecar()
                guard selection == url, !Task.isCancelled else { return }
                didOpen(opened, read ?? OpenedSidecar())
            }
            return
        }
        showFrame(nil)
        pendingCanvas = nil
        latestFrame = nil
        histogram = .empty
        isLoading = true
        Task { await loadThumbnail(for: url) }
        openTask = Task { [engine] in
            let loading = Task { await readSidecar() }
            do {
                let opened = try await engine.open(url)
                let read = await loading.value
                guard selection == url else { return }
                didOpen(opened, read ?? OpenedSidecar())
            } catch is CancellationError {
                return
            } catch {
                guard selection == url else { return }
                isLoading = false
                errorMessage = error.localizedDescription
            }
        }
    }

    /// A photo's sidecar as read when it opens.
    private struct OpenedSidecar: Sendable {
        var sidecar: Sidecar?
        /// Written by a newer Redlamp: shown, but never saved over.
        var isNewer = false
    }

    private func didOpen(_ opened: ImageInfo, _ read: OpenedSidecar) {
        let sidecar = read.sidecar
        info = opened
        availableAIMaskKinds = engine.availableMaskKinds()
        maskMessage = nil
        isReadOnly = read.isNewer
        if !metadataChangedWhileOpening {
            photoMetadata = sidecar?.metadata ?? PhotoMetadata()
        }
        var loaded = sidecar?.recipe ?? EditRecipe()
        if loaded.whiteBalanceMode == .asShot, let wb = opened.asShotWhiteBalance {
            loaded[.temperature] = wb.temperature
            loaded[.tint] = wb.tint
        }
        recipe = loaded
        snapshots = sidecar?.snapshots ?? []
        startSession(opening: opened.url, recipe: loaded, hasSidecar: sidecar != nil)
        isLoading = false
        cropIntent = loaded.crop
        uprightGuides = []
        isPlacingGuides = false
        let frameSize = loaded.developedSize(imageSize: opened.pixelSize)
        if !hasFrame {
            showOnCanvas(frameSize)
        } else {
            pendingCanvas = (frameSize, generation &+ 1)
        }
        requestRender()
    }

    private func showOnCanvas(_ imageSize: PixelSize) {
        canvas.zoom = .fit
        canvas.center = CGPoint(x: 0.5, y: 0.5)
        canvas.imageSize = imageSize
    }

    // MARK: - Rendering

    private var beforeRecipe: EditRecipe {
        var before = EditRecipe()
        if let wb = info?.asShotWhiteBalance {
            before[.temperature] = wb.temperature
            before[.tint] = wb.tint
        }
        return before
    }

    public func requestRender() {
        guard let info else { return }
        var displayed = isShowingOriginal
            ? beforeRecipe.withGeometry(of: recipe)
            : (previewingEdit ?? previewingRecipe.map { previewEdit(for: $0) } ?? recipe)
        // The crop tool shows the whole straightened frame, with the crop drawn over it.
        if activeTool == .crop {
            displayed.crop = .full
        }
        // A new frame size shows once a frame of that size arrives.
        let frameSize = displayed.developedSize(imageSize: info.pixelSize)
        if pendingCanvas == nil, frameSize != canvas.imageSize, canvas.imageSize.width > 0 {
            pendingCanvas = (frameSize, generation &+ 1)
        }
        let target = pendingCanvas.map { CanvasController.RenderTarget(size: canvas.fitRenderSize(for: $0.imageSize)) }
            ?? canvas.renderTarget
        guard target.size.width > 0 else { return }
        generation &+= 1
        let overlay = activeTool == .masking && showMaskOverlay && !isShowingOriginal ? selectedMaskID : nil
        var request = RenderRequest(
            recipe: displayed,
            targetSize: target.size,
            region: target.region,
            showClipping: showClipping || temporaryClipping,
            maskOverlay: overlay,
            generation: generation,
        )
        request.maskOverlayColor = maskOverlayColor
        request.maskOverlayStyle = showLuminanceMap && overlay != nil ? .luminanceMap : maskOverlayStyle
        request.showRawClipping = showRawClipping
        request.comparison = isComparing ? beforeRecipe : nil
        engine.render(request)
    }

    /// Frames received from the engine, and the latest ones' render times (for performance
    /// diagnostics).
    @ObservationIgnored public private(set) var debugFrameCount = 0
    @ObservationIgnored public private(set) var debugRenderDurations: [Duration] = []

    private func receive(_ frame: RenderedFrame) {
        guard info != nil else { return }
        if let pending = pendingCanvas {
            guard frame.generation >= pending.firstGeneration else { return }
            pendingCanvas = nil
            showOnCanvas(pending.imageSize)
        }
        debugFrameCount += 1
        debugRenderDurations.append(frame.renderDuration)
        if debugRenderDurations.count > 4000 {
            debugRenderDurations.removeFirst(2000)
        }
        showFrame(frame)
        latestFrame = frame
        guard statsTask == nil else { return }
        let wait = lastStatsUpdate + .milliseconds(33) - .now
        statsTask = Task { [weak self] in
            if wait > .zero {
                try? await Task.sleep(for: wait)
            }
            guard let self else { return }
            statsTask = nil
            guard let latest = latestFrame else { return }
            lastStatsUpdate = .now
            histogram = latest.histogram
            // A readout people can actually read; faster only re-renders its glass capsule.
            if lastRenderTimeUpdate.duration(to: .now) > .milliseconds(250) {
                lastRenderTimeUpdate = .now
                lastRenderTime = latest.renderDuration
            }
        }
    }

    private func showFrame(_ frame: RenderedFrame?) {
        frames.show(frame)
        if hasFrame != (frame != nil) {
            hasFrame = frame != nil
        }
    }

    @ObservationIgnored private var latestFrame: RenderedFrame?
    @ObservationIgnored private var statsTask: Task<Void, Never>?
    @ObservationIgnored private var lastStatsUpdate = ContinuousClock.now
    @ObservationIgnored private var lastRenderTimeUpdate = ContinuousClock.now

    // MARK: - Parameters

    public func value(_ parameter: ParameterID) -> Double {
        self[observing: parameter]
    }

    public func isEdited(_ parameter: ParameterID) -> Bool {
        if parameter == .temperature || parameter == .tint {
            return whiteBalanceMode != .asShot
        }
        return abs(self[observing: parameter] - parameter.spec.defaultValue) > 1e-9
    }

    /// Starts a continuous edit (a slider drag); history records one step when it ends.
    public func beginEdit(_ parameter: ParameterID? = nil) {
        editStart = recipe
        editParameter = parameter
    }

    public func setValue(_ parameter: ParameterID, _ value: Double) {
        var next = recipe
        next[parameter] = parameter.spec.quantize(value)
        if EditRecipe.geometryParameters.contains(parameter) {
            constrainCrop(&next)
        }
        if parameter == .temperature || parameter == .tint {
            next.whiteBalanceMode = matchesAsShot(next) ? .asShot : .custom
        }
        guard next != recipe else { return }
        let previous = recipe
        recipe = next
        requestRender()
        scheduleSave()
        if editStart == nil {
            recordStep(for: parameter, from: previous)
        }
    }

    /// Ends a drag as one step, named for the slider it began on (see `beginEdit`) or `name`.
    public func endEdit(name: String? = nil) {
        if let name {
            endEdit(.edit, name)
        } else {
            finishEdit { [self] start in
                if let editParameter {
                    recordStep(for: editParameter, from: start)
                } else {
                    recordHistory(.edit, "Edit", from: start)
                }
            }
        }
    }

    /// Ends a drag as one step. `value` reads the value it changed, to show it before and after.
    func endEdit(_ action: HistoryAction, _ title: String, value: ((EditRecipe) -> String)? = nil) {
        finishEdit { [self] start in recordHistory(action, title, from: start, value: value) }
    }

    private func finishEdit(_ record: (EditRecipe) -> Void) {
        defer {
            editStart = nil
            editParameter = nil
        }
        guard let start = editStart, start != recipe else { return }
        record(start)
    }

    public func reset(_ parameter: ParameterID) {
        resetParameters([parameter], name: "Reset \(parameter.displayName)")
    }

    public func resetParameters(_ parameters: [ParameterID], name: String) {
        var next = recipe
        next.reset(parameters.filter { $0 != .temperature && $0 != .tint })
        if parameters.contains(.temperature) || parameters.contains(.tint) {
            next.whiteBalanceMode = .asShot
            if let wb = info?.asShotWhiteBalance {
                next[.temperature] = wb.temperature
                next[.tint] = wb.tint
            }
        }
        if parameters.count == 1, let parameter = parameters.first {
            commit(next, .reset, name) { parameter.spec.formatted($0[parameter]) }
        } else {
            commit(next, .reset, name)
        }
    }

    public func resetAll() {
        commit(beforeRecipe, .reset, "Reset")
    }

    /// Alt-drag on tone sliders previews clipping, like Lightroom.
    public func setTemporaryClipping(_ on: Bool) {
        guard temporaryClipping != on else { return }
        temporaryClipping = on
        requestRender()
    }

    // MARK: - Base Look, treatment, white balance

    public func setTreatment(_ treatment: Treatment) {
        var next = recipe
        next.treatment = treatment
        commit(next, .treatment, "Treatment") { $0.treatment.name }
    }

    public func setBaseLook(_ look: BaseLookReference) {
        var next = recipe
        next.baseLook = look.withAmount(recipe.baseLook.isSameLook(as: look) ? recipe.baseLook.amount : look.amount)
        if look == BuiltInBaseLook.monochrome.reference || recipes.package(for: look)?.parameters.isMonochrome == true {
            next.treatment = .blackAndWhite
        }
        commit(next, .baseLook, "Base Look") { $0.baseLook.name }
    }

    public func setWhiteBalanceMode(_ mode: WhiteBalanceMode) {
        switch mode {
        case .asShot:
            guard let wb = info?.asShotWhiteBalance else { return }
            applyWhiteBalance(wb, mode: .asShot)
        case .auto:
            Task {
                if let wb = await engine.autoWhiteBalance() {
                    applyWhiteBalance(wb, mode: .auto)
                }
            }
        case .custom:
            var next = recipe
            next.whiteBalanceMode = .custom
            commit(next, .whiteBalance, "White Balance") { $0.whiteBalanceMode.name }
        default:
            if let wb = mode.presetValue {
                applyWhiteBalance(wb, mode: mode)
            }
        }
    }

    public func sampleWhiteBalance(at point: CGPoint) {
        Task {
            guard let photoPoint = imagePoint(forCanvas: point) else { return }
            if let wb = await engine.whiteBalance(sampledAt: photoPoint) {
                applyWhiteBalance(wb, mode: .custom, selector: true)
            }
            eyedropperActive = false
        }
    }

    /// A preset shows the mode it came from and went to; the selector, the temperature.
    private func applyWhiteBalance(_ wb: WhiteBalanceValue, mode: WhiteBalanceMode, selector: Bool = false) {
        var next = recipe
        next.whiteBalanceMode = mode
        next[.temperature] = ParameterID.temperature.spec.quantize(wb.temperature)
        next[.tint] = ParameterID.tint.spec.quantize(wb.tint)
        if selector {
            commit(next, .whiteBalance, "White Balance Selector") {
                "\(ParameterID.temperature.spec.formatted($0[.temperature])) K"
            }
        } else {
            commit(next, .whiteBalance, "White Balance") { $0.whiteBalanceMode.name }
        }
    }

    private func matchesAsShot(_ candidate: EditRecipe) -> Bool {
        guard let wb = info?.asShotWhiteBalance else { return false }
        return abs(candidate[.temperature] - ParameterID.temperature.spec.quantize(wb.temperature)) < 1
            && abs(candidate[.tint] - ParameterID.tint.spec.quantize(wb.tint)) < 0.5
    }

    public func autoTone() {
        Task {
            let values = await engine.autoTone(for: recipe)
            guard !values.isEmpty else { return }
            var next = recipe
            for (parameter, value) in values {
                next[parameter] = value
            }
            commit(next, .auto, "Auto Settings")
        }
    }

    // MARK: - Tone curve

    public func setPointCurve(_ points: [CurvePoint]) {
        var next = recipe
        next.pointCurve = points
        guard next != recipe else { return }
        let previous = recipe
        recipe = next
        requestRender()
        scheduleSave()
        if editStart == nil {
            recordHistory(.toneCurve, "Point Curve", from: previous)
        }
    }

    public func resetPointCurve() {
        var next = recipe
        next.pointCurve = EditRecipe.linearPointCurve
        commit(next, .reset, "Reset Point Curve")
    }

    // MARK: - Snapshots

    public func createSnapshot() {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        snapshots.append(Snapshot(name: formatter.string(from: Date()), recipe: recipe))
        scheduleSave()
    }

    public func applySnapshot(_ snapshot: Snapshot) {
        commit(snapshot.recipe, .snapshot, "Snapshot") { _ in snapshot.name }
    }

    public func deleteSnapshot(_ snapshot: Snapshot) {
        snapshots.removeAll { $0.id == snapshot.id }
        scheduleSave()
    }

    // MARK: - History (see EditorModel+History)

    public func goToHistory(_ index: Int) {
        guard history.indices.contains(index) else { return }
        historyIndex = index
        recipe = history[index].recipe
        requestRender()
        scheduleSave()
    }

    /// A new session for the photo just opened; its earlier ones load in the background.
    private func startSession(opening url: URL, recipe: EditRecipe, hasSidecar: Bool) {
        history = [HistoryStep(action: .open, title: hasSidecar ? "Opened" : "Import", recipe: recipe)]
        historyIndex = 0
        session = (UUID(), Date())
        clearsSavedHistory = false
        earlierSessions = []
        earlierSessionsLoaded = !hasSidecar
        historyTask?.cancel()
        guard hasSidecar else { return }
        historyTask = Task { [sidecars] in
            let sessions = await Task.detached(priority: .utility) { sidecars.loadHistory(for: url) }.value
            guard selection == url, !Task.isCancelled else { return }
            earlierSessions = sessions.filter { $0.id != session.id }
            earlierSessionsLoaded = true
        }
    }

    /// Applies a change without recording history (the live part of a drag).
    func applyLive(_ next: EditRecipe) {
        guard next != recipe else { return }
        recipe = next
        requestRender()
        scheduleSave()
    }

    /// A live change, such as dragging the crop: history records one step when the drag ends.
    func apply(_ next: EditRecipe) {
        guard next != recipe else { return }
        let previous = recipe
        recipe = next
        requestRender()
        scheduleSave()
        if editStart == nil {
            recordHistory(.crop, "Crop", from: previous)
        }
    }

    /// Applies a change as one step. `value` reads the value it changed, to show it before and after.
    func commit(_ next: EditRecipe, _ action: HistoryAction, _ title: String, value: ((EditRecipe) -> String)? = nil) {
        guard next != recipe else { return }
        let previous = recipe
        recipe = next
        recordHistory(action, title, from: previous, value: value)
        requestRender()
        scheduleSave()
    }

    // MARK: - Copy / paste

    public func copySettings() {
        clipboard = recipe
        hasClipboard = true
    }

    public func pasteSettings() {
        guard let clipboard else { return }
        commit(clipboard, .paste, "Paste Settings")
        updatePastedAIMasks()
    }

    // MARK: - Panels

    public func togglePanel(_ panel: PanelID, solo: Bool) {
        if solo || soloMode {
            expandedPanels = expandedPanels.contains(panel) && expandedPanels.count == 1 ? [] : [panel]
        } else if expandedPanels.contains(panel) {
            expandedPanels.remove(panel)
        } else {
            expandedPanels.insert(panel)
        }
    }

    /// The left column's panels expand and collapse as the Develop panels do; Solo Mode is
    /// Option-click there, so the inspector's setting doesn't reach them.
    public func toggleSidebarSection(_ section: SidebarSection, solo: Bool) {
        if solo {
            expandedSidebarSections = expandedSidebarSections == [section] ? [] : [section]
        } else if expandedSidebarSections.contains(section) {
            expandedSidebarSections.remove(section)
        } else {
            expandedSidebarSections.insert(section)
        }
    }

    #if DEBUG || REDLAMP_PROFILING
        /// Scripted state changes for development snapshots (`--snapshot-script`).
        public func applyDebugCommand(_ key: String, _ value: String) {
            switch key {
            case "panel":
                expandedPanels = value == "all" ? Set(PanelID.allCases) :
                    Set(value.split(separator: "+").compactMap { PanelID(rawValue: String($0)) })
            case "tool":
                activeTool = EditTool(rawValue: value) ?? .edit
            case "select":
                if let index = Int(value), items.indices.contains(index) {
                    select(items[index].url)
                }
            case "zoom":
                canvas.zoom = value == "1:1" ? .oneToOne : value == "fill" ? .fill : .fit
            case "action":
                if let action = ShortcutAction(rawValue: value) {
                    perform(action)
                }
            case "before":
                showBefore = value == "1"
            case "compare":
                compareLayout = CompareLayout(rawValue: value) ?? .toggle
            case "split":
                splitPosition = Double(value) ?? 0.5
            case "clipping":
                showClipping = value == "1"
            case "rawClipping":
                showRawClipping = value == "1"
            case "assessment":
                colorAssessment = value == "1"
            case "recipe", "preset":
                if let recipe = recipes.recipe(id: value) ?? recipes.recipe(id: "redlamp/\(value)") {
                    applyRecipe(recipe)
                }
            case "baseLook", "profile":
                if let look = BuiltInBaseLook(legacyID: value) ?? BuiltInBaseLook(legacyID: "redlamp.\(value)") {
                    setBaseLook(look.reference)
                } else if let package = recipes.baseLooks.first(where: { $0.id == value || $0.slot == value }) {
                    setBaseLook(package.reference)
                }
            case "wb":
                if let mode = WhiteBalanceMode(rawValue: value) {
                    setWhiteBalanceMode(mode)
                }
            case "linear", "radial":
                // linear=x1:y1:x2:y2   radial=cx:cy:rx:ry[:feather]
                let n = value.split(separator: ":").compactMap { Double($0) }
                guard n.count >= 4 else { return }
                let shape: MaskShape = key == "linear"
                    ? .linear(LinearMask(start: ImagePoint(x: n[0], y: n[1]), end: ImagePoint(x: n[2], y: n[3])))
                    : .radial(RadialMask(
                        center: ImagePoint(x: n[0], y: n[1]), radiusX: n[2], radiusY: n[3],
                        feather: n.count > 4 ? n[4] : 50,
                    ))
                startDrawing(key == "linear" ? .linear : .radial)
                beginDrawing(shape)
                finishDrawing()
            default:
                let parameter = ParameterID(rawValue: key) ?? ParameterID.allCases.first { key == "\($0)" }
                if let parameter, let number = Double(value) {
                    setSliderValue(parameter, number)
                }
            }
        }
    #endif

    // MARK: - Persistence

    /// Saves 600 ms after the last change. A drag pushes the deadline back on every event
    /// rather than spawning a task per event.
    func scheduleSave() {
        saveDeadline = .now + .milliseconds(600)
        guard saveTask == nil else { return }
        saveTask = Task { [weak self] in
            while let deadline = self?.saveDeadline, deadline > .now {
                try? await Task.sleep(until: deadline)
                if Task.isCancelled {
                    return
                }
            }
            self?.saveNow()
        }
    }

    public func saveNow() {
        saveTask?.cancel()
        saveTask = nil
        saveDeadline = nil
        guard let url = selection, info != nil, !isReadOnly else { return }
        let metadata = photoMetadata
        var sidecar = Sidecar(
            recipe: recipe, snapshots: snapshots, metadata: metadata.isEmpty ? nil : metadata,
            session: HistorySession(
                id: session.id,
                started: session.started,
                steps: Array(history.prefix(historyIndex + 1)),
            ),
        )
        sidecar.clearsHistory = clearsSavedHistory
        clearsSavedHistory = false
        let pristine = sidecar.isPristine && earlierSessionsLoaded && earlierSessions.isEmpty
        let store = sidecars
        Task.detached(priority: .utility) {
            if pristine {
                store.delete(for: url)
            } else {
                try? store.save(sidecar, for: url)
            }
        }
        let hasEdits = !recipe.isPristine
        library.update(url) { item in
            item.hasEdits = hasEdits
            item.metadata = metadata
        }
    }
}
