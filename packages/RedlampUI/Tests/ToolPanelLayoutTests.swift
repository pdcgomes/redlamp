import AppKit
import Foundation
import RedlampDesign
import RedlampEngineAPI
import Testing
@testable import RedlampUI

/// A tool's panel keeps its rows apart as what it shows grows and shrinks.
@MainActor
@Suite(.serialized)
struct ToolPanelLayoutTests {
    private func openEditor(_ engine: StubEngine) async throws -> (EditorModel, () -> Void) {
        let folder = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let model = EditorModel(engine: engine)
        model.select(folder.appending(path: "IMG_0001.ARW"))
        for _ in 0 ..< 200 where model.info == nil {
            try await Task.sleep(for: .milliseconds(5))
        }
        #expect(model.info != nil)
        return (model, {
            model.fillsGeneratively = false
            try? FileManager.default.removeItem(at: folder)
        })
    }

    private func window(_ content: NSView) -> NSWindow {
        _ = NSApplication.shared
        let window = NSWindow(
            contentRect: CGRect(x: 0, y: 0, width: 300, height: 900), styleMask: [.titled], backing: .buffered,
            defer: false,
        )
        window.contentView = content
        return window
    }

    private func settle(_ window: NSWindow) async throws {
        for _ in 0 ..< 20 {
            try await Task.sleep(for: .milliseconds(5))
            window.contentView?.layoutSubtreeIfNeeded()
        }
    }

    @Test func `the Healing panel's sliders move down when the download offer appears, and back up`() async throws {
        let engine = StubEngine()
        engine.generativeAvailability = .needsModel(ModelInfo(
            id: "flux2-klein-4b-fill", name: "FLUX.2 [klein] 4B", purpose: "Generative fill",
            downloadBytes: 2_410_000_000, state: .notDownloaded, licence: "Apache-2.0",
            licenceURL: URL(string: "https://example.com/LICENSE.txt"),
        ))
        let (model, cleanup) = try await openEditor(engine)
        defer { cleanup() }
        model.activeTool = .heal
        await model.loadGenerativeFill()
        await model.setSpotMode(.remove)
        model.fillsGeneratively = false

        let column = InspectorPanelsView(model: model, tool: .heal)
        let window = window(column)
        defer { window.contentView = nil }
        try await settle(window)
        let rows = column.document.arrangedViews
        let (panel, sliders) = try (#require(rows.first as? HostedControl), #require(rows.last))
        let closed = panel.frame.height

        func expectApart(_ comment: Comment) {
            #expect(panel.frame.height == panel.height(forWidth: panel.frame.width), comment)
            #expect(sliders.frame.minY >= panel.frame.maxY, comment)
            #expect(column.document.frame.height >= sliders.frame.maxY, comment)
        }
        expectApart("with Content-Aware")

        model.fillsGeneratively = true
        try await settle(window)
        #expect(panel.frame.height > closed + 40, "the offer adds its text and buttons")
        expectApart("with the download offer")

        model.fillsGeneratively = false
        try await settle(window)
        #expect(panel.frame.height == closed)
        expectApart("with Content-Aware again")
    }
}
