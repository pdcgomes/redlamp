#if DEBUG || REDLAMP_PROFILING
    import AppKit
    import ObjectiveC

    /// Keeps the keyboard and the trackpad of the person at the Mac out of a run, so a scenario performs only what it
    /// sends. A run in the background never takes the focus, but a menu it opens takes the keyboard while it tracks, as
    /// any app's menu does: what's typed in another app meanwhile reaches the test app, and what the menu doesn't take,
    /// its single-key shortcuts would act on once it closes (a Flag as Pick and a Cycle Lights Out that no scenario
    /// sent). Scrolling and pinching over its window reach it, active or not. The driver's events are made in the app's
    /// own process; any other key, scroll or gesture is dropped before the app's handlers see it, and the run's events
    /// name it.
    @MainActor
    enum ForeignInput {
        private static var recorder: Recorder?
        private static var installed = false

        /// What acts without a click, by the name the run's events give it: keys, and the wheel's and the trackpad's
        /// scrolls and gestures.
        private static let kept: [NSEvent.EventType: String] = [
            .keyDown: "keyDown", .keyUp: "keyUp", .flagsChanged: "flagsChanged", .scrollWheel: "scrollWheel",
            .magnify: "magnify", .smartMagnify: "smartMagnify", .rotate: "rotate", .swipe: "swipe",
        ]

        /// Drops foreign input from now on. AppKit calls an app's local monitors in no fixed order, so a monitor of its
        /// own would keep events from only some of the others: the filter is in `NSApplication.sendEvent(_:)`, which
        /// calls the monitors, then looks for a key equivalent in the menus, then hands the event to its window.
        static func keepOut(recording recorder: Recorder) {
            self.recorder = recorder
            let selector = #selector(NSApplication.sendEvent(_:))
            guard !installed, let method = class_getInstanceMethod(NSApplication.self, selector) else { return }
            installed = true
            typealias SendEvent = @convention(c) (NSApplication, Selector, NSEvent) -> Void
            let send = unsafeBitCast(method_getImplementation(method), to: SendEvent.self)
            let filtered: @convention(block) (NSApplication, NSEvent) -> Void = { application, event in
                guard !MainActor.assumeIsolated({ drops(event) }) else { return }
                send(application, selector, event)
            }
            method_setImplementation(method, imp_implementationWithBlock(filtered))
        }

        static func letIn() {
            recorder = nil
        }

        /// Whether `event` is foreign input to drop, which the run's events then name.
        private static func drops(_ event: NSEvent) -> Bool {
            guard let recorder, let type = kept[event.type], isForeign(event) else { return false }
            var fields: [String: Any] = ["type": type]
            if [.keyDown, .keyUp, .flagsChanged].contains(event.type) {
                fields["keyCode"] = Int(event.keyCode)
            }
            if [.keyDown, .keyUp].contains(event.type) {
                fields["characters"] = event.charactersIgnoringModifiers ?? ""
            }
            recorder.write("foreign-input", fields)
            return true
        }

        /// Whether `event` came from outside the app's process: the person's keyboard or trackpad, or another app.
        nonisolated static func isForeign(_ event: NSEvent) -> Bool {
            guard let source = event.cgEvent?.getIntegerValueField(.eventSourceUnixProcessID) else { return false }
            return source != Int64(ProcessInfo.processInfo.processIdentifier)
        }
    }
#endif
