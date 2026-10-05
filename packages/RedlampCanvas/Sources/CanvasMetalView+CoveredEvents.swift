import AppKit

/// Tools draw over the canvas in views that take its clicks and drags (the Masking, Healing and
/// Crop overlays). Scrolling and pinching over them still reach the canvas, so the photo zooms and
/// pans in every tool as it does with none.
extension CanvasMetalView {
    /// Whether an event at a point of the canvas is the canvas's to take, though something covers it.
    struct CoveredEvent {
        /// The event is for this canvas's window (not a popover's or another window's).
        var sameWindow: Bool
        /// It lands on the stage: the canvas minus the panels' space.
        var onStage: Bool
        /// The view it would go to is the canvas itself, which takes it the usual way.
        var hitsCanvas: Bool
        /// That view scrolls or edits text of its own (a list, a field).
        var hitsScrollingView: Bool

        var belongsToCanvas: Bool {
            sameWindow && onStage && !hitsCanvas && !hitsScrollingView
        }
    }

    func updateCoveredEventMonitor() {
        guard interactive, forwardsCoveredEvents, window != nil else {
            if let monitor = coveredEventMonitor {
                NSEvent.removeMonitor(monitor)
                coveredEventMonitor = nil
            }
            return
        }
        guard coveredEventMonitor == nil else { return }
        coveredEventMonitor = NSEvent.addLocalMonitorForEvents(matching: [
            .scrollWheel,
            .magnify,
        ]) { [weak self] event in
            guard let self, covered(event).belongsToCanvas else { return event }
            if event.type == .magnify {
                magnify(with: event)
            } else {
                handleScroll(event)
            }
            return nil
        }
    }

    private func covered(_ event: NSEvent) -> CoveredEvent {
        guard event.window === window, let content = window?.contentView else {
            return CoveredEvent(sameWindow: false, onStage: false, hitsCanvas: false, hitsScrollingView: false)
        }
        let point = convert(event.locationInWindow, from: nil)
        let hit = content
            .hitTest(content.superview?.convert(event.locationInWindow, from: nil) ?? event.locationInWindow)
        var scrolling = false
        var view = hit
        while let current = view, !scrolling {
            scrolling = current is NSScrollView || current is NSTextView
            view = current.superview
        }
        return CoveredEvent(
            sameWindow: true,
            onStage: controller.fullStage(in: bounds.size).contains(point),
            hitsCanvas: hit === self,
            hitsScrollingView: scrolling,
        )
    }
}
