#if DEBUG || REDLAMP_PROFILING
    import CoreFoundation
    import Observation

    /// The menu bar's rebuilds, for the regression suite's measurements: how many times SwiftUI asked for the menus'
    /// body, and each one's time from the body's start to the end of the main run loop's turn it was in, which holds
    /// what SwiftUI did with the items after it; and each time `MenuBarState` ran the menus' checks again. Changing
    /// `tick` rebuilds the menus, to time a rebuild by itself.
    @_spi(Harness) @MainActor @Observable public final class MenuBarProbe {
        public static let shared = MenuBarProbe()

        public var tick = 0
        @ObservationIgnored public private(set) var rebuilds = 0
        /// Milliseconds, one per turn holding a rebuild: to the turn's end, and of the bodies alone.
        @ObservationIgnored public private(set) var turns: [Double] = []
        @ObservationIgnored public private(set) var bodies: [Double] = []
        /// Milliseconds, one per run of the menus' checks.
        @ObservationIgnored public private(set) var refreshes: [Double] = []
        /// Milliseconds, one per ⌘ key whose item was brought up to date before AppKit looked for it.
        @ObservationIgnored public private(set) var keys: [Double] = []
        @ObservationIgnored private var started: CFAbsoluteTime?
        @ObservationIgnored private var observer: CFRunLoopObserver?

        /// The menus' body starts: returns when, for `built(since:)`.
        public func rebuilding() -> CFAbsoluteTime {
            _ = tick
            rebuilds += 1
            let now = CFAbsoluteTimeGetCurrent()
            if started == nil {
                started = now
            }
            if observer == nil {
                // Last of the turn's observers, after Core Animation's commit.
                let observer = CFRunLoopObserverCreateWithHandler(
                    nil, CFRunLoopActivity.beforeWaiting.rawValue | CFRunLoopActivity.exit.rawValue, true, CFIndex.max,
                ) { [weak self] _, _ in
                    MainActor.assumeIsolated { self?.turnEnded() }
                }
                CFRunLoopAddObserver(CFRunLoopGetMain(), observer, .commonModes)
                self.observer = observer
            }
            return now
        }

        public func built(since start: CFAbsoluteTime) {
            bodies.append((CFAbsoluteTimeGetCurrent() - start) * 1000)
        }

        func refreshed(since start: CFAbsoluteTime) {
            refreshes.append((CFAbsoluteTimeGetCurrent() - start) * 1000)
        }

        func readiedKey(since start: CFAbsoluteTime) {
            keys.append((CFAbsoluteTimeGetCurrent() - start) * 1000)
        }

        /// Starts or ends a dialog on `model` as a sheet does, holding the editor's actions, without the sheet.
        public func holdDialog(_ open: Bool, on model: EditorModel) {
            model.isModalDialogOpen = open
        }

        private func turnEnded() {
            guard let started else { return }
            turns.append((CFAbsoluteTimeGetCurrent() - started) * 1000)
            self.started = nil
        }
    }
#endif
