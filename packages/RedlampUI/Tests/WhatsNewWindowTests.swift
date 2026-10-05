import AppKit
import AVFoundation
import Foundation
import Testing
@testable import RedlampUI

/// The What's New window: from the film's rise through the highlights and their pages (UX-14).
@MainActor
struct WhatsNewWindowTests {
    private func pages(_ versions: [String]) -> WhatsNewPages {
        let items = versions.enumerated().map { index, version in
            WhatsNewItem(
                id: "item-\(index)", version: AppVersion(version)!, date: "2026-10-06", symbol: "camera",
                title: "Title \(index)", summary: "Summary", body: "One **bold** paragraph.\n\nAnother.",
                image: .init(
                    url: URL(string: "https://site.test/\(index).png")!,
                    alt: "Alt",
                    width: 2080,
                    height: 1504,
                ),
                action: index == 0 ? .app(.testCamera, title: "Test Your Camera…") : nil,
            )
        }
        return WhatsNewPages(items: items, images: [:])
    }

    @Test func `the film's rise comes first, then the highlights, a page each, and Done`() throws {
        try #require(FileManager.default.fileExists(atPath: WelcomeTests.film.path))
        let model = WhatsNewModel(
            pages: pages(["0.2.4-prealpha", "0.2.4-prealpha"]),
            film: WelcomeTests.film,
            reduceMotion: false,
        )
        var finished = false
        model.onFinish = { finished = true }
        #expect(model.step == .film)
        #expect(model.player?.isMuted == true, "the film is silent")
        // As the film does when its logo has risen.
        model.showHighlights()
        #expect(model.step == .highlights)
        model.next()
        #expect(model.step == .page(0))
        model.next()
        #expect(model.step == .page(1))
        #expect(!finished)
        model.next()
        #expect(finished)
    }

    @Test func `back goes to the page before, and from the first page to the highlights`() {
        let model = WhatsNewModel(pages: pages(["0.2.4-prealpha", "0.2.4-prealpha"]), film: nil, reduceMotion: false)
        model.show(page: 1)
        model.back()
        #expect(model.step == .page(0))
        model.back()
        #expect(model.step == .highlights)
        model.back()
        #expect(model.step == .highlights)
        model.show(page: 7)
        #expect(model.step == .highlights, "a page that isn't there")
    }

    @Test func `with Reduce Motion or without the film, it opens on the highlights`() {
        #expect(WhatsNewModel(pages: pages(["0.2.4-prealpha"]), film: WelcomeTests.film, reduceMotion: true)
            .step == .highlights)
        #expect(WhatsNewModel(pages: pages(["0.2.4-prealpha"]), film: nil, reduceMotion: false).step == .highlights)
    }

    @Test func `the title names the version when every highlight is in it`() {
        #expect(WhatsNewModel(pages: pages(["0.2.4-prealpha"]), film: nil, reduceMotion: false)
            .title == "What's New in Redlamp 0.2.4")
        #expect(
            WhatsNewModel(pages: pages(["0.2.5-prealpha", "0.2.4-prealpha"]), film: nil, reduceMotion: false).title
                == "What's New in Redlamp",
        )
    }

    @Test func `a symbol this macOS doesn't have shows as a sparkle`() {
        #expect(WhatsNewView.symbol("camera.badge.ellipsis") == "camera.badge.ellipsis")
        #expect(WhatsNewView.symbol("no.such.symbol.anywhere") == "sparkles")
    }

    @Test func `the window is the welcome's size; arrows move through the pages and Escape closes it`() throws {
        var closed = false
        let controller = WhatsNewWindowController(
            pages: pages(["0.2.4-prealpha", "0.2.4-prealpha"]), film: nil, onAction: { _ in },
            onClose: { closed = true },
        )
        let window = try #require(controller.window)
        #expect(window.frame.size == WelcomeView.size)
        #expect(window.title == "What's New in Redlamp")
        #expect(controller.model.step == .highlights)
        try controller.keyDown(with: key(NSRightArrowFunctionKey))
        #expect(controller.model.step == .page(0))
        try controller.keyDown(with: key(NSLeftArrowFunctionKey))
        #expect(controller.model.step == .highlights)
        try #require(window.contentView).doCommand(by: #selector(NSResponder.cancelOperation(_:)))
        #expect(closed)
    }

    @Test func `a page's button closes the window, then opens what it names`() {
        var ran: WhatsNewItem.Action?
        var closed = false
        let controller = WhatsNewWindowController(
            pages: pages(["0.2.4-prealpha"]), film: nil, onAction: { ran = $0 }, onClose: { closed = true },
        )
        controller.showWindow(nil)
        controller.model.perform(.app(.testCamera, title: "Test Your Camera…"))
        #expect(closed)
        #expect(ran == .app(.testCamera, title: "Test Your Camera…"))
    }

    private func key(_ function: Int) throws -> NSEvent {
        let character = String(Character(Unicode.Scalar(UInt16(function))!))
        return try #require(NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: 0, context: nil,
            characters: character, charactersIgnoringModifiers: character, isARepeat: false,
            keyCode: function == NSRightArrowFunctionKey ? 124 : 123,
        ))
    }
}
