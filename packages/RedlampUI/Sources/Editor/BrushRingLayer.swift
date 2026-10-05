import AppKit
import RedlampCanvas
import SwiftUI

/// A brush's ring over the photo (UX-15). It follows the pointer; while the brush's size or
/// feather changes (from `[` and `]`, ⌘-scroll or the inspector's sliders) it also shows where
/// the pointer last was on the photo, or at `fallback`, with `label` beside it, until a moment
/// after the last change.
struct BrushRingLayer<Ring: View>: View {
    let pointer: CGPoint?
    let fallback: CGPoint
    /// The values whose change shows the ring: its size and feather.
    let watched: [Double]
    let label: String?
    /// The ring's outer radius, in points, to place the label under it.
    let radius: CGFloat
    @ViewBuilder let ring: () -> Ring

    @State private var last: CGPoint?
    @State private var changes = 0
    @State private var previewing = false

    var body: some View {
        ZStack {
            if let at = pointer ?? (previewing ? last ?? fallback : nil) {
                ring()
                    .position(at)
                if previewing, let label {
                    Text(label)
                        .font(.system(size: 11, weight: .medium).monospacedDigit())
                        .foregroundStyle(.white)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(Capsule().fill(Color.black.opacity(0.6)))
                        .fixedSize()
                        .position(x: at.x, y: at.y + radius + 16)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .allowsHitTesting(false)
        .onChange(of: pointer) { _, pointer in
            if let pointer {
                last = pointer
            }
        }
        .onChange(of: watched) {
            changes += 1
        }
        .task(id: changes) {
            guard changes > 0 else { return }
            previewing = true
            try? await Task.sleep(for: .seconds(1.2))
            if !Task.isCancelled {
                previewing = false
            }
        }
    }
}

/// ⌘-scroll over this view's area, for a brush drawn over a picture that isn't the canvas (the
/// Stack workspace's preview). It never takes a click.
struct CommandScrollArea: NSViewRepresentable {
    /// Notches (positive away from you), and whether Shift is held; returns whether it took the event.
    let onScroll: (Double, Bool) -> Bool

    func makeNSView(context _: Context) -> CatcherView {
        CatcherView()
    }

    func updateNSView(_ view: CatcherView, context _: Context) {
        view.onScroll = onScroll
    }

    final class CatcherView: NSView {
        var onScroll: ((Double, Bool) -> Bool)?
        private var monitor: Any?

        override func hitTest(_: NSPoint) -> NSView? {
            nil
        }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if let monitor {
                NSEvent.removeMonitor(monitor)
                self.monitor = nil
            }
            guard window != nil else { return }
            monitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
                guard let self, event.window === window, event.modifierFlags.contains(.command),
                      bounds.contains(convert(event.locationInWindow, from: nil)),
                      onScroll?(CanvasMetalView.notches(of: event), event.modifierFlags.contains(.shift)) == true
                else { return event }
                return nil
            }
        }
    }
}
