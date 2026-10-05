import AppKit
import Testing
@testable import RedlampCanvas

/// Scrolling and pinching over a tool's overlay reach the canvas; over panels, lists and other
/// windows they don't (UX-15).
@MainActor
struct CoveredEventTests {
    private typealias Event = CanvasMetalView.CoveredEvent

    @Test func `an event on the stage under an overlay belongs to the canvas`() {
        #expect(Event(sameWindow: true, onStage: true, hitsCanvas: false, hitsScrollingView: false).belongsToCanvas)
    }

    @Test func `the canvas, panels, lists and other windows keep their own events`() {
        // The canvas takes an event that reaches it the usual way.
        #expect(!Event(sameWindow: true, onStage: true, hitsCanvas: true, hitsScrollingView: false).belongsToCanvas)
        // A panel over the canvas's edge, outside the stage.
        #expect(!Event(sameWindow: true, onStage: false, hitsCanvas: false, hitsScrollingView: false).belongsToCanvas)
        // The command palette's list.
        #expect(!Event(sameWindow: true, onStage: true, hitsCanvas: false, hitsScrollingView: true).belongsToCanvas)
        // A popover or another window.
        #expect(!Event(sameWindow: false, onStage: true, hitsCanvas: false, hitsScrollingView: false).belongsToCanvas)
    }

    @Test func `a wheel notch rolled away from you is one, whatever the scrolling direction setting`() throws {
        let cgEvent = try #require(CGEvent(
            scrollWheelEvent2Source: nil, units: .line, wheelCount: 1, wheel1: 2, wheel2: 0, wheel3: 0,
        ))
        let event = try #require(NSEvent(cgEvent: cgEvent))
        let notches = CanvasMetalView.notches(of: event)
        #expect(abs(notches) == 2)
        #expect((notches > 0) == !event.isDirectionInvertedFromDevice)
    }

    @Test func `a wheel spun hard counts as four notches at most`() throws {
        let cgEvent = try #require(CGEvent(
            scrollWheelEvent2Source: nil, units: .line, wheelCount: 1, wheel1: 9, wheel2: 0, wheel3: 0,
        ))
        let event = try #require(NSEvent(cgEvent: cgEvent))
        #expect(abs(CanvasMetalView.notches(of: event)) == 4)
    }
}
