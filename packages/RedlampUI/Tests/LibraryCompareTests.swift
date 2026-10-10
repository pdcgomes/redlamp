import AppKit
import CoreGraphics
import Foundation
import RedlampDocument
import RedlampLibrary
import Testing
@_spi(Harness) @testable import RedlampUI

/// Compare (C) and Survey (N) in the Library module (LIB-16): the select and a candidate side by side, the candidate
/// changed by ← and →, made the select by ↑ and swapped by ↓, their zoom and pan linked until unlinked; the photos
/// selected laid out together, the arrow keys moving between them and a photo's × taking it out; in both the
/// culling keys on the active photo alone and the right panels following it.
@MainActor
struct LibraryCompareTests {
    /// Photos 1200 by 800 pixels: their previews at most 2048, so the same.
    private nonisolated static func photo(_ size: Int) -> CGImage? {
        ModuleFixture.image(min(size, 1200))
    }

    /// A folder of `count` photos in Library's grid, with the window's module views around it.
    private func library(_ count: Int) async throws -> (ModuleFixture, ModuleWindow) {
        let fixture = ModuleFixture()
        fixture.engine.decodedThumbnail = { _, size in Self.photo(size) }
        try await fixture.open(count: count)
        let modules = fixture.showModules()
        fixture.model.showModule(.library)
        try await fixture.settle()
        return (fixture, modules)
    }

    private func names(_ urls: [URL?]) -> [String] {
        urls.map { $0?.lastPathComponent ?? "-" }
    }

    /// A turn for the views' trackers, then the window laid out, as a display cycle lays it out on screen.
    private func settle(_ fixture: ModuleFixture, _ modules: ModuleWindow) async throws {
        try await fixture.settle()
        modules.window.contentView?.layoutSubtreeIfNeeded()
    }

