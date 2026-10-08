import AppKit
import CoreGraphics
import Foundation
import Observation
import RedlampCanvas
import RedlampEngineAPI
import SwiftUI
import Testing
@testable import RedlampUI

/// The filmstrip's Hide Automatically (UX-19): one saved preference for the View menu, the
/// filmstrip's own menu and Settings, and the room the photo makes for the filmstrip while it's off.
@MainActor
struct FilmstripHidingTests {
    private let folder = FileManager.default.temporaryDirectory.appending(path: "filmstrip-hiding-\(UUID().uuidString)")
    private let suite = "FilmstripHidingTests-\(UUID().uuidString)"

    private final class Heard: @unchecked Sendable {
        var changed = false
    }

    private func cleanUp() {
        try? FileManager.default.removeItem(at: folder)
        UserDefaults().removePersistentDomain(forName: suite)
    }

    /// An editor on a folder of `count` photos.
    private func editor(photos count: Int = 3) async throws -> EditorModel {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        for index in 0 ..< count {
            FileManager.default.createFile(
                atPath: folder.appending(path: String(format: "IMG_%04d.ARW", index)).path,
                contents: Data([1]),
            )
        }
        let defaults = try #require(UserDefaults(suiteName: suite))
        let model = EditorModel(engine: StubEngine(), library: FolderLibrary(defaults: defaults))
        model.open([folder])
        for _ in 0 ..< 400 where model.library.count < count || model.selection == nil {
            try await Task.sleep(for: .milliseconds(5))
        }
        try #require(model.library.count == count)
        return model
    }

    private static func views<T: NSView>(_: T.Type, in view: NSView?) -> [T] {
        guard let view else { return [] }
        return ((view as? T).map { [$0] } ?? []) + view.subviews.flatMap { views(T.self, in: $0) }
    }

    /// The filmstrip's photos where they can be seen in `window`, laid out.
    private static func shownStrip(in window: NSWindow) -> FilmstripStripView? {
        guard let content = window.contentView else { return nil }
        content.layoutSubtreeIfNeeded()
        return views(FilmstripStripView.self, in: content).first { strip in
            strip.layoutSubtreeIfNeeded()
            return !strip.isHiddenOrHasHiddenAncestor
                && sequence(first: strip as NSView, next: \.superview).allSatisfy { $0.alphaValue > 0 }
                && content.bounds.intersects(strip.convert(strip.bounds, to: content))
                && strip.collectionView.frame.width > strip.scrollView.contentView.bounds.width
        }
    }

    /// The editor's canvas with its floating filmstrip, in a window of its own.
    private static func window(showing model: EditorModel) -> NSWindow {
        _ = NSApplication.shared
        let window = NSWindow(
            contentRect: CGRect(x: 0, y: 0, width: 1200, height: 700), styleMask: [.titled],
            backing: .buffered, defer: false,
        )
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(
            rootView: EditorContentView(model: model, theme: ThemeSettings(), onOpen: {}),
        )
        return window
    }

    private func eventually(_ condition: () -> Bool) async throws {
        for _ in 0 ..< 400 where !condition() {
            try await Task.sleep(for: .milliseconds(5))
        }
    }

    @Test func `Hide Automatically is on until it's turned off, and the next launch reads it back`() throws {
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { cleanUp() }
        #expect(FilmstripPreference(defaults: defaults).hidesAutomatically, "nothing saved yet")

        let preference = FilmstripPreference(defaults: defaults)
        preference.hidesAutomatically = false
        #expect(!FilmstripPreference(defaults: defaults).hidesAutomatically)
        preference.hidesAutomatically = true
        #expect(FilmstripPreference(defaults: defaults).hidesAutomatically)
    }

