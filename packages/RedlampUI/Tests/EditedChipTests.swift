import AppKit
import Foundation
import RedlampDesign
import RedlampEngineAPI
import Testing
@_spi(Harness) @testable import RedlampUI

/// The Edited chip counts the kinds of setting a panel has changed, as Copy Settings lists them.
@MainActor
struct EditedChipTests {
    @Test func `every panel's settings belong to exactly one of its checklist lines, and no line to two panels`() {
        var owners: [String: PanelID] = [:]
        for panel in PanelID.allCases {
            let ids = PanelID.settingsItemIDs[panel] ?? []
            #expect(panel.settingsItems.map(\.id) == ids, "\(panel): a line that isn't in the checklist")
            for id in ids {
                #expect(owners[id] == nil, "\(id) is counted by \(owners[id].map(\.title) ?? "") and \(panel.title)")
                owners[id] = panel
            }
            for parameter in panel.parameters {
                let lines = panel.settingsItems.filter { $0.parameters.contains(parameter) }
                #expect(lines.count == 1, "\(parameter) is on \(lines.count) of \(panel.title)'s lines")
            }
        }
        #expect(PanelID.detail.settingsItems.map(\.name) == ["Sharpening", "Noise Reduction"])
        #expect(PanelID.toneCurve.settingsItems.map(\.name) == ["Parametric Curve", "Point Curve"])
        #expect(PanelID.colorMixer.settingsItems.map(\.name) == ["Hue", "Saturation", "Luminance", "Point Color"])
        #expect(PanelID.effects.settingsItems.count == 7 && PanelID.lens.settingsItems.count == 4)
    }

    @Test func `a panel counts the lines with a setting away from its default, in the panel's order`() {
        let model = EditorModel(engine: StubEngine())
        #expect(model.editedItems(.detail).isEmpty && !model.isEdited(.detail))
        model.setValue(.noiseLuminance, 20)
        #expect(model.editedItems(.detail).map(\.name) == ["Noise Reduction"])
        #expect(model.isEdited(.detail))
        model.setValue(.grainAmount, 30)
        model.setValue(.vignetteAmount, -20)
        #expect(model.editedItems(.effects).map(\.name) == ["Vignette", "Grain"])
        model.setPointCurve([CurvePoint(x: 0, y: 0.1), CurvePoint(x: 1, y: 1)])
        #expect(model.editedItems(.toneCurve).map(\.name) == ["Point Curve"])
        model.setPanel(.detail, on: false)
        #expect(model.editedItems(.detail).count == 1, "a switched-off panel still counts")
    }

    @Test func `the chip's tooltip and VoiceOver name what it counts`() async throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let model = EditorModel(engine: StubEngine())
        model.select(folder.appending(path: "IMG_0001.ARW"))
        for _ in 0 ..< 200 where model.info == nil {
            try await Task.sleep(for: .milliseconds(5))
        }
        let panel = PanelSectionView(panel: .detail, model: model, rows: [NSView()])
        let window = NSWindow(
            contentRect: CGRect(x: 0, y: 0, width: 316, height: 200), styleMask: [.borderless], backing: .buffered,
            defer: true,
        )
        window.contentView = panel
        defer { window.contentView = nil }
        model.setValue(.sharpenAmount, 70)
        model.setValue(.noiseLuminance, 20)
        try await Task.sleep(for: .milliseconds(20))
        let header = try #require(panel.subviews.first { $0.accessibilityIdentifier() == "panel.detail.header" })
        #expect(header.accessibilityHelp() == "Detail has 2 edited settings: Sharpening, Noise Reduction")
        let owner = try #require(header as? NSViewToolTipOwner)
        #expect(owner.view(header, stringForToolTip: 0, point: .zero, userData: nil) == "Sharpening, Noise Reduction")

        model.reset(.sharpenAmount)
        try await Task.sleep(for: .milliseconds(20))
        #expect(header.accessibilityHelp() == "Detail has 1 edited setting: Noise Reduction")
        model.reset(.noiseLuminance)
        try await Task.sleep(for: .milliseconds(20))
        #expect(header.accessibilityHelp() == nil)
    }
}
