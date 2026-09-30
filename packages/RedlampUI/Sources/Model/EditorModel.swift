import CoreGraphics
import Foundation
import Observation
import RedlampCanvas
import RedlampDocument
import RedlampEngineAPI

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

    public private(set) var folder: URL?
    public internal(set) var items: [LibraryItem] = []
    public private(set) var thumbnails: [URL: CGImage] = [:]
    public private(set) var selection: URL?

    // MARK: Current image

    public private(set) var info: ImageInfo?
    public private(set) var isLoading = false
    public private(set) var errorMessage: String?
    /// The photo's sidecar was written by a newer Redlamp. Its edit is shown, but changes aren't
    /// saved: this version would lose settings it doesn't understand.
    public private(set) var isReadOnly = false
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
            if newValue.profile != old.profile {
                withMutation(keyPath: \.profile) {}
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

    private subscript(observing parameter: ParameterID) -> Double {
        access(keyPath: \.[observing: parameter])
        return storedRecipe[parameter]
    }

    public var treatment: Treatment {
        access(keyPath: \.treatment)
        return storedRecipe.treatment
    }

    public var profile: ProfileReference {
        access(keyPath: \.profile)
        return storedRecipe.profile
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

    public private(set) var history: [HistoryStep] = []
    public private(set) var historyIndex = 0
    public private(set) var snapshots: [Snapshot] = []
    /// Frames go straight to the canvases; views only observe whether there is one.
    @ObservationIgnored public let frames = FrameFeed()
    public private(set) var hasFrame = false
    /// Published at most ~30 times a second: enough for a live readout, while frames
    /// arrive at up to the display rate.
    public private(set) var histogram = Histogram.empty
    public private(set) var lastRenderTime: Duration?

    // MARK: View state

    public var showBefore = false {
        didSet { requestRender() }
    }

    public var showClipping = false {
        didSet { requestRender() }
    }

    public var eyedropperActive = false
    public var activeTool: EditTool = .edit {
        didSet {
            if activeTool != .masking {
                drawingKind = nil
            }
            requestRender()
        }
    }

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
    public var expandedPanels: Set<PanelID> = [.basic, .toneCurve, .colorMixer]
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
    /// Holding Option turns group titles into "Reset …" buttons, as in Lightroom.
    public var optionKeyHeld = false
    public var showMaskPins = true
    public var maskOverlayColor: MaskOverlayColor = .red {
        didSet { requestRender() }
    }

    public var showShortcuts = false
    /// The photo viewed before the current one, for Paste from Previous.
    public internal(set) var previousSelection: URL?
    /// Window-level effects the app layer performs (full screen, toolbar visibility).
    @ObservationIgnored public var onToggleFullScreen: (() -> Void)?
    @ObservationIgnored public var onToggleToolbar: (() -> Void)?

    /// Live panel widths. The canvas deliberately ignores these (see `PanelMetrics`).
    public var sidebarWidth: CGFloat = 250
    public var inspectorWidth: CGFloat = 316
    public private(set) var previewingPreset: Preset?
    public private(set) var hasClipboard = false

    /// Called when the folder changes, so the app can remember it.
    @ObservationIgnored public var onFolderChange: ((URL) -> Void)?

    @ObservationIgnored private var temporaryClipping = false
    @ObservationIgnored private var clipboard: EditRecipe?
    @ObservationIgnored var pendingDrawingName: String?
    @ObservationIgnored var editStart: EditRecipe?
    @ObservationIgnored var editParameter: ParameterID?
    @ObservationIgnored private var generation: UInt64 = 0
    /// Canvas geometry for a photo whose first frame hasn't arrived yet. Until it does, the
    /// previous photo stays on screen rather than flashing the placeholder in between.
    @ObservationIgnored private var pendingCanvas: (imageSize: PixelSize, firstGeneration: UInt64)?
    @ObservationIgnored private var saveTask: Task<Void, Never>?
    @ObservationIgnored private var saveDeadline: ContinuousClock.Instant?
    @ObservationIgnored private var openTask: Task<Void, Never>?
    @ObservationIgnored private var framesTask: Task<Void, Never>?

    public init(engine: any EditingEngine) {
        self.engine = engine
        canvas.onRenderSizeChange = { [weak self] _ in self?.requestRender() }
        let frames = engine.frames()
        framesTask = Task { [weak self] in
            for await frame in frames {
                self?.receive(frame)
            }
        }
    }

    // MARK: - Library

    /// Opens a folder, or loose files (their folder becomes the library).
    public func open(_ urls: [URL]) {
        guard let first = urls.first else { return }
        var isDirectory: ObjCBool = false
        FileManager.default.fileExists(atPath: first.path, isDirectory: &isDirectory)
        if isDirectory.boolValue {
            openFolder(first, select: nil)
        } else {
            openFolder(first.deletingLastPathComponent(), select: first)
        }
    }

    private func openFolder(_ url: URL, select target: URL?) {
        folder = url
        onFolderChange?(url)
        let store = sidecars
        Task {
            let found = await Task.detached(priority: .userInitiated) {
                Library.images(in: url).map { image in
                    let summary = Library.summary(image, store: store)
                    return LibraryItem(url: image, hasEdits: summary.hasEdits, metadata: summary.metadata)
                }
            }.value
            guard folder == url else { return }
            items = found
            thumbnails = [:]
            if let next = target ?? found.first?.url {
                select(next)
            }
        }
    }

    public func loadThumbnail(for url: URL) async {
        guard thumbnails[url] == nil else { return }
        if let image = await engine.thumbnail(for: url, maxPixelSize: 256) {
            thumbnails[url] = image
        }
    }

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
        eyedropperActive = false
        previewingPreset = nil
        selectedMaskID = nil
        selectedComponentID = nil
        drawingKind = nil
        openTask?.cancel()
        if let opened = engine.openIfReady(url) {
            didOpen(opened, sidecar: sidecars.load(for: url))
            return
        }
        showFrame(nil)
        pendingCanvas = nil
        latestFrame = nil
        histogram = .empty
        isLoading = true
        Task { await loadThumbnail(for: url) }
        openTask = Task { [engine, sidecars] in
            do {
                let opened = try await engine.open(url)
                guard selection == url else { return }
                didOpen(opened, sidecar: sidecars.load(for: url))
            } catch is CancellationError {
                return
            } catch {
                guard selection == url else { return }
                isLoading = false
                errorMessage = error.localizedDescription
            }
        }
    }

    public func selectNext() {
        step(by: 1)
    }

    public func selectPrevious() {
        step(by: -1)
    }

    private func step(by offset: Int) {
        guard let selection, let index = items.firstIndex(where: { $0.url == selection }) else { return }
        let next = index + offset
        guard items.indices.contains(next) else { return }
        select(items[next].url)
    }

    /// The photo being opened, then its neighbours, the direction of travel first.
    private func workingSet(around url: URL, comingFrom previous: URL?) -> [URL] {
        guard let index = items.firstIndex(where: { $0.url == url }) else { return [url] }
        let backward = previous.flatMap { previous in items.firstIndex { $0.url == previous } }.map { $0 > index }
        let offsets = backward == true ? [-1, 1, -2] : [1, -1, 2]
        return [url] + offsets.map { index + $0 }.filter(items.indices.contains).map { items[$0].url }
    }

    private func didOpen(_ opened: ImageInfo, sidecar: Sidecar?) {
        info = opened
        isReadOnly = sidecars.isWrittenByNewerVersion(for: opened.url)
        var loaded = sidecar?.recipe ?? EditRecipe()
        if loaded.whiteBalanceMode == .asShot, let wb = opened.asShotWhiteBalance {
            loaded[.temperature] = wb.temperature
            loaded[.tint] = wb.tint
        }
        recipe = loaded
        snapshots = sidecar?.snapshots ?? []
        history = [HistoryStep(name: sidecar == nil ? "Import" : "Opened with edits", recipe: loaded)]
        historyIndex = 0
        isLoading = false
        if !hasFrame {
            showOnCanvas(opened.pixelSize)
        } else {
            pendingCanvas = (opened.pixelSize, generation &+ 1)
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
        guard info != nil else { return }
        let target = pendingCanvas.map { CanvasController.RenderTarget(size: canvas.fitRenderSize(for: $0.imageSize)) }
            ?? canvas.renderTarget
        guard target.size.width > 0 else { return }
        generation &+= 1
        let displayed = showBefore ? beforeRecipe : (previewingPreset.map { $0.apply(to: recipe) } ?? recipe)
        let overlay = activeTool == .masking && showMaskOverlay && !showBefore ? selectedMaskID : nil
        var request = RenderRequest(
            recipe: displayed,
            targetSize: target.size,
            region: target.region,
            showClipping: showClipping || temporaryClipping,
            maskOverlay: overlay,
            generation: generation,
        )
        request.maskOverlayColor = maskOverlayColor
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
        if parameter == .temperature || parameter == .tint {
            next.whiteBalanceMode = matchesAsShot(next) ? .asShot : .custom
        }
        guard next != recipe else { return }
        recipe = next
        requestRender()
        scheduleSave()
        if editStart == nil {
            recordHistory(historyName(for: parameter))
        }
    }

    public func endEdit(name: String? = nil) {
        defer {
            editStart = nil
            editParameter = nil
        }
        guard let start = editStart, start != recipe else { return }
        if let name {
            recordHistory(name)
        } else if let editParameter {
            recordHistory(historyName(for: editParameter))
        } else {
            recordHistory("Edit")
        }
    }

    public func reset(_ parameter: ParameterID) {
        resetParameters([parameter], name: "Reset \(parameter.spec.label)")
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
        commit(next, name: name)
    }

    public func resetAll() {
        commit(beforeRecipe, name: "Reset")
    }

    func historyName(for parameter: ParameterID) -> String {
        let spec = parameter.spec
        let key = parameter.rawValue
        if parameter.isMaskScoped {
            return "\(selectedMask?.name ?? "Mask") \(spec.label) \(spec.formatted(maskValue(parameter)))"
        }
        let prefix: String = if PanelID.colorMixer.parameters.contains(parameter) {
            "\(spec.label) \(mixerAttribute(parameter))"
        } else if PanelID.toneCurve.parameters.contains(parameter) {
            "Curve \(spec.label)"
        } else if let range = GradingRange.allCases.first(where: { key.hasPrefix("grading.\($0.rawValue).") }) {
            "\(range.name) \(spec.label)"
        } else if key.hasPrefix("effects.vignette.") {
            "Vignette \(spec.label)"
        } else if key.hasPrefix("effects.grain.") {
            "Grain \(spec.label)"
        } else if key.hasPrefix("detail.sharpen.") {
            "Sharpening \(spec.label)"
        } else if key.hasPrefix("detail.noise.") {
            "Noise Reduction \(spec.label)"
        } else {
            spec.label
        }
        return "\(prefix) \(spec.formatted(recipe[parameter]))"
    }

    private func mixerAttribute(_ parameter: ParameterID) -> String {
        if parameter.rawValue.contains(".hue.") {
            return "Hue"
        }
        if parameter.rawValue.contains(".saturation.") {
            return "Saturation"
        }
        return "Luminance"
    }

    /// Alt-drag on tone sliders previews clipping, like Lightroom.
    public func setTemporaryClipping(_ on: Bool) {
        guard temporaryClipping != on else { return }
        temporaryClipping = on
        requestRender()
    }

    // MARK: - Profile, treatment, white balance

    public func setTreatment(_ treatment: Treatment) {
        var next = recipe
        next.treatment = treatment
        commit(next, name: "Treatment: \(treatment.name)")
    }

    public func setProfile(_ profile: BuiltInProfile) {
        var next = recipe
        next.profile = profile.reference
        if profile == .monochrome {
            next.treatment = .blackAndWhite
        }
        commit(next, name: "Profile: \(profile.name)")
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
            commit(next, name: "White Balance: Custom")
        default:
            if let wb = mode.presetValue {
                applyWhiteBalance(wb, mode: mode)
            }
        }
    }

    public func sampleWhiteBalance(at point: CGPoint) {
        Task {
            if let wb = await engine.whiteBalance(sampledAt: point) {
                applyWhiteBalance(wb, mode: .custom, name: "White Balance: Selector")
            }
            eyedropperActive = false
        }
    }

    private func applyWhiteBalance(_ wb: WhiteBalanceValue, mode: WhiteBalanceMode, name: String? = nil) {
        var next = recipe
        next.whiteBalanceMode = mode
        next[.temperature] = ParameterID.temperature.spec.quantize(wb.temperature)
        next[.tint] = ParameterID.tint.spec.quantize(wb.tint)
        commit(next, name: name ?? "White Balance: \(mode.name)")
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
            commit(next, name: "Auto Settings")
        }
    }

    // MARK: - Tone curve

    public func setPointCurve(_ points: [CurvePoint]) {
        var next = recipe
        next.pointCurve = points
        guard next != recipe else { return }
        recipe = next
        requestRender()
        scheduleSave()
        if editStart == nil {
            recordHistory("Point Curve")
        }
    }

    public func resetPointCurve() {
        var next = recipe
        next.pointCurve = EditRecipe.linearPointCurve
        commit(next, name: "Reset Point Curve")
    }

    // MARK: - Presets and snapshots

    public func applyPreset(_ preset: Preset) {
        previewingPreset = nil
        commit(preset.apply(to: recipe), name: "Preset: \(preset.name)")
    }

    /// Hover preview: renders the preset without committing it.
    public func previewPreset(_ preset: Preset?) {
        guard previewingPreset != preset else { return }
        previewingPreset = preset
        requestRender()
    }

    public func createSnapshot() {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        snapshots.append(Snapshot(name: formatter.string(from: Date()), recipe: recipe))
        scheduleSave()
    }

    public func applySnapshot(_ snapshot: Snapshot) {
        commit(snapshot.recipe, name: "Snapshot: \(snapshot.name)")
    }

    public func deleteSnapshot(_ snapshot: Snapshot) {
        snapshots.removeAll { $0.id == snapshot.id }
        scheduleSave()
    }

    // MARK: - History

    public var canUndo: Bool {
        historyIndex > 0
    }

    public var canRedo: Bool {
        historyIndex < history.count - 1
    }

    public func undo() {
        guard canUndo else { return }
        goToHistory(historyIndex - 1)
    }

    public func redo() {
        guard canRedo else { return }
        goToHistory(historyIndex + 1)
    }

    public func goToHistory(_ index: Int) {
        guard history.indices.contains(index) else { return }
        historyIndex = index
        recipe = history[index].recipe
        requestRender()
        scheduleSave()
    }

    public func clearHistory() {
        history = [HistoryStep(name: "History cleared", recipe: recipe)]
        historyIndex = 0
    }

    /// Applies a change without recording history (the live part of a drag).
    func applyLive(_ next: EditRecipe) {
        guard next != recipe else { return }
        recipe = next
        requestRender()
        scheduleSave()
    }

    func commit(_ next: EditRecipe, name: String) {
        guard next != recipe else { return }
        recipe = next
        recordHistory(name)
        requestRender()
        scheduleSave()
    }

    func recordHistory(_ name: String) {
        if historyIndex < history.count - 1 {
            history.removeSubrange((historyIndex + 1)...)
        }
        history.append(HistoryStep(name: name, recipe: recipe))
        if history.count > 500 {
            history.removeFirst(history.count - 500)
        }
        historyIndex = history.count - 1
    }

    // MARK: - Copy / paste

    public func copySettings() {
        clipboard = recipe
        hasClipboard = true
    }

    public func pasteSettings() {
        guard let clipboard else { return }
        commit(clipboard, name: "Paste Settings")
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

    // MARK: - Export

    public func exportCurrent(to url: URL, format: ImageExporter.Format) async throws {
        let bits = format == .tiff || format == .png ? 16 : 8
        let image = try await engine.renderStill(StillRequest(
            recipe: recipe,
            colorSpace: .sRGB,
            bitsPerComponent: bits,
        ))
        try await Task.detached(priority: .userInitiated) {
            try ImageExporter.write(image, to: url, format: format)
        }.value
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
            case "sidebarWidth":
                sidebarWidth = CGFloat(Double(value) ?? 250)
            case "inspectorWidth":
                inspectorWidth = CGFloat(Double(value) ?? 316)
            case "before":
                showBefore = value == "1"
            case "clipping":
                showClipping = value == "1"
            case "preset":
                if let preset = BuiltInPresets.all.first(where: { $0.id == value }) {
                    applyPreset(preset)
                }
            case "profile":
                if let profile = BuiltInProfile(rawValue: "redlamp.\(value)") {
                    setProfile(profile)
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
        let metadata = items.first { $0.url == url }?.metadata ?? PhotoMetadata()
        let sidecar = Sidecar(recipe: recipe, snapshots: snapshots, metadata: metadata.isEmpty ? nil : metadata)
        let pristine = sidecar.isPristine
        let store = sidecars
        Task.detached(priority: .utility) {
            if pristine {
                store.delete(for: url)
            } else {
                try? store.save(sidecar, for: url)
            }
        }
        if let index = items.firstIndex(where: { $0.url == url }) {
            items[index].hasEdits = !recipe.isPristine
        }
    }
}