    @Test func `the stage keeps clear of the filmstrip only while the photo makes room for it`() {
        let floating = PanelMetrics.stageInsets(toolbarHeight: 52, presenting: false, filmstrip: false)
        let kept = PanelMetrics.stageInsets(toolbarHeight: 52, presenting: false, filmstrip: true)
        #expect(floating.bottom == PanelMetrics.inset, "the filmstrip floats over the photo")
        #expect(kept.bottom == PanelMetrics.inset + PanelMetrics.filmstripHeight + PanelMetrics.inset)
        #expect(kept.bottom == 126)
        #expect(kept.top == 52 && kept.leading == floating.leading && kept.trailing == floating.trailing)
        #expect(PanelMetrics.stageInsets(toolbarHeight: 52, presenting: true, filmstrip: true) == .zero)
    }

    /// A portrait photo fills the stage's height, so Fit reaches its bottom.
    @Test func `at Fit the photo ends above the filmstrip, and panning stops its bottom edge there`() {
        let canvas = CanvasController()
        canvas.updateView(size: CGSize(width: 1800, height: 900), backingScale: 2)
        canvas.imageSize = PixelSize(width: 3024, height: 4032)
        canvas.stageInsets = PanelMetrics.stageInsets(toolbarHeight: 52, presenting: false, filmstrip: true)
        let filmstripTop = 900 - PanelMetrics.inset - PanelMetrics.filmstripHeight
        let fit = canvas.imageRect(in: canvas.viewSize)
        #expect(abs(fit.maxY - (filmstripTop - PanelMetrics.inset)) < 0.5)
        #expect(abs(canvas.visibleImageRect.height - 1) < 1e-6, "the Navigator shows all of it in view")

        canvas.zoom = .oneToOne
        canvas.center = CGPoint(x: 0.5, y: 1)
        let panned = canvas.imageRect(in: canvas.viewSize)
        #expect(panned.height > 900)
        #expect(abs(panned.maxY - (filmstripTop - PanelMetrics.inset)) < 0.5)
        #expect(abs(canvas.visibleImageRect.maxY - 1) < 1e-6, "the Navigator shows the bottom in view")
    }

    @Test func `the photo makes room while Hide Automatically is off, and gets it back from F6 and presenting`(
    ) async throws {
        defer { cleanUp() }
        let kept = FilmstripPreference.shared.hidesAutomatically
        defer { FilmstripPreference.shared.hidesAutomatically = kept }
        let model = try await editor()

        model.filmstripHidesAutomatically = true
        #expect(!model.makesRoomForFilmstrip, "it floats over the photo")
        model.filmstripHidesAutomatically = false
        #expect(model.makesRoomForFilmstrip)

        model.lightsOut = 1
        #expect(model.makesRoomForFilmstrip, "Lights Out leaves the photo where it is")
        model.lightsOut = 0

        #expect(model.perform(.toggleFilmstrip))
        #expect(!model.makesRoomForFilmstrip, "hidden altogether, it gives its room back")
        #expect(model.perform(.toggleFilmstrip))
        #expect(model.makesRoomForFilmstrip)

        #expect(model.perform(.fullScreenPreview))
        #expect(model.isPresenting && !model.makesRoomForFilmstrip)
        #expect(model.perform(.fullScreenPreview))
        #expect(!model.isPresenting && model.makesRoomForFilmstrip, "presenting puts it back as it was")
    }

    @Test func `with no photos there's no filmstrip to make room for`() {
        let kept = FilmstripPreference.shared.hidesAutomatically
        defer { FilmstripPreference.shared.hidesAutomatically = kept }
        let model = EditorModel(engine: StubEngine())
        model.filmstripHidesAutomatically = false
        #expect(model.library.count == 0 && !model.makesRoomForFilmstrip)
    }

    /// The View menu, the filmstrip's menu and Settings all set the one preference the stage follows.
    @Test func `a change from any of its controls reaches every editor and the stage`() async throws {
        defer { cleanUp() }
        let kept = FilmstripPreference.shared.hidesAutomatically
        defer { FilmstripPreference.shared.hidesAutomatically = kept }
        let model = try await editor()
        let other = EditorModel(engine: StubEngine())
        model.filmstripHidesAutomatically = true

        let heard = Heard()
        withObservationTracking { _ = model.makesRoomForFilmstrip } onChange: { heard.changed = true }
        FilmstripPreference.shared.hidesAutomatically = false
        #expect(heard.changed)
        #expect(model.makesRoomForFilmstrip && !other.filmstripHidesAutomatically)

        other.filmstripHidesAutomatically = true
        #expect(model.filmstripHidesAutomatically && !model.makesRoomForFilmstrip)
    }

