import AppKit
import RedlampDesign
import Testing

/// What a layer-drawn view tells the profiling build's draw counter (RESP-11).
@MainActor
struct DrawObserverTests {
    private final class Probe: LayerDrawnView {
        override func drawContent(in _: CGRect) {}
    }

    private final class Events {
        var drew = 0
        var sizes: [CGSize] = []
    }

    @Test func `a layer-drawn view tells the draw observer of each draw and each new size`() throws {
        let events = Events()
        LayerDrawnView.drawObserver = { _, event in
            switch event {
            case .drew: events.drew += 1
            case let .laidOut(size, _): events.sizes.append(size)
            case .backingChanged: break
            }
        }
        defer { LayerDrawnView.drawObserver = nil }
        let view = Probe(frame: NSRect(x: 0, y: 0, width: 40, height: 20))
        view.layout()
        view.layout()
        let context = try #require(CGContext(
            data: nil, width: 40, height: 20, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue,
        ))
        view.draw(CALayer(), in: context)
        view.setFrameSize(NSSize(width: 60, height: 20))
        view.layout()
        #expect(events.drew == 1)
        #expect(events.sizes == [CGSize(width: 40, height: 20), CGSize(width: 60, height: 20)])
    }
}