    /// A key the view handles itself, as the key monitor lets it through.
    private func press(_ code: UInt16, in view: NSView) throws {
        let event = try #require(NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: [.function, .numericPad], timestamp: 0,
            windowNumber: view.window?.windowNumber ?? 0, context: nil, characters: "", charactersIgnoringModifiers: "",
            isARepeat: false, keyCode: code,
        ))
        view.keyDown(with: event)
    }

    /// A click on `view` at `point` in its own coordinates, `count` clicks in a row.
    private func click(_ view: NSView, at point: CGPoint? = nil, count: Int = 1) throws {
        let point = point ?? CGPoint(x: view.bounds.midX, y: view.bounds.midY)
        for clicks in 1 ... count {
            for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
                let event = try #require(NSEvent.mouseEvent(
                    with: type, location: view.convert(point, to: nil), modifierFlags: [], timestamp: 0,
                    windowNumber: view.window?.windowNumber ?? 0, context: nil, eventNumber: 0, clickCount: clicks,
                    pressure: type == .leftMouseUp ? 0 : 1,
                ))
                if type == .leftMouseDown {
                    view.mouseDown(with: event)
                } else {
                    view.mouseUp(with: event)
                }
            }
        }
    }

    /// Until the culling changes asked for are in the photos' sidecars.
    private func written(_ model: EditorModel) async {
        while let tail = model.cullingTail {
            await tail.value
            if model.cullingTail == tail {
                break
            }
        }
        await model.saves.flush()
    }

    /// The text the Library's right column shows.
    private func texts(in view: NSView) -> [String] {
        view.subviews.flatMap { child in ((child as? NSTextField).map { [$0.stringValue] } ?? []) + texts(in: child) }
    }

    // MARK: - Compare

    @Test func `C shows the active photo as the select beside the photo after it, both selected and the select active`()
        async throws {
        let (fixture, modules) = try await library(5)
        defer { fixture.cleanUp() }
        let (model, photos) = (fixture.model, fixture.photos)
        model.click(photos[1])
        #expect(ShortcutAction.compareView.title == "Compare" && ShortcutAction.surveyView.title == "Survey")
        #expect(model.canPerform(.compareView) && model.perform(.compareView))
        #expect(model.module == .library && model.libraryView == .compare)
        let compare = model.libraryCompare
        #expect(names([compare.select, compare.candidate]) == names([photos[1], photos[2]]))
        #expect(model.selectedPhotos == [photos[1], photos[2]] && model.selection == photos[1])
        try await settle(fixture, modules)
        let view = modules.content.library.compare
        #expect(!view.isHidden && modules.content.library.loupe.isHidden && modules.grid.isHidden)
        #expect(modules.window.firstResponder === view, "Compare takes the keyboard for ↑ and ↓")
        try await fixture.eventually { view.halves.values.allSatisfy { $0.photo.image != nil } }
        #expect(view.halves[.select]?.photo.url == photos[1] && view.halves[.candidate]?.photo.url == photos[2])
        #expect(view.halves[.select]?.photo.isActive == true && view.halves[.candidate]?.photo.isActive == false)
        #expect(view.halves[.select]?.photo.accessibilityLabel() == photos[1].lastPathComponent)

        #expect(model.perform(.compareView), "C in Compare keeps it as it is")
        #expect(names([compare.select, compare.candidate]) == names([photos[1], photos[2]]))
        model.showModule(.develop)
        #expect(model.perform(.compareView) && model.module == .library && model.libraryView == .compare)
    }

    @Test func `with several photos selected, the candidate is the next of them, back to the first after the last`()
        async throws {
        let (fixture, _) = try await library(6)
        defer { fixture.cleanUp() }
        let (model, photos) = (fixture.model, fixture.photos)
        model.click(photos[1])
        model.click(photos[4], toggling: true)
        #expect(model.selection == photos[4])
        model.perform(.compareView)
        let compare = model.libraryCompare
        #expect(names([compare.select, compare.candidate]) == names([photos[4], photos[1]]))
        #expect(model.selectedPhotos == [photos[1], photos[4]] && model.selection == photos[4])
    }

    @Test func `← and → change the candidate in the grid's order past the select, and stop at either end`()
        async throws {
        let (fixture, _) = try await library(5)
        defer { fixture.cleanUp() }
        let (model, photos) = (fixture.model, fixture.photos)
        model.click(photos[2])
        model.perform(.compareView)
        let compare = model.libraryCompare
        #expect(compare.candidate == photos[3])
        #expect(model.perform(.nextPhoto) && compare.candidate == photos[4])
        #expect(
            model.selection == photos[2] && model.selectedPhotos == [photos[2], photos[4]],
            "the select stays active",
        )
        #expect(!model.canPerform(.nextPhoto), "→ at the last photo")
        model.perform(.nextPhoto)
        #expect(compare.candidate == photos[4])
        model.perform(.previousPhoto)
        #expect(compare.candidate == photos[3])
        model.perform(.previousPhoto)
        #expect(compare.candidate == photos[1], "← goes past the select")
        model.perform(.previousPhoto)
        #expect(compare.candidate == photos[0] && !model.canPerform(.previousPhoto))
        #expect(compare.select == photos[2] && model.libraryView == .compare)
    }

    @Test func `↑ makes the candidate the select and the next photo the candidate, and ↓ swaps the two`() async throws {
        let (fixture, modules) = try await library(5)
        defer { fixture.cleanUp() }
        let (model, photos) = (fixture.model, fixture.photos)
        model.click(photos[1])
        model.perform(.compareView)
        try await fixture.settle()
        let view = modules.content.library.compare
        let compare = model.libraryCompare
        try press(126, in: view)
        #expect(names([compare.select, compare.candidate]) == names([photos[2], photos[3]]))
        #expect(model.selection == photos[2] && compare.activeSide == .select, "the select is active")
        #expect(model.selectedPhotos == [photos[2], photos[3]])
        model.activateCompared(.candidate)
        try press(125, in: view)
        #expect(names([compare.select, compare.candidate]) == names([photos[3], photos[2]]))
        #expect(model.selection == photos[3] && compare.activeSide == .select, "the active photo stays active")
        #expect(view.swap.accessibilityPerformPress())
        #expect(names([compare.select, compare.candidate]) == names([photos[2], photos[3]]))
        #expect(view.makeSelect.accessibilityPerformPress())
        #expect(names([compare.select, compare.candidate]) == names([photos[3], photos[4]]))
        #expect(model.activity.events.contains { $0.kind == .action && $0.text == "Make Select" })
        #expect(view.done.accessibilityPerformPress() && model.libraryView == .loupe, "Done shows the loupe")
        #expect(model.selection == photos[3])
    }

    @Test func `culling keys reach the active photo alone, and with ⇧ the candidate moves on`() async throws {
        let (fixture, _) = try await library(5)
        defer { fixture.cleanUp() }
        let (model, photos) = (fixture.model, fixture.photos)
        model.click(photos[0])
        model.perform(.compareView)
        func metadata(_ index: Int) -> PhotoMetadata {
            model.library.item(for: photos[index])?.metadata ?? PhotoMetadata()
        }
        #expect(model.canPerform(.rating3) && model.perform(.rating3))
        #expect(metadata(0).rating == 3 && metadata(1).rating == 0, "the select alone")
        model.activateCompared(.candidate)
        #expect(model.selection == photos[1])
        #expect(model.perform(.flagPick))
        #expect(metadata(1).flag == .pick && metadata(0).flag == nil, "the candidate alone")
        #expect(model.perform(.rating2, shifted: true))
        #expect(metadata(1).rating == 2 && model.libraryCompare.candidate == photos[2])
        #expect(model.selection == photos[2] && model.libraryCompare.activeSide == .candidate)
        #expect(metadata(2).rating == 0)
        #expect(model.perform(.undo) && metadata(1).rating == 0, "Undo takes back the candidate's rating")
        try await fixture.eventually { !model.isWritingCulling }
    }

    @Test func `the right panels follow the active photo`() async throws {
        let (fixture, modules) = try await library(4)
        defer { fixture.cleanUp() }
        let (model, photos) = (fixture.model, fixture.photos)
        model.click(photos[0])
        model.perform(.compareView)
        try await fixture.settle()
        let column = modules.right.library
        #expect(texts(in: column).contains(photos[0].lastPathComponent))
        model.activateCompared(.candidate)
        try await fixture.settle()
        #expect(texts(in: column).contains(photos[1].lastPathComponent))
        #expect(!texts(in: column).contains(photos[0].lastPathComponent))
        model.perform(.gridView)
        model.click(photos[0])
        model.click(photos[2], extending: true)
        model.perform(.surveyView)
        model.perform(.previousPhoto)
        try await fixture.settle()
        #expect(model.selection == photos[1] && texts(in: column).contains(photos[1].lastPathComponent))
    }

    @Test func `the two zoom and pan together until unlinked, and linked again take the active one's zoom`()
        async throws {
        let (fixture, modules) = try await library(4)
        defer { fixture.cleanUp() }
        let model = fixture.model
        model.click(fixture.photos[0])
        model.perform(.compareView)
        try await fixture.settle()
        let view = modules.content.library.compare
        let (select, candidate) = try (#require(view.halves[.select]?.photo), #require(view.halves[.candidate]?.photo))
        #expect(model.canPerform(.toggleZoom) && model.perform(.toggleZoom))
        try await fixture.settle()
        #expect(select.zoom == .actual && candidate.zoom == .actual)
        model.setCompareFocus(CGPoint(x: 0.2, y: 0.7))
        try await fixture.settle()
        #expect(select.focus == CGPoint(x: 0.2, y: 0.7) && candidate.focus == select.focus)
        try await fixture.eventually { select.showsFullPhoto && candidate.showsFullPhoto }
        #expect(select.image?.width == 1200, "1:1 decodes the photo itself")

        #expect(view.link.isOn && view.link.accessibilityPerformPress())
        try await fixture.settle()
        #expect(!model.libraryCompare.isLinked && !view.link.isOn)
        model.perform(.toggleZoom)
        try await fixture.settle()
        #expect(select.zoom == .fit && candidate.zoom == .actual, "unlinked, Z reaches the active photo alone")
        model.activateCompared(.candidate)
        try await fixture.settle()
        #expect(model.libraryViews.loupeZoom == .actual, "the toolbar's Fit and 1:1 show the active photo's zoom")
        #expect(select.zoom == .fit && candidate.zoom == .actual)
        #expect(view.link.accessibilityPerformPress())
        try await fixture.settle()
        #expect(select.zoom == .actual && candidate.zoom == .actual, "linked again, both take the active one's")
    }

    @Test func `a click on the candidate makes it active, and one on the active photo zooms where it lands`()
        async throws {
        let (fixture, modules) = try await library(4)
        defer { fixture.cleanUp() }
        let model = fixture.model
        model.click(fixture.photos[0])
        model.perform(.compareView)
        try await settle(fixture, modules)
        let view = modules.content.library.compare
        let candidate = try #require(view.halves[.candidate]?.photo)
        try await fixture.eventually { candidate.photoFrame.width > 0 }
        try click(candidate)
        #expect(model.libraryCompare.activeSide == .candidate && model.selection == fixture.photos[1])
        #expect(model.libraryViews.loupeZoom == .fit, "the click that makes it active doesn't zoom")
        let frame = candidate.photoFrame
        try click(candidate, at: CGPoint(x: frame.minX + frame.width / 4, y: frame.midY))
        #expect(model.libraryViews.loupeZoom == .actual)
        #expect(abs(model.libraryCompare.focus.x - 0.25) < 0.02 && abs(model.libraryCompare.focus.y - 0.5) < 0.02)
        #expect(modules.window.firstResponder === view)
    }

    @Test func `a photo chosen in the filmstrip takes the active one's place`() async throws {
        let (fixture, _) = try await library(6)
        defer { fixture.cleanUp() }
        let (model, photos) = (fixture.model, fixture.photos)
        model.click(photos[0])
        model.perform(.compareView)
        try await fixture.settle()
        let compare = model.libraryCompare
        model.click(photos[3])
        try await fixture.settle()
        #expect(names([compare.select, compare.candidate]) == names([photos[3], photos[1]]))
        #expect(model.selectedPhotos == [photos[1], photos[3]] && model.selection == photos[3])
        model.activateCompared(.candidate)
        model.click(photos[5])
        model.perform(.previousPhoto)
        #expect(names([compare.select, compare.candidate]) == names([photos[3], photos[4]]), "← from the new candidate")
    }

    @Test func `E shows the active photo in the loupe, G the grid and Esc the grid, the selection kept`() async throws {
        let (fixture, _) = try await library(4)
        defer { fixture.cleanUp() }
        let (model, photos) = (fixture.model, fixture.photos)
        model.click(photos[1])
        model.perform(.compareView)
        model.activateCompared(.candidate)
        #expect(model.perform(.loupeView) && model.libraryView == .loupe && model.selection == photos[2])
        #expect(model.selectedPhotos == [photos[1], photos[2]])
        #expect(model.perform(.compareView) && model.libraryCompare.select == photos[2])
        #expect(model.perform(.gridView) && model.libraryView == .grid && model.selectedPhotos == [
            photos[1],
            photos[2],
        ])
        model.perform(.compareView)
        #expect(model.perform(.cancel) && model.libraryView == .grid)
    }

    // MARK: - Survey

    @Test func `N lays out the photos selected, the active one marked, and the arrow keys move between them`()
        async throws {
        let (fixture, modules) = try await library(8)
        defer { fixture.cleanUp() }
        let (model, photos) = (fixture.model, fixture.photos)
        model.click(photos[1])
        model.click(photos[6], extending: true)
        #expect(model.canPerform(.surveyView) && model.perform(.surveyView))
        #expect(model.libraryView == .survey && model.selection == photos[6])
        try await settle(fixture, modules)
        let view = modules.content.library.survey
        #expect(!view.isHidden && modules.window.firstResponder === view)
        #expect(view.photos == Array(photos[1 ... 6]))
        try await fixture.eventually { view.cells.prefix(6).allSatisfy { $0.photo.image != nil } }
        let frames = view.cells.prefix(6).map(\.frame)
        for (index, frame) in frames.enumerated() {
            #expect(view.bounds.contains(frame) && frame.width > 100, "\(frame) isn't in \(view.bounds)")
            #expect(!frames.enumerated().contains { $0.offset != index && $0.element.intersects(frame) })
        }
        #expect(view.cell(showing: photos[6])?.photo.isActive == true)
        #expect(view.cells.prefix(6).count { $0.photo.isActive } == 1)

        #expect(!model.canPerform(.nextPhoto) && model.canPerform(.previousPhoto))
        model.perform(.previousPhoto)
        #expect(model.selection == photos[5] && model.selectedPhotos == Array(photos[1 ... 6]))
        try await fixture.settle()
        #expect(view.cell(showing: photos[5])?.photo.isActive == true)
        // ↓ and ↑: the photo in the row below or above, nearest across.
        let rows = Set(frames.map(\.minY)).sorted()
        #expect(rows.count == 2, "six photos in \(view.bounds.size) lie in two rows")
        model.activateSurveyed(photos[1])
        try press(125, in: view)
        let below = try #require(model.selection.flatMap(view.cell(showing:)))
        #expect(below.frame.minY == rows[1] && below.frame.minX == frames[0].minX)
        try press(126, in: view)
        #expect(model.selection == photos[1])
        try press(36, in: view)
        #expect(model.libraryView == .loupe && model.selection == photos[1], "Return opens the active photo")
    }

    @Test func `a click makes a photo active and a double-click opens it in the loupe`() async throws {
        let (fixture, modules) = try await library(4)
        defer { fixture.cleanUp() }
        let (model, photos) = (fixture.model, fixture.photos)
        model.click(photos[0])
        model.click(photos[3], extending: true)
        model.perform(.surveyView)
        try await settle(fixture, modules)
        let view = modules.content.library.survey
        let cell = try #require(view.cell(showing: photos[1]))
        try click(cell.photo)
        #expect(model.selection == photos[1] && model.selectedPhotos == photos)
        try click(cell.photo, count: 2)
        #expect(model.libraryView == .loupe && model.selection == photos[1])
    }

    @Test func `culling keys in Survey reach the active photo alone, and with ⇧ the next becomes active`()
        async throws {
        let (fixture, _) = try await library(5)
        defer { fixture.cleanUp() }
        let (model, photos) = (fixture.model, fixture.photos)
        model.click(photos[0])
        model.click(photos[3], extending: true)
        model.perform(.surveyView)
        model.activateSurveyed(photos[1])
        func metadata(_ index: Int) -> PhotoMetadata {
            model.library.item(for: photos[index])?.metadata ?? PhotoMetadata()
        }
        #expect(model.perform(.labelGreen))
        #expect(metadata(1).label == .green && [0, 2, 3].allSatisfy { metadata($0).label == nil })
        #expect(model.perform(.flagReject, shifted: true))
        #expect(metadata(1).flag == .reject && model.selection == photos[2])
        #expect(model.selectedPhotos == Array(photos[0 ... 3]), "the survey stays")
        try await fixture.eventually { !model.isWritingCulling }
    }

    @Test func `a photo's × takes it out of the selection, and Survey stays until one is left`() async throws {
        let (fixture, modules) = try await library(5)
        defer { fixture.cleanUp() }
        let (model, photos) = (fixture.model, fixture.photos)
        model.click(photos[1])
        model.click(photos[4], extending: true)
        model.perform(.surveyView)
        try await fixture.settle()
        let view = modules.content.library.survey
        let active = try #require(view.cell(showing: photos[4]))
        #expect(active.remove.accessibilityIdentifier() == "survey.remove.\(photos[4].lastPathComponent)")
        #expect(active.remove.accessibilityPerformPress())
        #expect(model.selectedPhotos == Array(photos[1 ... 3]) && model.selection == photos[3])
        try await fixture.settle()
        #expect(model.libraryView == .survey && view.photos == Array(photos[1 ... 3]))
        #expect(view.cell(showing: photos[3])?.photo.isActive == true)
        #expect(view.cell(showing: photos[1])?.remove.accessibilityPerformPress() == true)
        #expect(view.cell(showing: photos[2])?.remove.accessibilityPerformPress() == true)
        try await fixture.settle()
        #expect(view.photos == [photos[3]] && model.libraryView == .survey)
        #expect(view.cell(showing: photos[3])?.remove.isEnabled == false)
        #expect(!model.removeFromSurvey(photos[3]) && model.selection == photos[3], "the last photo stays")
    }

    @Test func `Survey's layout shows the photos as large as they fit, a short last row centred`() {
        let area = CGRect(x: 0, y: 0, width: 1200, height: 600)
        let one = LibrarySurveyView.layout([1.5], in: area, gap: 14, strip: 22)
        #expect(one == [area])
        let two = LibrarySurveyView.layout([1.5, 1.5], in: area, gap: 14, strip: 22)
        #expect(two.count == 2 && two[0].minY == two[1].minY && two[1].minX - two[0].maxX == 14, "side by side")
        let three = LibrarySurveyView.layout([1.5, 1.5, 1.5], in: area, gap: 14, strip: 22)
        #expect(Set(three.map(\.minY)).count == 2, "two rows cover more than one of three")
        #expect(abs(three[2].midX - area.midX) < 0.5, "the last row's photo is centred")
        let portraits = LibrarySurveyView.layout(Array(repeating: 2.0 / 3, count: 3), in: area, gap: 14, strip: 22)
        #expect(Set(portraits.map(\.minY)).count == 1, "three portraits stand in one row")
        for frames in [two, three, portraits] {
            #expect(frames.allSatisfy { area.contains($0) })
        }
        #expect(LibrarySurveyView.layout([], in: area, gap: 14, strip: 22).isEmpty)
    }

    // MARK: - Budgets

    @Test(.measuresSpeed)
    func `Compare and Survey are on screen within a frame of their keys`() async throws {
        let (fixture, modules) = try await library(40)
        defer { fixture.cleanUp() }
        let (model, photos) = (fixture.model, fixture.photos)
        model.click(photos[10])
        model.click(photos[17], extending: true)
        for photo in photos[10 ... 18] {
            _ = try await model.thumbnailLoader.image(for: #require(model.library.item(for: photo)))
        }
        let library = modules.content.library
        let clock = ContinuousClock()
        func onScreen(_ action: ShortcutAction, shown: () -> Bool) async throws -> Duration {
            var times: [Duration] = []
            for _ in 0 ..< 15 {
                model.perform(.gridView)
                try await settle(fixture, modules)
                let start = clock.now
                model.perform(action)
                while !shown(), clock.now - start < .seconds(2) {
                    await Task.yield()
                }
                modules.window.contentView?.layoutSubtreeIfNeeded()
                times.append(clock.now - start)
            }
            return times.sorted()[times.count / 2]
        }
        let compare = try await onScreen(.compareView) {
            !library.compare.isHidden && library.compare.halves.values.allSatisfy { $0.photo.image != nil }
        }
        model.perform(.gridView)
        model.click(photos[10])
        model.click(photos[17], extending: true)
        let survey = try await onScreen(.surveyView) {
            !library.survey.isHidden && library.survey.photos.count == 8
                && library.survey.cells.prefix(8).allSatisfy { $0.photo.image != nil }
        }
        print("Compare on screen in a median of \(compare), Survey of eight in \(survey)")
        #expect(compare < .microseconds(8300), "Compare took \(compare)")
        #expect(survey < .microseconds(8300), "Survey took \(survey)")
    }
}
