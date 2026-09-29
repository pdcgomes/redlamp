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
    public private(set) var items: [LibraryItem] = []
    public private(set) var thumbnails: [URL: CGImage] = [:]
    public private(set) var selection: URL?

    // MARK: Current image

    public private(set) var info: ImageInfo?
    public private(set) var isLoading = false
    public private(set) var errorMessage: String?
    public private(set) var recipe = EditRecipe()
    public private(set) var history: [HistoryStep] = []
    public private(set) var historyIndex = 0
    public private(set) var snapshots: [Snapshot] = []
    public private(set) var frame: RenderedFrame?
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
    public var activeTool: EditTool = .edit
    public var expandedPanels: Set<PanelID> = [.basic, .toneCurve, .colorMixer]
    public var soloMode = false
    public var leftPanelVisible = true
    public var rightPanelVisible = true
    public var filmstripVisible = true
    public private(set) var previewingPreset: Preset?
    public private(set) var hasClipboard = false

    /// Called when the folder changes, so the app can remember it.
    @ObservationIgnored public var onFolderChange: ((URL) -> Void)?

    @ObservationIgnored private var temporaryClipping = false
    @ObservationIgnored private var clipboard: EditRecipe?
    @ObservationIgnored private var editStart: EditRecipe?
    @ObservationIgnored private var editParameter: ParameterID?
    @ObservationIgnored private var generation: UInt64 = 0
    @ObservationIgnored private var saveTask: Task<Void, Never>?
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
                Library.images(in: url).map { LibraryItem(url: $0, hasEdits: Library.hasEdits($0, store: store)) }
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
        selection = url
        info = nil
        frame = nil
        histogram = .empty
        errorMessage = nil
        isLoading = true
        eyedropperActive = false
        previewingPreset = nil
        openTask?.cancel()
        openTask = Task { [engine, sidecars] in
            await loadThumbnail(for: url)
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

    private func didOpen(_ opened: ImageInfo, sidecar: Sidecar?) {
        info = opened
        var loaded = sidecar?.recipe ?? EditRecipe()
        if loaded.whiteBalanceMode == .asShot, let wb = opened.asShotWhiteBalance {
            loaded[.temperature] = wb.temperature
            loaded[.tint] = wb.tint
        }
        recipe = loaded
        snapshots = sidecar?.snapshots ?? []
        history = [HistoryStep(name: sidecar == nil ? "Import" : "Opened with edits", recipe: loaded)]
        historyIndex = 0
        canvas.zoom = .fit
        canvas.center = CGPoint(x: 0.5, y: 0.5)
        canvas.imageSize = opened.pixelSize
        isLoading = false
        requestRender()
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
        let size = canvas.renderSize
        guard size.width > 0 else { return }
        generation &+= 1
        let displayed = showBefore ? beforeRecipe : (previewingPreset.map { $0.apply(to: recipe) } ?? recipe)
        engine.render(RenderRequest(
            recipe: displayed,
            targetSize: size,
            showClipping: showClipping || temporaryClipping,
            generation: generation,
        ))
    }

    private func receive(_ frame: RenderedFrame) {
        guard info != nil else { return }
        self.frame = frame
        histogram = frame.histogram
        lastRenderTime = frame.renderDuration
    }

    // MARK: - Parameters

    public func value(_ parameter: ParameterID) -> Double {
        recipe[parameter]
    }

    public func isEdited(_ parameter: ParameterID) -> Bool {
        if parameter == .temperature || parameter == .tint {
            return recipe.whiteBalanceMode != .asShot
        }
        return abs(recipe[parameter] - parameter.spec.defaultValue) > 1e-9
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

    private func historyName(for parameter: ParameterID) -> String {
        let spec = parameter.spec
        let key = parameter.rawValue
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

    private func commit(_ next: EditRecipe, name: String) {
        guard next != recipe else { return }
        recipe = next
        recordHistory(name)
        requestRender()
        scheduleSave()
    }

    private func recordHistory(_ name: String) {
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

    #if DEBUG
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
            default:
                let parameter = ParameterID(rawValue: key) ?? ParameterID.allCases.first { key == "\($0)" }
                if let parameter, let number = Double(value) {
                    setValue(parameter, number)
                }
            }
        }
    #endif

    // MARK: - Persistence

    private func scheduleSave() {
        saveTask?.cancel()
        saveTask = Task {
            try? await Task.sleep(for: .milliseconds(600))
            guard !Task.isCancelled else { return }
            saveNow()
        }
    }

    public func saveNow() {
        saveTask?.cancel()
        guard let url = selection, info != nil else { return }
        let sidecar = Sidecar(recipe: recipe, snapshots: snapshots)
        let pristine = recipe.isPristine && snapshots.isEmpty
        let store = sidecars
        Task.detached(priority: .utility) {
            if pristine {
                store.delete(for: url)
            } else {
                try? store.save(sidecar, for: url)
            }
        }
        if let index = items.firstIndex(where: { $0.url == url }) {
            items[index].hasEdits = !pristine
        }
    }
}
