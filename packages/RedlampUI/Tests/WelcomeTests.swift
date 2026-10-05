import AppKit
import AVFoundation
import Foundation
import Testing
@testable import RedlampUI

/// The welcome window: when it opens by itself, and its steps from the film to the editor.
@MainActor
struct WelcomeTests {
    /// The film the app ships.
    static let film = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().appendingPathComponent("../../../apps/RedlampMac/Resources/Welcome.mp4")
        .standardizedFileURL

    private func defaults() throws -> UserDefaults {
        try #require(UserDefaults(suiteName: "WelcomeTests-\(UUID().uuidString)"))
    }

    @Test func `it opens at the first launch, and not again once it has been shown`() throws {
        let defaults = try defaults()
        #expect(Welcome.opensAtLaunch(arguments: ["Redlamp"], defaults: defaults))
        #expect(
            Welcome.opensAtLaunch(arguments: ["Redlamp", "/Photos/Trip"], defaults: defaults),
            "with a folder to open",
        )
        Welcome.markShown(in: defaults)
        #expect(!Welcome.opensAtLaunch(arguments: ["Redlamp"], defaults: defaults))
    }

    @Test func `a new welcome opens again for someone who saw the one before`() throws {
        let defaults = try defaults()
        defaults.set(Welcome.version - 1, forKey: Welcome.shownKey)
        #expect(Welcome.opensAtLaunch(arguments: ["Redlamp"], defaults: defaults))
    }

    @Test func `launches made by tooling never open it, and --welcome always does`() throws {
        let defaults = try defaults()
        for flag in Welcome.toolingArguments {
            #expect(
                !Welcome.opensAtLaunch(arguments: ["Redlamp", "/Photos", flag, "select=1"], defaults: defaults),
                "\(flag)",
            )
        }
        Welcome.markShown(in: defaults)
        #expect(Welcome.opensAtLaunch(arguments: ["Redlamp", "--welcome"], defaults: defaults))
    }

    @Test func `the film comes first, then Continue and Start Editing go through the pages`() throws {
        try #require(FileManager.default.fileExists(atPath: Self.film.path))
        let model = WelcomeModel(film: Self.film, reduceMotion: false)
        var finished = false
        model.onFinish = { finished = true }
        #expect(model.step == .film)
        // As the film does when its logo has risen.
        model.showPages()
        #expect(model.step == .about)
        model.next()
        #expect(model.step == .help)
        #expect(!finished)
        model.next()
        #expect(finished)
    }

    @Test func `skipping goes to the first page over the film's last frame, without its sound`() async throws {
        let model = WelcomeModel(film: Self.film, reduceMotion: false)
        let player = try #require(model.player)
        model.skip()
        #expect(model.step == .about)
        #expect(model.filmOpacity == 0)
        for _ in 0 ..< 150 where model.filmOpacity == 0 {
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(model.filmOpacity == 1)
        #expect(player.rate == 0)
        #expect(player.volume == 0)
        #expect(abs(player.currentTime().seconds - WelcomeModel.lastFrame.seconds) < 0.001)
    }

    @Test func `with Reduce Motion or without the film, it opens on the first page`() {
        #expect(WelcomeModel(film: Self.film, reduceMotion: true).step == .about)
        #expect(WelcomeModel(film: nil, reduceMotion: false).step == .about)
    }

    @Test func `a film that can't be played leaves the pages over the wall`() async throws {
        let model = WelcomeModel(film: URL(fileURLWithPath: "/nonexistent/Welcome.mp4"), reduceMotion: false)
        model.start()
        for _ in 0 ..< 150 where model.step == .film {
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(model.step == .about)
        model.stop()
    }

    /// The window is the film's size, and Escape (sent up from wherever focus is) skips the film,
    /// then closes the window. Reduce Motion is given, not read from this Mac: GitHub's runners
    /// turn it on.
    @Test func `escape skips the film, then closes the window`() throws {
        var closed = false
        let controller = WelcomeWindowController(film: Self.film, reduceMotion: false) { closed = true }
        let window = try #require(controller.window)
        let content = try #require(window.contentView)
        #expect(window.frame.size == WelcomeView.size, "the film fills the window, titlebar included")
        #expect(content.frame.size == WelcomeView.size)
        #expect(!window.styleMask.contains(.resizable))
        content.doCommand(by: #selector(NSResponder.cancelOperation(_:)))
        #expect(controller.model.step == .about)
        #expect(!closed)
        content.doCommand(by: #selector(NSResponder.cancelOperation(_:)))
        #expect(closed)
    }

    @Test func `with Reduce Motion, the window opens on the first page and escape closes it`() throws {
        var closed = false
        let controller = WelcomeWindowController(film: Self.film, reduceMotion: true) { closed = true }
        #expect(controller.model.step == .about)
        try #require(controller.window?.contentView).doCommand(by: #selector(NSResponder.cancelOperation(_:)))
        #expect(closed)
    }
}
