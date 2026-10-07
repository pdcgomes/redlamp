import CoreGraphics
import Foundation
import Observation
import RedlampCanvas
import RedlampEngineAPI
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

    /// An editor on a folder of three photos.
    private func editor() async throws -> EditorModel {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        for index in 0 ..< 3 {
            FileManager.default.createFile(
                atPath: folder.appending(path: "IMG_000\(index).ARW").path,
                contents: Data([1]),
            )
        }
        let defaults = try #require(UserDefaults(suiteName: suite))
        let model = EditorModel(engine: StubEngine(), library: FolderLibrary(defaults: defaults))
        model.open([folder])
        for _ in 0 ..< 400 where model.library.count < 3 {
            try await Task.sleep(for: .milliseconds(5))
        }
        try #require(model.library.count == 3)
        return model
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
}
