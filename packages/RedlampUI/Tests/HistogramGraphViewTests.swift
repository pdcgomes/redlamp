import AppKit
import Foundation
import RedlampDesign
import RedlampEngineAPI
import Testing
@testable import RedlampUI

/// The histogram's graph, which takes a new histogram about 30 times a second while a photo
/// renders (RESP-05).
///
/// The look is compared with references drawn at a scale of 1, in the dark appearance and in
/// sRGB, whatever the screen's and the system's, so one set serves every Mac: CI's runner is in
/// Light mode, on a display of its own. To record them again, run with
/// `TEST_RUNNER_REDLAMP_RECORD_HISTOGRAM=1`.
@MainActor @Suite(.serialized)
struct HistogramGraphViewTests {
    static let goldenURL = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        .appending(path: "Golden")
    static let recording = ProcessInfo.processInfo.environment["REDLAMP_RECORD_HISTOGRAM"] == "1"

    private final class Draws {
        var count = 0
    }

    /// A window at a scale of 1 on any screen, so the graph draws its references' pixels.
    private final class OneXWindow: NSWindow {
        override var backingScaleFactor: CGFloat {
            1
        }
    }

    private func openEditor() async throws -> (EditorModel, GatedEngine, () -> Void) {
        let folder = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let engine = GatedEngine()
        engine.sendsFrames = true
        let model = EditorModel(engine: engine)
        model.canvas.updateView(size: CGSize(width: 300, height: 200), backingScale: 1)
        model.select(folder.appending(path: "IMG_0001.ARW"))
        for _ in 0 ..< 400 where !model.hasFrame {
            try await Task.sleep(for: .milliseconds(5))
        }
        try #require(model.hasFrame)
        return (model, engine, { try? FileManager.default.removeItem(at: folder) })
    }

