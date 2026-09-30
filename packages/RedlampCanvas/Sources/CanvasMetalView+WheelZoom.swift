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
    /// A mouse wheel zooms around the pointer; trackpad scrolling pans (pinch zooms).
    override public func scrollWheel(with event: NSEvent) {
        guard interactive else { return }
        if event.hasPreciseScrollingDeltas {
            guard controller.isZoomedIn else { return }
            controller.pan(byPoints: CGSize(width: event.scrollingDeltaX, height: event.scrollingDeltaY))
            return
        }
        // Wheel rolled away from you zooms in, whatever the natural-scrolling setting.
        let notches = Double(event.isDirectionInvertedFromDevice ? -event.scrollingDeltaY : event.scrollingDeltaY)
        guard notches != 0 else { return }
        let from = wheelZoom.target ?? controller.pixelScale
        // Four notches double or halve the zoom.
        wheelZoom.target = controller.clampedScale(from * pow(2, min(max(notches, -4), 4) / 4))
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
