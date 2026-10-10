#if DEBUG || REDLAMP_PROFILING
    import AppKit
    import Foundation
    import RedlampEngine
    import RedlampEngineAPI
    import RedlampLibrary
    import RedlampServices
    @_spi(Harness) import RedlampUI

    @MainActor
    extension DebugLibraryPerformance {
        /// What one relaunch showed of the edited photos whose renders were stored before it (LIB-17).
        struct Relaunched {
            /// Whether the folder opened at once, as a launch restores it, or once the library had opened.
            var atOnce = true
            /// From the launch: the library open, the folder's photos shown, the photos shown from the library, the
            /// first thumbnail of a rendered photo on the grid's first screen, and every rendered photo there showing
            /// its render; nil for what didn't come.
            var ready: Duration?
            var shown: Duration?
            var fromLibrary: Duration?
            var firstThumbnail: Duration?
            var renders: Duration?
            /// The rendered photos on the first screen, and those that showed their embedded preview before their
            /// render.
            var onScreen = 0
            var embeddedFirst = 0
            /// Scrolling the grid end to end: the rendered photos seen with their thumbnails, and those seen showing
            /// their embedded preview.
            var scrolled = 0
            var scrolledEmbedded = 0
        }

        /// Edited photos' renders after a relaunch (LIB-17): every edited photo of the fixture rendered and stored
        /// with the grid shown, then, `count` times, the library closed as quitting does and opened again in a new
        /// editor with the grid in a window, and the folder holding the most rendered photos opened in it: at once, as
        /// a launch restores its folder before the library is open, or once the library is open, by turns. For each:
        /// how long after the launch every photo on the grid's first screen whose render is stored shows it rather
        /// than its embedded preview, how many showed their embedded preview first, and, scrolling the grid end to
        /// end in 8 s, how many such photos were seen showing their embedded preview.
        static func relaunch(_ session: inout Session, count: Int = 4) async {
            phase("rendering every edit before relaunching")
            let renders = session.model.editRenders
            renders.makeEngine = { try? RedlampEngine(decoder: DecodeServiceClient(), lensProfiles: .user) }
            let edited = session.model.items.filter(renders.renders)
            await renders.renderAgain()
            renders.isRunning = true
            let window = NSWindow(
                contentRect: CGRect(x: 0, y: 0, width: 1100, height: 800), styleMask: [.borderless],
                backing: .buffered, defer: false,
            )
            window.contentView = LibraryGridViews.make(model: session.model)
            window.orderBack(nil)
            let rendering = ContinuousClock.now
            var stored = Set<String>()
            while ContinuousClock.now - rendering < .seconds(900) {
                let states = edited.map { item in session.library.item(for: item.url).flatMap(renders.isRendered) }
                if !states.contains(where: { $0 == nil }) {
                    stored = Set(zip(edited, states).compactMap { $1 == true ? $0.url.path : nil })
                    break
                }
                try? await Task.sleep(for: .milliseconds(100))
            }
            renders.isRunning = false
            renders.letEngineGo()
            let byFolder = Dictionary(grouping: stored) { ($0 as NSString).deletingLastPathComponent }
            let folder = byFolder.max { $0.value.count < $1.value.count }
                .map { URL(fileURLWithPath: $0.key, isDirectory: true) } ?? session.fixture
            session.lines.append(String(
                format: "Relaunching with the edits rendered: %d of the %d edited photos rendered and stored in %.1f s; "
                    + "%@ opened, which holds %d of them",
                stored.count, edited.count, seconds(ContinuousClock.now - rendering), folder.lastPathComponent,
                byFolder[folder.path]?.count ?? 0,
            ))

            var runs: [Relaunched] = []
            for number in 1 ... count {
                window.contentView = nil
                session.service.close()
                phase("relaunch \(number)")
                try? await Task.sleep(for: .milliseconds(500))
                let library = FolderLibrary()
                library.add([session.fixture])
                let loader = ThumbnailLoader(packs: session.packs) { [engine = session.engine] url, size in
                    engine.decodeThumbnail(for: url, maxPixelSize: size)
                }
                let service = LibraryService(
                    paths: session.paths, sidecars: library.sidecars, thumbnail: session.thumbnail,
                )
                var run = Relaunched(atOnce: number % 2 == 1)
                let launched = ContinuousClock.now
                library.attach(service)
                let model = EditorModel(engine: session.engine, library: library, thumbnailLoader: loader)
                let grid = LibraryGridViews.make(model: model)
                window.contentView = grid
                library.setIncludesSubfolders(true)
                if !run.atOnce {
                    while await !service.canShow(folder, includingSubfolders: true),
                          ContinuousClock.now - launched < .seconds(30) {
                        try? await Task.sleep(for: .milliseconds(1))
                    }
                }
                library.open(folder)
                var first: [String: Bool] = [:]
                while ContinuousClock.now - launched < .seconds(30) {
                    let now = ContinuousClock.now - launched
                    if run.ready == nil, service.isReady {
                        run.ready = now
                    }
                    if run.shown == nil, library.count > 0 {
                        run.shown = now
                    }
                    if run.fromLibrary == nil, library.isShownFromLibrary, library.count > 0,
                       let item = library.items.row(0), library.storeThumbnail(for: item) != nil {
                        run.fromLibrary = now
                    }
                    let shown = LibraryGridViews.edits(in: grid).filter { stored.contains($0.key) }
                    for (path, state) in shown where state.image && first[path] == nil {
                        first[path] = state.render
                        run.firstThumbnail = run.firstThumbnail ?? now
                    }
                    if run.fromLibrary != nil, !shown.isEmpty, shown.values.allSatisfy(\.render) {
                        run.renders = now
                        run.onScreen = shown.count
                        run.embeddedFirst = shown.keys.count { first[$0] == false }
                        break
                    }
                    try? await Task.sleep(for: .milliseconds(1))
                }
                var seen: Set<String> = []
                var embedded: Set<String> = []
                let duration = 8.0
                let scrolling = CFAbsoluteTimeGetCurrent()
                while CFAbsoluteTimeGetCurrent() - scrolling < duration {
                    LibraryGridViews.scroll(grid, to: (CFAbsoluteTimeGetCurrent() - scrolling) / duration)
                    try? await Task.sleep(for: .microseconds(8333))
                    for (path, state) in LibraryGridViews.edits(in: grid) where stored.contains(path) && state.image {
                        seen.insert(path)
                        if !state.render {
                            embedded.insert(path)
                        }
                    }
                }
                (run.scrolled, run.scrolledEmbedded) = (seen.count, embedded.count)
                runs.append(run)
                session.lines.append(relaunched(number, run))
                session.model = model
                session.library = library
                session.loader = loader
                session.service = service
            }
            window.contentView = nil
            window.orderOut(nil)
            session.measured.relaunchRenders = runs.map { $0.renders.map { seconds($0) * 1000 } ?? .infinity }
        }

        private static func relaunched(_ number: Int, _ run: Relaunched) -> String {
            let at = { (duration: Duration?) in duration.map(ms) ?? "never" }
            return "Relaunch \(number), the folder opened \(run.atOnce ? "at once" : "once the library was open"): "
                + "the library open at \(at(run.ready)), the photos shown at \(at(run.shown)), from the library at "
                + "\(at(run.fromLibrary)); the first thumbnail of a rendered photo at \(at(run.firstThumbnail)), and "
                + "all \(run.onScreen) on the first screen showing their renders at \(at(run.renders)), "
                + "\(run.embeddedFirst) of them after their embedded preview; scrolling the grid end to end in 8 s, "
                + "\(run.scrolledEmbedded) of the \(run.scrolled) rendered photos seen showed their embedded preview"
        }
    }
#endif