    /// #344: the filmstrip that slid away once the pointer left it comes back as it was left, scrolled
    /// to the photo picked there, not at the first photo.
    @Test func `hidden and shown again, the filmstrip comes back scrolled where it was`() async throws {
        defer { cleanUp() }
        let kept = FilmstripPreference.shared.hidesAutomatically
        defer { FilmstripPreference.shared.hidesAutomatically = kept }
        let model = try await editor(photos: 200)
        model.filmstripHidesAutomatically = false
        let window = Self.window(showing: model)
        defer { window.contentView = nil }
        /// As the pointer leaving or coming back does, without waiting for the slide.
        func hidesAutomatically(_ hides: Bool) {
            withTransaction(\.disablesAnimations, true) { model.filmstripHidesAutomatically = hides }
        }

        try await eventually { Self.shownStrip(in: window) != nil }
        let strip = try #require(Self.shownStrip(in: window))
        let clip = strip.scrollView.contentView
        let picked = 120
        let frame = try #require(strip.collectionView.layoutAttributesForItem(at: IndexPath(item: picked, section: 0)))
            .frame
        clip.scroll(to: CGPoint(x: frame.midX - clip.bounds.width / 2, y: 0))
        strip.scrollView.reflectScrolledClipView(clip)
        let place = clip.bounds.origin.x
        #expect(place > 0 && clip.bounds.contains(frame))
        model.click(model.items[picked].url, toggling: false, extending: false)
        try await eventually { model.selection == model.items[picked].url }
        let middle = strip.convert(CGPoint(x: strip.bounds.midX, y: strip.bounds.midY), to: nil)

        hidesAutomatically(true)
        try await eventually { Self.shownStrip(in: window) == nil }
        #expect(Self.shownStrip(in: window) == nil, "it slid away")
        #expect(
            window.contentView?.superview?.hitTest(middle) is CanvasMetalView,
            "a click where it was is the photo's",
        )
        hidesAutomatically(false)
        try await eventually { Self.shownStrip(in: window) != nil }
        let shown = try #require(Self.shownStrip(in: window))
        let bounds = shown.scrollView.contentView.bounds
        #expect(abs(bounds.origin.x - place) < 0.5, "at \(bounds.origin.x), where it was left at \(place)")
        #expect(bounds.contains(frame), "the photo picked is in view")
    }

    /// F6 takes the filmstrip away altogether, and brings back a new strip: it opens at the photo open
    /// now, wherever ← and → went meanwhile.
    @Test func `turned off and on again, the filmstrip opens at the open photo`() async throws {
        defer { cleanUp() }
        let kept = FilmstripPreference.shared.hidesAutomatically
        defer { FilmstripPreference.shared.hidesAutomatically = kept }
        let model = try await editor(photos: 200)
        model.filmstripHidesAutomatically = false
        let window = Self.window(showing: model)
        defer { window.contentView = nil }
        try await eventually { Self.shownStrip(in: window) != nil }

        #expect(model.perform(.toggleFilmstrip))
        try await eventually { Self.shownStrip(in: window) == nil }
        #expect(Self.shownStrip(in: window) == nil, "F6 took it away")
        model.select(model.items[160].url)
        #expect(model.perform(.toggleFilmstrip))
        try await eventually { Self.shownStrip(in: window) != nil }
        let strip = try #require(Self.shownStrip(in: window))
        let frame = try #require(strip.collectionView.layoutAttributesForItem(at: IndexPath(item: 160, section: 0)))
            .frame
        try await eventually { strip.scrollView.contentView.bounds.contains(frame) }
        #expect(strip.scrollView.contentView.bounds.contains(frame), "at \(strip.scrollView.contentView.bounds)")
    }
}
