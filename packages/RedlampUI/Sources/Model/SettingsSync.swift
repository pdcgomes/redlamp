import Foundation
import Observation
import RedlampDocument
import RedlampEngineAPI

/// Changes photos that aren't open, one at a time in the background: Sync Settings, Paste onto a
/// selection, Update AI Masks across it (`docs/plans/2026-10-02-copy-paste-sync-design.md`).
///
/// For each photo it reads the sidecar, pastes, recomputes the AI masks the paste brought (and an
/// Auto white balance) in an engine of its own, so the open photo is never disturbed, and saves
/// with a history step. A photo whose sidecar a newer Redlamp wrote, or this version can't read,
/// is left alone. Undo puts back what the last batch changed, on every photo not edited since.
@MainActor
@Observable
public final class SettingsSync {
    public enum Change {
        /// `selection` of `source`, pasted.
        case paste(EditRecipe, SettingsSelection)
        /// Every AI mask computed again with today's models.
        case updateAIMasks
        /// Each photo's sensor dust (found across the selection) healed, a source found for each speck.
        case healDust([URL: [DetectedSpot]])
    }

    public struct Progress: Equatable, Sendable {
        public var title: String
        public var done: Int
        public var total: Int
    }

    public private(set) var progress: Progress?
    /// Auto Sync: each step on the open photo repeats on the rest of the selection.
    public var isAutoSyncing = false
    /// How the last batch went, when there is something to say ("1 photo was left alone…").
    public private(set) var report: String?
    public var canUndo: Bool {
        !written.isEmpty && progress == nil
    }

    /// An engine for photos that aren't open; nil leaves AI masks and Auto white balance as pasted.
    @ObservationIgnored var makeEngine: () -> (any EditingEngine)?
    @ObservationIgnored let store: SidecarStore
    @ObservationIgnored private var task: Task<Void, Never>?
    /// The last batch: each photo's edit before (nil: it had no sidecar) and after.
    @ObservationIgnored private var before: [URL: EditRecipe?] = [:]
    @ObservationIgnored private var written: [URL: EditRecipe] = [:]
    @ObservationIgnored private var title = ""
    /// Auto Sync's steps that came while a batch ran: gathered, and run after it.
    @ObservationIgnored private var pending: (
        source: EditRecipe, selection: SettingsSelection, photos: [URL], done: (URL, EditRecipe) -> Void,
    )?

    init(store: SidecarStore = SidecarStore(), makeEngine: @escaping () -> (any EditingEngine)?) {
        self.store = store
        self.makeEngine = makeEngine
    }

    /// Starts `change` on `photos`, recorded in each one's history as `title`; `done` is told of
    /// each photo written.
    func run(_ change: Change, on photos: [URL], title: String, done: @escaping (URL, EditRecipe) -> Void) {
        guard progress == nil, !photos.isEmpty else { return }
        progress = Progress(title: title, done: 0, total: photos.count)
        self.title = title
        report = nil
        before = [:]
        written = [:]
        task = Task { [weak self] in
            await self?.process(change, photos, title: title, done: done)
        }
    }

    public func cancel() {
        pending = nil
        task?.cancel()
    }

    /// One Auto Sync step: what it changed of `source`, onto `photos`; gathered with the steps
    /// before it while a batch runs.
    func autoSync(
        _ source: EditRecipe, _ changes: SettingsSelection, on photos: [URL], done: @escaping (URL, EditRecipe) -> Void,
    ) {
        guard !changes.isEmpty, !photos.isEmpty else { return }
        if progress == nil {
            run(.paste(source, changes), on: photos, title: "Auto Sync", done: done)
        } else {
            let gathered = pending.map { $0.selection.union(changes) } ?? changes
            pending = (source, gathered, photos, done)
        }
    }

    /// Waits for the batch running, if any.
    func idle() async {
        await task?.value
    }

    /// Puts back every photo of the last batch not edited since.
    func undo(done: @escaping (URL, EditRecipe) -> Void) {
        guard canUndo else { return }
        for (url, after) in written {
            guard store.load(for: url)?.recipe == after, let previous = before[url] else { continue }
            if let previous {
                record(previous, from: after, for: url, title: "Undo \(title)", action: .paste)
                done(url, previous)
            } else {
                store.delete(for: url)
                done(url, EditRecipe())
            }
        }
        written = [:]
        before = [:]
        report = nil
    }

