import AppKit
import QuartzCore

/// Where a mouse-wheel zoom is heading; a display link eases the scale towards it.
struct WheelZoom {
    var target: Double?
    var anchor = CGPoint.zero
    var link: CADisplayLink?
    var lastTick: CFTimeInterval?
}

extension CanvasMetalView {
    /// A mouse wheel zooms around the pointer; trackpad scrolling pans (pinch zooms). With ⌘ held,
    /// scrolling goes to `onCommandScroll` first (the active brush's size).
    override public func scrollWheel(with event: NSEvent) {
        guard interactive else { return }
        handleScroll(event)
    }

    /// How far a scroll event turns, in wheel notches: positive when rolled away from you or
    /// swiped up, whatever the natural-scrolling setting. A trackpad's ten points make a notch.
    public static func notches(of event: NSEvent) -> Double {
        let delta = Double(event.isDirectionInvertedFromDevice ? -event.scrollingDeltaY : event.scrollingDeltaY)
        return event.hasPreciseScrollingDeltas ? delta / 10 : min(max(delta, -4), 4)
    }

    func handleScroll(_ event: NSEvent) {
        if event.modifierFlags.contains(.command), let onCommandScroll,
           onCommandScroll(Self.notches(of: event), event.modifierFlags.contains(.shift)) {
            return
        }
        if event.hasPreciseScrollingDeltas {
            guard controller.isZoomedIn else { return }
            controller.pan(byPoints: CGSize(width: event.scrollingDeltaX, height: event.scrollingDeltaY))
            return
        }
        let notches = Self.notches(of: event)
        guard notches != 0 else { return }
        let from = wheelZoom.target ?? controller.pixelScale
        // Four notches double or halve the zoom.
        wheelZoom.target = controller.clampedScale(from * pow(2, notches / 4))
        wheelZoom.anchor = convert(event.locationInWindow, from: nil)
        if wheelZoom.link == nil {
            let link = displayLink(target: self, selector: #selector(stepWheelZoom))
            link.add(to: .main, forMode: .common)
            wheelZoom.link = link
            wheelZoom.lastTick = nil
        }
    }

    @objc private func stepWheelZoom(_ link: CADisplayLink) {
        guard let target = wheelZoom.target else {
            stopWheelZoom()
            return
        }
        let elapsed = wheelZoom.lastTick.map { link.timestamp - $0 } ?? 1.0 / 120
        wheelZoom.lastTick = link.timestamp
        let current = controller.pixelScale
        // Eases in log space, so each notch feels the same at any zoom level.
        let remaining = log(target / current)
        let done = abs(remaining) < 0.002
        let scale = done ? target : current * exp(remaining * (1 - exp(-elapsed / 0.06)))
        controller.zoom(toScale: scale, anchoredAt: wheelZoom.anchor)
        setNeedsRedraw()
        // Also stops if the target became unreachable (the window resized mid-zoom).
        if done || controller.pixelScale == current {
            stopWheelZoom()
        }
    }

    func stopWheelZoom() {
        wheelZoom.link?.invalidate()
        wheelZoom = WheelZoom()
    }
}
