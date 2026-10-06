import CoreGraphics
import Foundation
import RedlampDocument
import RedlampEngineAPI
import RedlampLibrary
import RedlampRecipes

extension EditRenders {
    /// Starts rendering the next photo that needs it, `focus`'s rows first, unless one is rendering.
    func renderNext(_ focus: [Int]) {
        guard current == nil, isRunning, makeEngine != nil else { return }
        guard let next = nextRender(focus) else {
            releaseEngineWhenIdle()
            return
        }
        idleRelease?.cancel()
        idleRelease = nil
        let task = Task { [weak self] in
            guard let self else { return }
            await render(next.item, key: next.key, store: next.store, digest: next.digest)
        }
        current = (next.item.url, task)
    }

    /// Renders `item`'s edit, whose digest was read as `digest`, and stores its tiers: the sidecar read
    /// again with its masks' bitmaps, the photo opened and its edit rendered at the preview tier's size,
    /// each step once `mayGoOn` says so, then both tiers made from that render off the main thread.
    private func render(_ item: LibraryItem, key: ContentKey, store: PhotoStore, digest: EditDigest) async {
        let url = item.url
        defer {
            current = nil
            schedulePump()
        }
        let sidecars = library.sidecars
        let loaded = try? await scheduler.run(.background) { sidecars.store(for: url).load(for: url)?.recipe }
        guard !Task.isCancelled else { return }
        guard let recipe = loaded ?? nil, EditDigest(rendering: recipe) == digest else {
            // Changed since it was read: read again.
            if known[url]?.digest == digest {
                set(url, nil)
                revisit(url)
            }
            return
        }
        guard await mayGoOn(rendering: url), let engine = await workerEngine() else { return }
        let opening = ContinuousClock.now
        stepRunning = true
        let opened = try? await engine.open(url)
        stepRunning = false
        guard !Task.isCancelled else { return }
        guard let info = opened else { return failed(url, digest) }
        statistics.opening.append(Self.seconds(.now - opening))
        engineBytes += info.pixelSize.width * info.pixelSize.height * 32 / 3
        if !engine.canRender(recipe.baseLook), let look = editor?.recipes.library.definition(for: recipe.baseLook) {
            engine.registerBaseLook(look)
        }
        var request = StillRequest(
            recipe: EditorModel.asShot(recipe, info), maxLongEdge: PhotoStore.Tier.preview.pixelSize,
            colorSpace: .displayP3, purpose: .preview,
        )
        request.source = url
        guard await mayGoOn(rendering: url) else { return }
        let rendering = ContinuousClock.now
        stepRunning = true
        let rendered = try? await engine.renderStill(request)
        stepRunning = false
        if engineBytes > Self.engineBudget {
            self.engine = nil
            engineBytes = 0
        }
        guard !Task.isCancelled else { return }
        guard let image = rendered else { return failed(url, digest) }
        statistics.rendering.append(Self.seconds(.now - rendering))
        let storing = ContinuousClock.now
        let keeping = claims(of: key, except: url).union([digest])
        let (size, modified) = (item.size, item.modified)
        let stored = try? await scheduler.run(.background) {
            Self.store(image, key: key, edit: digest, size: size, modified: modified, in: store, keeping: keeping)
        }
        guard !Task.isCancelled, let stored else { return }
        guard stored else { return failed(url, digest) }
        statistics.storing.append(Self.seconds(.now - storing))
        statistics.rendered += 1
        guard var entry = known[url], entry.digest == digest, entry.state == .unrendered else { return }
        entry.state = .rendered
        set(url, entry)
        notify([url])
    }

    private func failed(_ url: URL, _ digest: EditDigest) {
        statistics.failed += 1
        guard var entry = known[url], entry.digest == digest else { return }
        entry.state = .failed
        set(url, entry)
    }

    /// Both tiers of `image`, a render of `edit`, stored for the photo `key` names, as its file was
    /// (`size` bytes, modified at `modified`); then its renders of edits other than `keeping`'s go.
    nonisolated static func store(
        _ image: CGImage, key: ContentKey, edit: EditDigest, size: Int64, modified: Date, in store: PhotoStore,
        keeping: Set<EditDigest>,
    ) -> Bool {
        let encoder = StoreImageEncoder()
        guard let grid = encoder.encode(image, for: .grid), let preview = encoder.encode(image, for: .preview),
              store.store(grid, for: key, tier: .grid, edit: edit, size: size, modified: modified),
              store.store(preview, for: key, tier: .preview, edit: edit, size: size, modified: modified)
        else { return false }
        store.removeEdits(of: key, keeping: keeping)
        return true
    }

    // MARK: - Keeping out of Develop's way

    /// Waits until a render's next step may run: Develop isn't shown, or it has asked for no frame for
    /// `developQuiet` and isn't opening a photo; no thumbnail on screen waits; the Mac isn't hot or saving
    /// power; and renders aren't paused. False when the render is to stop instead: it was cancelled, or
    /// its photo opened in Develop.
    private func mayGoOn(rendering url: URL) async -> Bool {
        let started = ContinuousClock.now
        var waited = false
        defer {
            if waited {
                statistics.waits += 1
                statistics.waited += .now - started
            }
        }
        while !Task.isCancelled, !isOpenInDevelop(url) {
            if isRunning, isDevelopQuiet, scheduler.load().waiting[.onScreen, default: 0] == 0,
               WorkScheduler.isRelaxed() {
                return true
            }
            waited = true
            try? await Task.sleep(for: .milliseconds(50))
        }
        return false
    }

    private var isDevelopQuiet: Bool {
        guard let editor, editor.module == .develop else { return true }
        return !editor.isLoading && developActive.map { .now - $0 >= Self.developQuiet } ?? true
    }

    // MARK: - The engine

    /// The engine renders are made in, made off the main thread when there's none.
    private func workerEngine() async -> (any EditingEngine)? {
        if let engine {
            return engine
        }
        guard let makeEngine else { return nil }
        let made = await Task.detached(priority: .utility) { makeEngine() }.value
        engine = made
        return made
    }

    /// Lets the engine go after `engineIdle` with nothing to render.
    private func releaseEngineWhenIdle() {
        guard engine != nil, idleRelease == nil else { return }
        idleRelease = Task { [weak self] in
            try? await Task.sleep(for: Self.engineIdle)
            guard let self, !Task.isCancelled, current == nil else { return }
            engine = nil
            engineBytes = 0
            idleRelease = nil
        }
    }

    nonisolated static func seconds(_ duration: Duration) -> Double {
        Double(duration.components.seconds) + Double(duration.components.attoseconds) / 1e18
    }
}
