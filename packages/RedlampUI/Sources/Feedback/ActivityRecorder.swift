import Foundation
import RedlampDesign
import RedlampEngineAPI

/// Writes the editor's changes of state into its `ActivityLog`: the tool, panels and masks, the
/// messages and errors people see, exports, model downloads, slow renders, and the Mac running
/// hot or short of memory. Actions, edits and photos opening are recorded where they happen.
@MainActor
final class ActivityRecorder {
    private var trackers: [Tracker] = []
    private var thermalObserver: NSObjectProtocol?
    private var memoryPressure: DispatchSourceMemoryPressure?

    /// Renders slower than this are worth a line.
    static let slowRender = Duration.milliseconds(400)

    init(model: EditorModel) {
        let log = model.activity
        log.record(.system, "Redlamp started")

        watch(model, { $0.activeTool }) { _, tool in log.record(.tool, "Tool: \(tool.title)") }
        watch(model, { $0.expandedPanels }) { old, new in
            for panel in PanelID.allCases where new.contains(panel) != old.contains(panel) {
                log.record(.panel, "\(new.contains(panel) ? "Opened" : "Closed") the \(panel.title) panel")
            }
        }
        watch(model, { $0.showBefore ? $0.compareLayout.title : nil }) { _, layout in
            log.record(.view, layout.map { "Before / After: \($0)" } ?? "Before / After off")
        }
        watch(model, { $0.canvas.zoomPercent }) { _, percent in
            log.record(.view, "Zoom: \(percent)%", replacing: "zoom")
        }
        watch(model, { $0.selectedPhotos.count }) { _, count in
            if count > 1 {
                log.record(.view, "Selected \(count) photos", replacing: "selection")
            }
        }
        watch(model, { $0.folder != nil }) { _, open in
            if open {
                log.record(.view, "Showed a folder")
            }
        }
        watch(model, { $0.library.isListing ? nil : $0.library.count }) { _, count in
            if let count {
                log.record(.view, "The folder holds \(count) photos", replacing: "folder-count", within: 5)
            }
        }

        watch(model, { model in model.selectedMaskID.flatMap { id in model.maskOutlines.first { $0.id == id } } }) {
            old, outline in
            guard let outline else { return }
            let shape = Self.describe(outline)
            if old?.id == outline.id {
                if old?.components != outline.components {
                    log.record(.mask, "Mask “\(outline.name)” is now \(shape)")
                }
            } else {
                log.record(.mask, "Selected mask “\(outline.name)”: \(shape)")
            }
        }
        watch(model, { $0.drawingKind }) { _, kind in
            if let kind {
                log.record(.mask, "Armed: \(kind.name)")
            }
        }
        watch(model, { $0.aiMaskProgress }) { old, kind in
            if let kind {
                log.record(.mask, "Computing a \(kind.name) mask")
            } else if let old {
                log.record(.mask, "Finished computing the \(old.name) mask")
            }
        }
        watch(model, { model in model.pendingModel.map { "\($0.model.name) for \($0.kind.name)" } }) { _, request in
            if let request {
                log.record(.model, "Asked to download \(request)")
            }
        }
        watch(model, { $0.modelDownloadProgress != nil }) { _, downloading in
            log.record(.model, downloading ? "Model download started" : "Model download ended")
        }
        watch(model, { $0.activeTool == .heal ? $0.spotMode.name : nil }) { _, mode in
            if let mode {
                log.record(.tool, "Healing mode: \(mode)")
            }
        }
        watch(model, { $0.activeTool == .heal ? $0.spotPick.name : nil }) { _, pick in
            if let pick {
                log.record(.tool, "Click picks: \(pick)")
            }
        }
        watch(model, { $0.stackWorkspace != nil }) { _, open in
            log.record(.view, open ? "Opened the Stack workspace" : "Closed the Stack workspace")
        }

        shown(model, .error, "Couldn't open the photo") { $0.errorMessage }
        shown(model, .error, "Save failed") { $0.saveError?.message }
        shown(model, .error, "Masking said") { $0.maskMessage }
        shown(model, .error, "Stack workspace said") { $0.stackWorkspace?.errorMessage }
        shown(model, .message, "Healing said") { $0.pickMessage }
        shown(model, .message, "Remove Dust said") { $0.dustMessage }
        shown(model, .message, "Find said") { $0.findMessage }
        shown(model, .export, "Export") { $0.exportStatus }

        watch(model, { $0.lastRenderTime }) { _, duration in
            guard let duration, duration > Self.slowRender else { return }
            let ms = Int((duration / .milliseconds(1)).rounded())
            log.record(
                .system,
                "Slow render: \(ms) ms at \(model.canvas.zoomPercent)%",
                replacing: "slow-render",
                within: 10,
            )
        }

        thermalObserver = NotificationCenter.default.addObserver(
            forName: ProcessInfo.thermalStateDidChangeNotification, object: nil, queue: .main,
        ) { _ in
            let state = ProcessInfo.processInfo.thermalState
            MainActor.assumeIsolated { log.record(.system, "Thermal state: \(Self.name(state))") }
        }
        let memoryPressure = DispatchSource.makeMemoryPressureSource(eventMask: [.warning, .critical], queue: .main)
        memoryPressure.setEventHandler { [weak memoryPressure] in
            let critical = memoryPressure?.data.contains(.critical) == true
            MainActor.assumeIsolated { log.record(.system, "Memory pressure: \(critical ? "critical" : "warning")") }
        }
        memoryPressure.resume()
        self.memoryPressure = memoryPressure
    }

    isolated deinit {
        thermalObserver.map(NotificationCenter.default.removeObserver)
        memoryPressure?.cancel()
    }

    /// Calls `changed` with the old and new value whenever `read` gives a different one.
    private func watch<Value: Equatable>(
        _ model: EditorModel,
        _ read: @escaping @MainActor (EditorModel) -> Value,
        _ changed: @escaping @MainActor (_ old: Value, _ new: Value) -> Void,
    ) {
        var last: Value?
        trackers.append(Tracker { [weak model] in
            guard let model else { return }
            let value = read(model)
            if let previous = last, previous != value {
                changed(previous, value)
            }
            last = value
        })
    }

    /// Records a message each time the UI shows a new one.
    private func shown(
        _ model: EditorModel, _ kind: ActivityLog.Event.Kind, _ label: String,
        _ read: @escaping @MainActor (EditorModel) -> String?,
    ) {
        let log = model.activity
        watch(model, read) { _, message in
            if let message {
                log.record(kind, "\(label): \(message)")
            }
        }
    }

    /// "Objects, subtract Brush, inverted Sky".
    static func describe(_ outline: MaskOutline) -> String {
        outline.components.enumerated().map { index, component in
            let kind = (component.inverted ? "inverted " : "") + (component.kind?.name ?? "a newer kind")
            return index == 0 ? kind : "\(component.operation.name.lowercased()) \(kind)"
        }.joined(separator: ", ")
    }

    static func name(_ state: ProcessInfo.ThermalState) -> String {
        switch state {
        case .nominal: "nominal"
        case .fair: "fair"
        case .serious: "serious"
        case .critical: "critical"
        @unknown default: "unknown"
        }
    }
}
