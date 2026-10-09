#if DEBUG || REDLAMP_PROFILING
    import AppKit

    /// Keeps the keyboard of the person at the Mac out of a run, so a scenario performs only what it sends. A run in
    /// the background never takes the focus, but a menu it opens takes the keyboard while it tracks, as any app's
    /// menu does: what's typed in another app meanwhile reaches the test app, and what the menu doesn't take, its
    /// single-key shortcuts would act on once it closes (a Flag as Pick and a Cycle Lights Out that no scenario sent).
    /// The driver's keys are made in the app's own process; any other key is dropped before the app's handlers see it,
    /// and the run's events name it.
    @MainActor
    enum ForeignInput {
        private static var monitor: Any?

        /// Watches the keys the app dispatches from now on. The app's own key handlers are installed first, and local
        /// monitors run newest first, so this one runs before them.
        static func keepOut(recording recorder: Recorder) {
            guard monitor == nil else { return }
            monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .keyUp, .flagsChanged]) { event in
                guard isForeign(event) else { return event }
                var fields: [String: Any] = ["type": "\(event.type)", "keyCode": Int(event.keyCode)]
                if event.type != .flagsChanged {
                    fields["characters"] = event.charactersIgnoringModifiers ?? ""
                }
                recorder.write("foreign-input", fields)
                return nil
            }
        }

        static func letIn() {
            monitor.map(NSEvent.removeMonitor)
            monitor = nil
        }

        /// Whether `event` came from outside the app's process: the person's keyboard, or another app.
        nonisolated static func isForeign(_ event: NSEvent) -> Bool {
            guard let source = event.cgEvent?.getIntegerValueField(.eventSourceUnixProcessID) else { return false }
            return source != Int64(ProcessInfo.processInfo.processIdentifier)
        }
    }
#endif