    private func process(
        _ change: Change, _ photos: [URL], title: String, done: @escaping (URL, EditRecipe) -> Void,
    ) async {
        var engine: (any EditingEngine)?
        var skipped = 0
        var failedMasks = 0
        for url in photos {
            guard !Task.isCancelled else { break }
            defer { progress?.done += 1 }
            guard store.protection(for: url) == nil else {
                skipped += 1
                continue
            }
            let existing = store.load(for: url)
            let original = existing?.recipe ?? EditRecipe()
            var next = original
            var masks: Set<UUID>?
            var autoWhiteBalance = false
            switch change {
            case let .paste(source, selection):
                next = original.pasting(source, selection)
                masks = EditRecipe.pastedMasks(from: source, selection)
                if selection.items.contains("whiteBalance") {
                    // As Shot is the photo's own, read when it opens; Auto is measured for it.
                    if next.whiteBalanceMode == .asShot {
                        next.reset([.temperature, .tint])
                    }
                    autoWhiteBalance = next.whiteBalanceMode == .auto
                }
            case .updateAIMasks:
                masks = nil
            case let .healDust(found):
                masks = []
                let specks = found[url] ?? []
                guard !specks.isEmpty else { continue }
                engine = engine ?? makeEngine()
                var opened = false
                if let engine {
                    opened = await (try? engine.open(url)) != nil
                }
                for speck in specks {
                    var spot = RetouchSpot(center: speck.center, source: speck.center, radius: speck.radius)
                    let found = opened ? await engine?.retouchSource(for: spot, recipe: original) : nil
                    spot.source = found ?? ImagePoint(x: min(speck.center.x + speck.radius * 2.5, 1), y: speck.center.y)
                    next.spots.append(spot)
                }
            }
            let needsMasks = next.masks.contains { layer in
                (masks?.contains(layer.id) ?? true) && layer.components.contains { $0.shape.isAIRaster }
            }
            if needsMasks || autoWhiteBalance {
                engine = engine ?? makeEngine()
                if let engine, await (try? engine.open(url)) != nil {
                    if autoWhiteBalance, let wb = await engine.autoWhiteBalance() {
                        next[.temperature] = wb.temperature
                        next[.tint] = wb.tint
                    }
                    if needsMasks {
                        let (recomputed, failed) = await EditorModel.recomputingAIMasks(next, in: masks, engine: engine)
                        next = recomputed
                        failedMasks += failed
                    }
                }
            }
            guard next != original else { continue }
            var sidecar = existing ?? Sidecar(recipe: next)
            sidecar.recipe = next
            sidecar.modified = Date()
            sidecar.session = HistorySession(steps: [
                HistoryStep(action: .open, title: existing == nil ? "Import" : "Opened", recipe: original),
                HistoryStep(action: change.action, title: title, recipe: next),
            ])
            guard (try? store.save(sidecar, for: url)) != nil else { continue }
            // updateValue: a photo without a sidecar keeps its nil (a subscript would drop the key).
            before.updateValue(existing?.recipe, forKey: url)
            // As read back, so Undo can tell the photo hasn't been edited since (dates round).
            written[url] = store.load(for: url)?.recipe ?? next
            done(url, next)
        }
        report = Self.report(skipped: skipped, failedMasks: failedMasks, cancelled: Task.isCancelled)
        progress = nil
        if let next = pending {
            pending = nil
            run(.paste(next.source, next.selection), on: next.photos, title: "Auto Sync", done: next.done)
            await task?.value
        }
    }

    /// A history session for a change made without opening the photo.
    private func record(
        _ recipe: EditRecipe,
        from current: EditRecipe,
        for url: URL,
        title: String,
        action: HistoryAction,
    ) {
        guard var sidecar = store.load(for: url) else { return }
        sidecar.recipe = recipe
        sidecar.modified = Date()
        sidecar.session = HistorySession(steps: [
            HistoryStep(action: .open, title: "Opened", recipe: current),
            HistoryStep(action: action, title: title, recipe: recipe),
        ])
        try? store.save(sidecar, for: url)
    }

    private static func report(skipped: Int, failedMasks: Int, cancelled: Bool) -> String? {
        var parts: [String] = []
        if cancelled {
            parts.append("Stopped before the end.")
        }
        if skipped > 0 {
            let photos = "\(skipped) photo\(skipped == 1 ? " was" : "s were")"
            parts.append("\(photos) left alone: edited by a newer Redlamp, or the edit can't be read.")
        }
        if failedMasks > 0 {
            parts.append("\(failedMasks) AI mask\(failedMasks == 1 ? "" : "s") couldn't be computed for its photo.")
        }
        return parts.isEmpty ? nil : parts.joined(separator: " ")
    }
}

private extension SettingsSync.Change {
    var action: HistoryAction {
        switch self {
        case .paste: .paste
        case .updateAIMasks: .mask(nil)
        case .healDust: .retouch
        }
    }
}

extension MaskShape {
    /// A bitmap an AI model computed for one photo (Depth Range's depth map too).
    var isAIRaster: Bool {
        switch self {
        case .ai, .depthRange: true
        default: false
        }
    }
}