    private func window(_ view: NSView) -> NSWindow {
        _ = NSApplication.shared
        let window = OneXWindow(
            contentRect: CGRect(x: 0, y: 0, width: 260, height: HistogramGraphView.height), styleMask: [.borderless],
            backing: .buffered, defer: false,
        )
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: .darkAqua)
        window.colorSpace = .sRGB
        window.contentView = view
        view.layoutSubtreeIfNeeded()
        return window
    }

    /// Three overlapping channels, shifted by `shift` bins, with `clipped` counts at both ends.
    private func histogram(shift: Int, clipped: UInt32 = 0) -> Histogram {
        func channel(_ center: Double, _ width: Double) -> [UInt32] {
            var bins = (0 ..< Histogram.binCount).map { index in
                let x = (Double(index - shift) - center) / width
                return UInt32(4000 * exp(-x * x / 2) + 20)
            }
            bins[0] += clipped
            bins[Histogram.binCount - 1] += clipped
            return bins
        }
        let red = channel(150, 30), green = channel(110, 40), blue = channel(80, 25)
        return Histogram(
            red: red, green: green, blue: blue, luminance: zip(red, zip(green, blue)).map { ($0 + $1.0 + $1.1) / 3 },
        )
    }

    /// Renders a frame carrying `histogram` and waits for the editor to publish it.
    private func show(_ histogram: Histogram, model: EditorModel, engine: GatedEngine, step: Int) async throws {
        engine.histogram = histogram
        model.setValue(.contrast, Double(step))
        for _ in 0 ..< 400 where model.histogram != histogram {
            try await Task.sleep(for: .milliseconds(5))
        }
        try #require(model.histogram == histogram)
        try await Task.sleep(for: .milliseconds(10))
    }

    /// Displays every layer that needs it, as Core Animation does at a commit. Drawing
    /// synchronously puts each drawing in the layer's backing before a snapshot reads it.
    private func display(_ layer: CALayer) {
        layer.drawsAsynchronously = false
        layer.displayIfNeeded()
        layer.sublayers?.forEach(display)
    }

    @Test func `new histograms are not drawn on the main thread`() async throws {
        let (model, engine, cleanup) = try await openEditor()
        defer { cleanup() }
        let view = HistogramGraphView(model: model)
        let window = window(view)
        defer { window.close() }
        try await show(histogram(shift: 0), model: model, engine: engine, step: 1)
        view.layoutSubtreeIfNeeded()
        try display(#require(view.layer))

        let draws = Draws()
        LayerDrawnView.drawObserver = { drawn, event in
            if drawn === view, case .drew = event {
                draws.count += 1
            }
        }
        defer { LayerDrawnView.drawObserver = nil }
        for step in 1 ... 10 {
            try await show(histogram(shift: step * 2), model: model, engine: engine, step: step + 1)
            view.layoutSubtreeIfNeeded()
            try display(#require(view.layer))
        }
        #expect(draws.count == 0)
    }

    @Test func `the graph looks the same for each histogram, clipping and hovered region`() async throws {
        let (model, engine, cleanup) = try await openEditor()
        defer { cleanup() }
        let view = HistogramGraphView(model: model)
        let window = window(view)
        defer { window.close() }

        try await show(histogram(shift: 0), model: model, engine: engine, step: 1)
        try await compare(view, with: "histogram-channels")

        try await show(histogram(shift: 20, clipped: 9000), model: model, engine: engine, step: 2)
        try await compare(view, with: "histogram-clipped")

        model.showClipping = true
        let event = try #require(NSEvent.mouseEvent(
            with: .mouseMoved, location: view.convert(CGPoint(x: 130, y: 50), to: nil), modifierFlags: [],
            timestamp: 0, windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 0,
            pressure: 0,
        ))
        view.mouseMoved(with: event)
        try await Task.sleep(for: .milliseconds(20))
        try await compare(view, with: "histogram-hovered")

        try await show(.empty, model: model, engine: engine, step: 3)
        try await compare(view, with: "histogram-empty")
    }

    /// The view's pixels in sRGB, once they have stayed the same for a quarter of a second.
    private func snapshot(_ view: NSView) async throws -> (CGImage, [UInt8]) {
        var previous: [UInt8]?
        var unchanged = 0
        for _ in 0 ..< 200 {
            view.layoutSubtreeIfNeeded()
            try display(#require(view.layer))
            let size = view.bounds.size
            let rep = try #require(NSBitmapImageRep(
                bitmapDataPlanes: nil, pixelsWide: Int(size.width.rounded(.up)),
                pixelsHigh: Int(size.height.rounded(.up)), bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0,
            )?.retagging(with: view.window?.colorSpace ?? .sRGB))
            rep.size = size
            view.cacheDisplay(in: view.bounds, to: rep)
            let image = try #require(rep.cgImage)
            let pixels = try pixels(of: image)
            unchanged = pixels == previous ? unchanged + 1 : 0
            if unchanged == 10 {
                return (image, pixels)
            }
            previous = pixels
            try await Task.sleep(for: .milliseconds(25))
        }
        Issue.record("The histogram never settled")
        throw CancellationError()
    }

    private func pixels(of image: CGImage) throws -> [UInt8] {
        let space = try #require(CGColorSpace(name: CGColorSpace.sRGB))
        let context = try #require(CGContext(
            data: nil, width: image.width, height: image.height, bitsPerComponent: 8, bytesPerRow: image.width * 4,
            space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue,
        ))
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        let data = try #require(context.data)
        return Array(UnsafeBufferPointer(
            start: data.assumingMemoryBound(to: UInt8.self), count: image.width * image.height * 4,
        ))
    }

    private func compare(_ view: NSView, with name: String) async throws {
        let (image, pixels) = try await snapshot(view)
        let url = Self.goldenURL.appending(path: "\(name).png")
        if Self.recording {
            try NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])?.write(to: url)
            return
        }
        guard FileManager.default.fileExists(atPath: url.path) else {
            Issue.record("Tests/Golden/\(name).png is missing: run with TEST_RUNNER_REDLAMP_RECORD_HISTOGRAM=1")
            return
        }
        let source = try #require(CGImageSourceCreateWithURL(url as CFURL, nil))
        let reference = try #require(CGImageSourceCreateImageAtIndex(source, 0, nil))
        try #require(reference.width == image.width && reference.height == image.height)
        let expected = try self.pixels(of: reference)
        let largest = zip(pixels, expected).map { abs(Int($0) - Int($1)) }.max() ?? 0
        guard largest > 2 else { return }
        let actual = FileManager.default.temporaryDirectory.appending(path: "\(name).png")
        try NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])?.write(to: actual)
        Issue.record("\(name): a channel differs from the reference by \(largest) of 255; see \(actual.path)")
    }
}
