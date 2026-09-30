import AppKit
import RedlampEngineAPI
import SwiftUI

/// Hands engine frames straight to the Metal views showing them. A new frame redraws the
/// canvas without re-evaluating any SwiftUI view, so rendering at display rate costs the
/// main thread one draw call rather than a view-graph update.
@MainActor
public final class FrameFeed {
    public private(set) var current: RenderedFrame?
    private let views = NSHashTable<CanvasMetalView>.weakObjects()
    private var waiters: [CheckedContinuation<RenderedFrame, Never>] = []

    public init() {}

    public func show(_ frame: RenderedFrame?) {
        current = frame
        for view in views.allObjects {
            view.display(frame)
        }
        if let frame {
            let resumed = waiters
            waiters.removeAll()
            for waiter in resumed {
                waiter.resume(returning: frame)
            }
        }
    }

    /// The next frame shown (for diagnostics that time frame arrival).
    public func nextFrame() async -> RenderedFrame {
        await withCheckedContinuation { waiters.append($0) }
    }

    /// A canvas showing this feed's frames, for AppKit layouts (SwiftUI uses `CanvasView`).
    public func makeView(controller: CanvasController, interactive: Bool = true) -> CanvasMetalView {
        let view = CanvasMetalView(controller: controller)
        view.interactive = interactive
        view.clickAction = interactive ? .zoom : .none
        attach(view)
        return view
    }

    func attach(_ view: CanvasMetalView) {
        views.add(view)
        view.display(current)
    }
}

/// Displays engine frames. The frame's IOSurface is sampled directly — no pixel copies.
public struct CanvasView: NSViewRepresentable {
    public enum ClickAction {
        case zoom
        case sample
        case none
    }

    let feed: FrameFeed
    let controller: CanvasController
    let revision: Int
    let clickAction: ClickAction
    let interactive: Bool
    /// Linear grey level around the photo (Lightroom's Lights Out dims it to black).
    let surround: Double
    /// A white frame around the photo, as a fraction of its shorter side (0 for none).
    let whiteFrame: Double
    let onSample: (CGPoint) -> Void

    public init(
        feed: FrameFeed,
        controller: CanvasController,
        clickAction: ClickAction = .zoom,
        interactive: Bool = true,
        surround: Double = CanvasMetalView.defaultSurround,
        whiteFrame: Double = 0,
        onSample: @escaping (CGPoint) -> Void = { _ in },
    ) {
        self.surround = surround
        self.whiteFrame = whiteFrame
        self.feed = feed
        self.controller = controller
        revision = controller.revision
        self.clickAction = clickAction
        self.interactive = interactive
        self.onSample = onSample
    }

    public func makeNSView(context _: Context) -> CanvasMetalView {
        let view = CanvasMetalView(controller: controller)
        feed.attach(view)
        return view
    }

    /// Runs only when the view's inputs change (geometry revision, tool, surround); new
    /// frames arrive through the feed.
    public func updateNSView(_ view: CanvasMetalView, context _: Context) {
        view.clickAction = clickAction
        view.interactive = interactive
        view.surround = surround
        view.whiteFrame = whiteFrame
        view.onSample = onSample
        view.setNeedsRedraw()
    }
}
